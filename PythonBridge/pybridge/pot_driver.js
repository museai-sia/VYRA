'use strict';
/*
 * VYRA on-device PO token driver.
 *
 * Executes Google's BotGuard VM the way LuanRT's bgutils-js
 * (MIT License) BotGuardClient / WebPoMinter do, but inside the
 * JavaScript environment the app provides for it: either a hidden
 * WKWebView page (real WebKit DOM) or a persistent JavaScriptCore
 * context with the hand-written browser shims below. The Python
 * provider (pot_ondevice.py) performs every network step itself
 * (challenge fetch, interpreter download, GenerateIT) through
 * yt-dlp's networking, so the session/cookies are the extraction's
 * own; this script only runs the VM and mints.
 *
 * Protocol: the host evaluates `__vyraPotOp('<json>')`; the call's
 * completion value is a JSON string describing the stage result.
 * Async VM steps report {status: 'pending'} and are driven by the
 * host with 'pump' + 'poll' ops (each host evaluation is a microtask
 * checkpoint; in the WebView the real event loop also turns between
 * evaluations). State lives in globalThis.__vyraPot and survives
 * across evaluations until the host resets the context.
 */
(function () {
  var G = globalThis;
  if (G.__vyraPot) return;
  var S = {
    installed: false,
    nativeTimers: typeof G.setTimeout === 'function',
    vm: null,
    vmFns: null,
    syncSnapshot: null,
    signalOutput: null,
    mintCallback: null,
    snap: null,        // {done, response, error}
    mintSetup: null,   // {done, error}
    mint: null,        // {done, token, error}
    timers: [],
    timerSeq: 1,
    start: Date.now(),
  };
  G.__vyraPot = S;

  // ---------- base64 (atob/btoa, Latin1 semantics) ----------
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function atobShim(input) {
    var str = String(input).replace(/[\s=]+$/, '');
    var out = '';
    var bits = 0, val = 0;
    for (var i = 0; i < str.length; i++) {
      var idx = B64.indexOf(str.charAt(i));
      if (idx < 0) throw new Error('InvalidCharacterError: bad base64');
      val = (val << 6) | idx; bits += 6;
      if (bits >= 8) { bits -= 8; out += String.fromCharCode((val >> bits) & 0xff); }
    }
    return out;
  }
  function btoaShim(input) {
    var str = String(input);
    var out = '';
    for (var i = 0; i < str.length; i += 3) {
      var a = str.charCodeAt(i) & 0xff;
      var b = i + 1 < str.length ? str.charCodeAt(i + 1) & 0xff : 0;
      var c = i + 2 < str.length ? str.charCodeAt(i + 2) & 0xff : 0;
      var n = (a << 16) | (b << 8) | c;
      out += B64.charAt((n >> 18) & 63) + B64.charAt((n >> 12) & 63)
        + (i + 1 < str.length ? B64.charAt((n >> 6) & 63) : '=')
        + (i + 2 < str.length ? B64.charAt(n & 63) : '=');
    }
    return out;
  }
  if (typeof G.atob !== 'function') G.atob = atobShim;
  if (typeof G.btoa !== 'function') G.btoa = btoaShim;

  function base64ToU8(base64) {
    var mod = String(base64).replace(/-/g, '+').replace(/_/g, '/').replace(/\./g, '=');
    var bin = G.atob(mod);
    var u8 = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
    return u8;
  }
  function u8ToBase64Url(u8) {
    var bin = '';
    for (var i = 0; i < u8.length; i += 0x8000) {
      bin += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    }
    return G.btoa(bin).replace(/\+/g, '-').replace(/\//g, '_');
  }
  function utf8Encode(str) {
    var bytes = [];
    for (var i = 0; i < str.length; i++) {
      var cp = str.codePointAt(i);
      if (cp > 0xffff) i++;
      if (cp < 0x80) bytes.push(cp);
      else if (cp < 0x800) bytes.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
      else if (cp < 0x10000) bytes.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      else bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    }
    return new Uint8Array(bytes);
  }

  // ---------- timers ----------
  // A bare JSContext has no timers at all: install a queue the host
  // drives via 'pump'. In a WebView the native timers exist and the
  // page event loop turns between host evaluations, so the queue is
  // never installed and pumpTimers() is a no-op.
  function schedule(fn, delay, interval) {
    var id = S.timerSeq++;
    S.timers.push({ id: id, fn: fn, due: Date.now() + (delay || 0), interval: interval || 0 });
    return id;
  }
  function cancel(id) {
    S.timers = S.timers.filter(function (t) { return t.id !== id; });
  }
  if (!S.nativeTimers) {
    G.setTimeout = function (fn, delay) { return schedule(fn, delay, 0); };
    G.clearTimeout = cancel;
    G.setInterval = function (fn, delay) { return schedule(fn, delay, delay || 0); };
    G.clearInterval = cancel;
    G.requestAnimationFrame = function (fn) { return schedule(function () { fn(Date.now()); }, 16, 0); };
    G.cancelAnimationFrame = cancel;
  }
  function pumpTimers() {
    if (S.nativeTimers) return 0;
    var now = Date.now();
    var due = S.timers.filter(function (t) { return t.due <= now; });
    S.timers = S.timers.filter(function (t) { return t.due > now; });
    for (var i = 0; i < due.length; i++) {
      var t = due[i];
      if (t.interval) { t.due = now + t.interval; S.timers.push(t); }
      try { t.fn(); } catch (e) { /* VM timers must not kill the driver */ }
    }
    return due.length;
  }

  // ---------- browser-ish environment shims (bare engine only) ---
  function makeElement(tag) {
    return {
      tagName: String(tag || 'div').toUpperCase(),
      nodeName: String(tag || 'div').toUpperCase(),
      nodeType: 1,
      style: {},
      children: [],
      childNodes: [],
      attributes: {},
      innerHTML: '',
      textContent: '',
      value: '',
      width: 0,
      height: 0,
      clientWidth: 0,
      clientHeight: 0,
      offsetWidth: 0,
      offsetHeight: 0,
      appendChild: function (c) { this.children.push(c); this.childNodes.push(c); return c; },
      removeChild: function (c) { return c; },
      insertBefore: function (c) { this.children.push(c); return c; },
      setAttribute: function (k, v) { this.attributes[k] = v; },
      getAttribute: function (k) { return this.attributes[k] || null; },
      removeAttribute: function (k) { delete this.attributes[k]; },
      addEventListener: function () {},
      removeEventListener: function () {},
      dispatchEvent: function () { return true; },
      getContext: function () { return null; },
      getBoundingClientRect: function () {
        return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 };
      },
      querySelector: function () { return null; },
      querySelectorAll: function () { return []; },
      getElementsByTagName: function () { return []; },
      cloneNode: function () { return makeElement(tag); },
      focus: function () {},
      blur: function () {},
      click: function () {},
      toDataURL: function () { return 'data:,'; },
    };
  }

  S.installEnv = function (opts) {
    opts = opts || {};
    // A real DOM (WKWebView page) already provides everything the
    // VM probes; keep it untouched and only mark the env installed.
    if (G.document && G.document.nodeType === 9 && G.window && G.navigator) {
      S.installed = true;
      return;
    }
    var ua = opts.userAgent || 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36(KHTML, like Gecko)';
    G.window = G;
    G.self = G;
    G.top = G;
    G.parent = G;
    G.location = {
      href: 'https://www.youtube.com/',
      origin: 'https://www.youtube.com',
      protocol: 'https:',
      host: 'www.youtube.com',
      hostname: 'www.youtube.com',
      port: '',
      pathname: '/',
      search: '',
      hash: '',
      reload: function () {},
      assign: function () {},
      replace: function () {},
      toString: function () { return this.href; },
    };
    G.origin = 'https://www.youtube.com';
    G.navigator = {
      userAgent: ua,
      appVersion: ua.replace('Mozilla/', ''),
      appName: 'Netscape',
      platform: 'MacIntel',
      language: 'en-US',
      languages: ['en-US', 'en'],
      onLine: true,
      cookieEnabled: true,
      hardwareConcurrency: 8,
      vendor: 'Apple Computer, Inc.',
      maxTouchPoints: 0,
      product: 'Gecko',
      webdriver: false,
      javaEnabled: function () { return false; },
    };
    G.screen = {
      width: 1024, height: 768, availWidth: 1024, availHeight: 768,
      colorDepth: 24, pixelDepth: 24,
    };
    G.innerWidth = 1024; G.innerHeight = 768;
    G.outerWidth = 1024; G.outerHeight = 768;
    G.devicePixelRatio = 1;
    G.performance = {
      now: function () { return Date.now() - S.start; },
      timeOrigin: S.start,
      timing: {},
      navigation: {},
      getEntriesByType: function () { return []; },
      mark: function () {},
      measure: function () {},
    };
    var documentElement = makeElement('html');
    var body = makeElement('body');
    var head = makeElement('head');
    G.document = {
      documentElement: documentElement,
      body: body,
      head: head,
      cookie: '',
      referrer: 'https://www.youtube.com/',
      URL: 'https://www.youtube.com/',
      documentURI: 'https://www.youtube.com/',
      readyState: 'complete',
      hidden: false,
      visibilityState: 'visible',
      createElement: function (tag) { return makeElement(tag); },
      createElementNS: function (ns, tag) { return makeElement(tag); },
      createTextNode: function (t) { return { nodeType: 3, textContent: t }; },
      createDocumentFragment: function () { return makeElement('#fragment'); },
      getElementById: function () { return null; },
      querySelector: function () { return null; },
      querySelectorAll: function () { return []; },
      getElementsByTagName: function () { return []; },
      getElementsByClassName: function () { return []; },
      addEventListener: function () {},
      removeEventListener: function () {},
    };
    G.addEventListener = function () {};
    G.removeEventListener = function () {};
    G.dispatchEvent = function () { return true; };
    G.getComputedStyle = function () {
      return { getPropertyValue: function () { return ''; } };
    };
    G.matchMedia = function () {
      return { matches: false, media: '', addEventListener: function () {}, addListener: function () {} };
    };
    if (typeof G.crypto === 'undefined' || !G.crypto || typeof G.crypto.getRandomValues !== 'function') {
      G.crypto = {
        getRandomValues: function (arr) {
          for (var i = 0; i < arr.length; i++) {
            arr[i] = Math.floor(Math.random() * 256) % (arr.BYTES_PER_ELEMENT === 2 ? 65536 : 256);
          }
          return arr;
        },
      };
    }
    if (typeof G.TextEncoder === 'undefined') {
      G.TextEncoder = function () {};
      G.TextEncoder.prototype.encode = function (s) { return utf8Encode(String(s)); };
    }
    S.installed = true;
  };

  // ---------- BotGuard driver (bgutils-js semantics) ----------
  function emit(obj) { return JSON.stringify(obj); }
  function errObj(stage, e) {
    return { status: 'error', stage: stage, error: String(e && e.message || e) };
  }
  function snapResult() {
    return S.snap.error ? errObj('snapshot', S.snap.error)
      : { status: 'snapshot', response: S.snap.response, hasMinterFn: typeof (S.signalOutput || [])[0] === 'function' };
  }
  function mintSetupResult() {
    return S.mintSetup.error ? errObj('mint_setup', S.mintSetup.error) : { status: 'ready' };
  }
  function mintResult() {
    return S.mint.error ? errObj('mint', S.mint.error) : { status: 'token', token: S.mint.token };
  }

  S.op = function (op) {
    try {
      switch (op.op) {
        case 'install': {
          S.installEnv(op.env || {});
          return emit({ status: 'installed', nativeTimers: S.nativeTimers });
        }
        case 'load': {
          if (!S.installed) S.installEnv(op.env || {});
          // BotGuard reads yt.config_ (EVENT_ID) while snapshotting;
          // install the config of the page the challenge came from.
          if (op.ytConfig) G.yt = { config_: op.ytConfig };
          (0, eval)(op.interpreterJs);
          var vm = G[op.globalName];
          if (!vm) return emit(errObj('load', 'BotGuard global "' + op.globalName + '" missing after interpreter eval'));
          if (typeof vm.a !== 'function') return emit(errObj('load', 'BotGuard init function (vm.a) unavailable'));
          S.vm = vm;
          S.vmFns = null;
          var setupCb = function (asyncFn, shutdownFn, passFn, cameraFn) {
            S.vmFns = {
              asyncSnapshotFunction: asyncFn,
              shutdownFunction: shutdownFn,
              passEventFunction: passFn,
              checkCameraFunction: cameraFn,
            };
          };
          var noop = function () {};
          var res = vm.a(op.program, setupCb, true, undefined, noop, [[], []], undefined, false, [noop, noop, noop, noop, noop]);
          S.syncSnapshot = res && res[0];
          pumpTimers();
          return emit({
            status: 'loaded',
            hasSyncSnapshot: typeof S.syncSnapshot === 'function',
            hasAsyncSnapshot: !!(S.vmFns && typeof S.vmFns.asyncSnapshotFunction === 'function'),
          });
        }
        case 'snapshot': {
          // The VM may deliver the async functions (via the setup
          // callback) only after its own timers/microtasks run; the
          // host drives that with pump/poll cycles.
          if (!S.vmFns || typeof S.vmFns.asyncSnapshotFunction !== 'function') {
            pumpTimers();
            if (!S.vmFns || typeof S.vmFns.asyncSnapshotFunction !== 'function') {
              return emit({ status: 'pending' });
            }
          }
          if (!S.snap) {
            S.signalOutput = [];
            S.snap = { done: false, response: null, error: null };
            var cb = function (resp) { S.snap.done = true; S.snap.response = resp; };
            try {
              S.vmFns.asyncSnapshotFunction(cb, [undefined, undefined, S.signalOutput, undefined]);
            } catch (e) {
              S.snap.done = true; S.snap.error = String(e && e.message || e);
            }
          }
          pumpTimers();
          return emit(S.snap.done ? snapResult() : { status: 'pending' });
        }
        case 'status': {
          return emit({
            status: 'ok',
            installed: S.installed,
            hasVm: !!S.vm,
            hasVmFns: !!S.vmFns,
            hasAsyncSnapshot: !!(S.vmFns && typeof S.vmFns.asyncSnapshotFunction === 'function'),
            hasSyncSnapshot: typeof S.syncSnapshot === 'function',
            hasMinterFn: typeof (S.signalOutput || [])[0] === 'function',
            pendingTimers: S.timers.length,
          });
        }
        case 'mint_setup': {
          var getMinter = S.signalOutput && S.signalOutput[0];
          if (typeof getMinter !== 'function') {
            return emit(errObj('mint_setup', 'PMD:Undefined (no minter function in signal output)'));
          }
          S.mintSetup = { done: false, error: null };
          S.mintCallback = null;
          var p = getMinter(base64ToU8(op.integrityToken));
          if (p && typeof p.then === 'function') {
            p.then(function (cb) { S.mintCallback = cb; S.mintSetup.done = true; },
                   function (e) { S.mintSetup.done = true; S.mintSetup.error = String(e && e.message || e); });
          } else if (typeof p === 'function') {
            S.mintCallback = p; S.mintSetup.done = true;
          } else {
            S.mintSetup.done = true; S.mintSetup.error = 'APF:Failed (getMinter did not return a callback)';
          }
          pumpTimers();
          return emit(S.mintSetup.done ? mintSetupResult() : { status: 'pending' });
        }
        case 'mint': {
          if (typeof S.mintCallback !== 'function') {
            return emit(errObj('mint', 'mint callback unavailable (mint_setup not completed)'));
          }
          S.mint = { done: false, token: null, error: null };
          var mp = S.mintCallback(utf8Encode(String(op.binding)));
          if (mp && typeof mp.then === 'function') {
            mp.then(function (bytes) {
              S.mint.done = true;
              if (!bytes) S.mint.error = 'YNJ:Undefined (mint returned nothing)';
              else S.mint.token = u8ToBase64Url(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes));
            }, function (e) { S.mint.done = true; S.mint.error = String(e && e.message || e); });
          } else if (mp instanceof Uint8Array) {
            S.mint.done = true; S.mint.token = u8ToBase64Url(mp);
          } else {
            S.mint.done = true; S.mint.error = 'ODM:Invalid (mint result type)';
          }
          pumpTimers();
          return emit(S.mint.done ? mintResult() : { status: 'pending' });
        }
        case 'pump': {
          pumpTimers();
          return emit({ status: 'pumped', pendingTimers: S.timers.length });
        }
        case 'poll': {
          if (op.stage === 'snapshot') {
            if (!S.snap) return S.op({ op: 'snapshot' });
            return emit(S.snap.done ? snapResult() : { status: 'pending' });
          }
          if (op.stage === 'mint_setup' && S.mintSetup) {
            return emit(S.mintSetup.done ? mintSetupResult() : { status: 'pending' });
          }
          if (op.stage === 'mint' && S.mint) {
            return emit(S.mint.done ? mintResult() : { status: 'pending' });
          }
          return emit(errObj('poll', 'unknown stage ' + op.stage));
        }
        default:
          return emit(errObj('dispatch', 'unknown op ' + op.op));
      }
    } catch (e) {
      return emit(errObj(op.op || 'unknown', e));
    }
  };
})();

function __vyraPotOp(json) {
  return __vyraPot.op(JSON.parse(json));
}
