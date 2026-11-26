"""On-device PO token provider for yt-dlp (VYRA).

Implements yt-dlp's PoTokenProvider interface like the vendored
bgutil HTTP provider does, but mints the token ON the device instead
of asking a LAN server:

  1. Obtain a BotGuard challenge — from the video webpage the
     extractor already fetched, or from a fresh youtube.com homepage
     request. All network traffic goes through yt-dlp's own
     networking (`_request_webpage` with the PoTokenRequest), so the
     challenge, the interpreter download and the GenerateIT call use
     the extraction's cookies/proxy/session — no parallel session.
  2. Run Google's BotGuard VM in the app's JavaScript environment
     (`_host.pot_js`, driver: pot_driver.js — a WKWebView page when
     available, else a persistent JavaScriptCore context) and take
     the WebPO snapshot.
  3. POST the snapshot to google.internal.waa.v1.Waa/GenerateIT for
     an integrity token, hand it to the VM's minter, and mint the
     token bound to exactly the content binding yt-dlp computed
     (`get_webpo_content_binding`: visitor data / data sync ID for
     GVS, video ID for PLAYER/SUBS).

The flow mirrors the bgutil server (Brainicism/bgutil-ytdlp-pot-
provider, built on LuanRT's bgutils-js, MIT License) step for step;
the Waa request key and Google API key below are the public web
client values those projects ship.

Failure behavior is deliberately honest: any failure raises
PoTokenProviderError, yt-dlp's POT director logs it and the
extraction continues WITHOUT a token (today's behavior), and the
failure is also recorded in the module event log, which the bridge
drains into its responses so the app can persist it in the debug
log with kind 'pot'. Nothing is retried in a loop and no token is
ever fabricated. The whole mint is bounded by
_MINT_OVERALL_TIMEOUT (it runs on a worker thread so even a JS
host call that never answers cannot hang the extraction), and
after a failed or timed-out mint a failure cooldown makes later
requests fail open immediately instead of paying the full mint
cost again for every client/context yt-dlp asks about. The one degraded success path: when GenerateIT
answers with only a websafe fallback token (Google did not accept
the snapshot for a full integrity token), the fallback token is
returned for session-bound GVS requests only — the same use
YouTube's own web client makes of it — and the event log says so.

Settings (extractor_args): youtubepot-vyraondevice
  enabled: ['true']   (required; anything else = provider inert)
  backend: ['auto'|'webview'|'jsc']  (JS environment preference)
"""
from __future__ import annotations

import json
import os
import threading
import time

from yt_dlp.extractor.youtube.pot.provider import (
    PoTokenContext,
    PoTokenProvider,
    PoTokenProviderError,
    PoTokenProviderRejectedRequest,
    PoTokenRequest,
    PoTokenResponse,
    register_preference,
    register_provider,
)
from yt_dlp.extractor.youtube.pot.utils import (
    WEBPO_CLIENTS,
    ContentBindingType,
    get_webpo_content_binding,
)
from yt_dlp.networking.common import Request
from yt_dlp.utils import js_to_json
from yt_dlp.utils.traversal import traverse_obj

_PROVIDER_VERSION = '1.0.0'

# Waa (Web Attestation API) endpoints and public client values, as
# shipped by bgutils-js (constants.ts / session_manager.ts).
_WAA_GENERATE_IT_URL = (
    'https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT')
_WAA_REQUEST_KEY = 'O43z0dpjhgX20SCx4KAo'
_GOOG_API_KEY = 'AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw'
_USER_AGENT = ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
               'AppleWebKit/537.36(KHTML, like Gecko)')
_HOMEPAGE_URL = 'https://www.youtube.com/'

_NETWORK_TIMEOUT = 25
_SNAPSHOT_TIMEOUT = 30
_MINT_TIMEOUT = 20
# The WHOLE mint (every stage together) gets this budget. Without
# it the stage budgets summed to minutes (25+25+30+25+20+20, plus
# host-call overshoot), and yt-dlp re-asked for every client /
# context after a failure — the first extraction effectively never
# finished. On expiry the mint FAILS OPEN: PoTokenProviderError,
# and the extraction continues without a token.
_MINT_OVERALL_TIMEOUT = 20
# After a failed or timed-out mint, later requests fail open
# immediately for this long instead of restarting the full mint:
# yt-dlp's director caches successes only, so without this latch
# every distinct-binding request in the same extraction paid the
# full mint cost again. The window also covers a worker thread
# still unwinding from the timed-out mint — every host call is
# individually capped well below it.
_FAILURE_COOLDOWN = 120
# op_driven poll cadence. The original 0.05s loop issued two
# blocking host evaluations per cycle; each WebView evaluation hops
# to the main thread and spins its run loop, so a 30s stage meant
# ~1200 main-thread round trips and app-wide lag.
_POLL_INTERVAL = 0.25

# MARK: - Bridge-visible event log (debug log kind 'pot')

_events: list[str] = []
_events_lock = threading.Lock()


def record_event(level: str, message: str) -> None:
    """Append one diagnostic line for the app's debug log. Levels:
    'error' (a mint failed) and 'info' (milestones / degraded mode).
    Token values are never recorded — only stages and outcomes."""
    with _events_lock:
        _events.append(f'{level.upper()}: {message}')
        del _events[:-50]


def drain_events() -> list[str]:
    with _events_lock:
        drained = list(_events)
        _events.clear()
        return drained


# MARK: - JS session (the persistent _host.pot_js environment)

_driver_source_cache: str | None = None


def _driver_source() -> str:
    global _driver_source_cache
    if _driver_source_cache is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            'pot_driver.js')
        with open(path, encoding='utf-8') as f:
            _driver_source_cache = f.read()
    return _driver_source_cache


class _PotMintError(Exception):
    """A minting stage failed; converted to PoTokenProviderError."""


class _JsSession:
    """One BotGuard session in the host JS environment. The state
    (VM, minter) lives in the JS context across `_host.pot_js`
    calls; `reset()` asks the host for a fresh context."""

    def __init__(self, backend_pref: str = 'auto'):
        import _host

        self._host = _host
        self.backend_pref = backend_pref or 'auto'
        self.backend: str | None = None
        self._driver_loaded = False

    def reset(self) -> str:
        out = self._host.pot_js_reset(self.backend_pref)
        try:
            info = json.loads(out)
        except Exception:
            info = {}
        self.backend = info.get('backend') or 'unknown'
        self._driver_loaded = False
        return self.backend

    def op(self, payload: dict) -> dict:
        script = ''
        if not self._driver_loaded:
            script += _driver_source() + '\n'
            self._driver_loaded = True
        script += '__vyraPotOp(' + json.dumps(json.dumps(payload)) + ');'
        out = self._host.pot_js(script)
        try:
            result = json.loads(out)
        except Exception as e:
            raise _PotMintError(f'JS host returned unparseable output: {e}')
        if not isinstance(result, dict):
            raise _PotMintError('JS host returned a non-object result')
        if result.get('status') == 'error':
            raise _PotMintError(
                f"JS stage '{result.get('stage')}': {result.get('error')}")
        return result

    def op_driven(self, payload: dict, stage: str, timeout: float) -> dict:
        """Run an op that may report 'pending': poll the VM (each
        host evaluation is a microtask checkpoint) until it
        completes or the deadline passes. The wait is a plain sleep
        between polls — progress happens in the JS environment, not
        in this loop — and 'pump' is sent only to the JSC backend,
        whose hand-driven timer queue needs it; in the WebView the
        page event loop turns on its own and 'pump' is a no-op that
        still costs a main-thread round trip."""
        result = self.op(payload)
        deadline = time.time() + timeout
        while result.get('status') == 'pending':
            if time.time() >= deadline:
                raise _PotMintError(
                    f"JS stage '{stage}' did not complete within {timeout:.0f}s")
            time.sleep(_POLL_INTERVAL)
            if self.backend == 'jsc':
                self.op({'op': 'pump'})
            result = self.op({'op': 'poll', 'stage': stage})
        return result


# Minter cache: provider instances are created per extraction, but
# the JS-side minter (and its integrity token) lives across calls,
# exactly like the bgutil server's session cache. Keyed by nothing —
# there is one app, one session; bindings differ per mint only.
_minter_lock = threading.Lock()
_minter_state = {
    'ready': False,
    'integrity_expires_at': 0.0,
    'backend': None,
}

# Failure latch: while time.time() < this, _real_request_pot fails
# open immediately without touching the JS host or the network.
_mint_blocked_until = 0.0


def _remaining(deadline: float) -> float:
    return deadline - time.time()


def _check_deadline(deadline: float, stage: str) -> None:
    if _remaining(deadline) <= 0:
        raise _PotMintError(
            f'overall mint budget of {_MINT_OVERALL_TIMEOUT:.0f}s '
            f'exceeded before stage: {stage}')


def _stage_budget(deadline: float, cap: float) -> float:
    return max(0.0, min(cap, _remaining(deadline)))


def _reset_minter_state() -> None:
    _minter_state['ready'] = False
    _minter_state['integrity_expires_at'] = 0.0
    _minter_state['backend'] = None


# MARK: - The provider

@register_provider
class VyraOnDevicePTP(PoTokenProvider):
    PROVIDER_NAME = 'vyra:ondevice'
    PROVIDER_VERSION = _PROVIDER_VERSION
    BUG_REPORT_LOCATION = 'VYRA app (on-device POT provider)'
    _SUPPORTED_CONTEXTS = (
        PoTokenContext.GVS,
        PoTokenContext.PLAYER,
        PoTokenContext.SUBS,
    )
    _SUPPORTED_CLIENTS = WEBPO_CLIENTS
    # All requests go through _request_webpage (yt-dlp networking),
    # so no external-request features need declaring.
    _SUPPORTED_EXTERNAL_REQUEST_FEATURES = None

    # -- availability -------------------------------------------------

    def is_available(self) -> bool:
        # Cheap and network-free, per the framework's contract: the
        # Settings toggle (extractor arg) must be on and the app must
        # provide the JS host functions.
        enabled = self._configuration_arg('enabled', default=['false'])[0]
        if (enabled or '').lower() != 'true':
            return False
        try:
            import _host

            return hasattr(_host, 'pot_js') and hasattr(_host, 'pot_js_reset')
        except Exception:
            return False

    def _backend_pref(self) -> str:
        pref = self._configuration_arg('backend', default=['auto'])[0]
        return pref if pref in ('auto', 'webview', 'jsc') else 'auto'

    # -- main entry ---------------------------------------------------

    def _real_request_pot(self, request: PoTokenRequest) -> PoTokenResponse:
        global _mint_blocked_until
        binding, binding_type = get_webpo_content_binding(request)
        if not binding:
            raise PoTokenProviderRejectedRequest(
                'No WebPO content binding for this request '
                f'(context={request.context.value}, '
                f'client={request.internal_client_name})')
        context_desc = (
            f'{request.context.value}/'
            f'{binding_type.value if binding_type else "?"}')
        if time.time() < _mint_blocked_until:
            record_event(
                'error',
                f'on-device mint skipped ({context_desc}): a recent '
                'mint failed or timed out; failing open until the '
                'cooldown expires')
            raise PoTokenProviderError(
                'On-device PO token minting is in failure cooldown; '
                'continuing without a token')
        deadline = time.time() + _MINT_OVERALL_TIMEOUT
        # One mint at a time. If another mint is already running,
        # wait only within this request's own budget — never queue
        # unboundedly behind it.
        if not _minter_lock.acquire(
                timeout=max(0.0, _remaining(deadline))):
            record_event(
                'error',
                f'on-device mint skipped ({context_desc}): another '
                'mint is still running')
            raise PoTokenProviderError(
                'Another on-device PO token mint is still running; '
                'continuing without a token')
        try:
            outcome: dict = {}

            def work():
                try:
                    outcome['result'] = self._mint(
                        request, binding, binding_type, deadline)
                except BaseException as e:  # surfaced by the caller
                    outcome['error'] = e

            # The mint runs on a daemon worker so the overall budget
            # holds even when a single host call blocks: a JS host
            # that never answers cannot hang the extraction, it can
            # only strand its own worker. The worker is the only
            # code touching the JS session while it runs.
            worker = threading.Thread(
                target=work, daemon=True, name='vyra-pot-mint')
            worker.start()
            worker.join(timeout=max(0.0, _remaining(deadline)))
            if worker.is_alive():
                _mint_blocked_until = time.time() + _FAILURE_COOLDOWN
                record_event(
                    'error',
                    f'on-device mint timed out after '
                    f'{_MINT_OVERALL_TIMEOUT:.0f}s ({context_desc}); '
                    'continuing without a token')
                raise PoTokenProviderError(
                    'On-device PO token minting timed out after '
                    f'{_MINT_OVERALL_TIMEOUT:.0f}s')
            error = outcome.get('error')
            if error is not None:
                if isinstance(error, _PotMintError):
                    _mint_blocked_until = (
                        time.time() + _FAILURE_COOLDOWN)
                    record_event(
                        'error',
                        f'on-device mint failed ({context_desc}): '
                        f'{error}')
                    raise PoTokenProviderError(
                        'On-device PO token minting failed: '
                        f'{error}') from error
                raise error
            token, expires_at = outcome['result']
        finally:
            _minter_lock.release()
        _mint_blocked_until = 0.0
        record_event('info', f'on-device mint ok ({context_desc})')
        return PoTokenResponse(po_token=token, expires_at=int(expires_at))

    # -- minting ------------------------------------------------------

    def _mint(self, request, binding, binding_type, deadline):
        # Fast path: a live minter from an earlier request in this
        # app session mints the new binding directly.
        if (_minter_state['ready']
                and time.time() < _minter_state['integrity_expires_at']):
            session = _JsSession(self._backend_pref())
            session.backend = _minter_state['backend']
            try:
                result = session.op_driven(
                    {'op': 'mint', 'binding': binding}, 'mint',
                    _stage_budget(deadline, _MINT_TIMEOUT))
                if result.get('status') == 'token' and result.get('token'):
                    return result['token'], _minter_state['integrity_expires_at']
            except _PotMintError:
                pass  # stale session (context was reset): rebuild once
            _reset_minter_state()
        return self._mint_fresh(request, binding, binding_type, deadline)

    def _mint_fresh(self, request, binding, binding_type, deadline):
        session = _JsSession(self._backend_pref())
        backend = session.reset()

        _check_deadline(deadline, 'challenge fetch')
        challenge, yt_config = self._fetch_challenge(request, deadline)
        interpreter_js = self._fetch_interpreter(
            request, challenge, deadline)

        session.op({'op': 'install', 'env': {'userAgent': _USER_AGENT}})
        load = session.op({
            'op': 'load',
            'interpreterJs': interpreter_js,
            'program': challenge['program'],
            'globalName': challenge['globalName'],
            'ytConfig': yt_config,
        })
        if load.get('status') != 'loaded':
            raise _PotMintError(f'BotGuard VM load failed: {load}')

        _check_deadline(deadline, 'snapshot')
        snapshot = session.op_driven(
            {'op': 'snapshot'}, 'snapshot',
            _stage_budget(deadline, _SNAPSHOT_TIMEOUT))
        if snapshot.get('status') != 'snapshot' or not snapshot.get('response'):
            raise _PotMintError(f'BotGuard snapshot failed: {snapshot}')

        _check_deadline(deadline, 'GenerateIT')
        integrity = self._generate_it(
            request, snapshot['response'], deadline)
        integrity_token = integrity[0] if len(integrity) > 0 else None
        ttl = integrity[1] if len(integrity) > 1 else None
        fallback_token = integrity[3] if len(integrity) > 3 else None

        if not integrity_token:
            # Google did not accept the snapshot for a full integrity
            # token. The websafe fallback token is session-bound, so
            # it is only meaningful for session-bound GVS requests —
            # the same fallback YouTube's web client uses.
            if (fallback_token
                    and request.context == PoTokenContext.GVS
                    and binding_type in (ContentBindingType.VISITOR_DATA,
                                         ContentBindingType.DATASYNC_ID)):
                record_event(
                    'info',
                    'GenerateIT returned no integrity token; using the '
                    'websafe fallback token for this session-bound GVS '
                    f'request (JS backend: {backend})')
                return fallback_token, time.time() + 3600
            raise _PotMintError(
                'GenerateIT returned no integrity token '
                f'(JS backend: {backend}, snapshot '
                f'{len(snapshot["response"])} chars, '
                f'minter function: {snapshot.get("hasMinterFn")})')

        _check_deadline(deadline, 'minter setup')
        setup = session.op_driven(
            {'op': 'mint_setup', 'integrityToken': integrity_token},
            'mint_setup', _stage_budget(deadline, _MINT_TIMEOUT))
        if setup.get('status') != 'ready':
            raise _PotMintError(f'minter setup failed: {setup}')

        expires_at = time.time() + (ttl if isinstance(ttl, (int, float))
                                    and ttl > 0 else 3600)
        _minter_state['ready'] = True
        _minter_state['integrity_expires_at'] = expires_at
        _minter_state['backend'] = backend

        result = session.op_driven(
            {'op': 'mint', 'binding': binding}, 'mint',
            _stage_budget(deadline, _MINT_TIMEOUT))
        if result.get('status') != 'token' or not result.get('token'):
            _reset_minter_state()
            raise _PotMintError(f'mint failed: {result}')
        return result['token'], expires_at

    # -- network steps (all via yt-dlp networking) --------------------

    def _fetch_text(self, request: PoTokenRequest, url: str,
                    data: bytes | None = None,
                    headers: dict | None = None,
                    deadline: float | None = None) -> str:
        timeout = _NETWORK_TIMEOUT
        if deadline is not None:
            _check_deadline(deadline, f'fetch {url}')
            timeout = max(1.0, min(_NETWORK_TIMEOUT,
                                   _remaining(deadline)))
        response = self._request_webpage(
            Request(url, data=data, headers=headers or {},
                    extensions={'timeout': timeout}),
            pot_request=request)
        return response.read().decode('utf-8', errors='replace')

    def _fetch_challenge(self, request: PoTokenRequest,
                         deadline: float | None = None):
        """BotGuard challenge + the ytcfg of the SAME page it came
        from (the VM reads yt.config_.EVENT_ID while snapshotting;
        the bgutil server warns that a challenge paired with another
        page's config is rejected). Prefers the extractor's video
        webpage; falls back to a fresh homepage request."""
        webpage = request.video_webpage
        if webpage:
            challenge = self._get_attestation(webpage)
            if challenge:
                return challenge, self._parse_ytcfg(webpage)
        homepage = self._fetch_text(
            request, _HOMEPAGE_URL, headers={'User-Agent': _USER_AGENT},
            deadline=deadline)
        challenge = self._get_attestation(homepage)
        if not challenge:
            raise _PotMintError(
                'BotGuard challenge (ytAtN) not found in the '
                'YouTube webpage or homepage')
        return challenge, self._parse_ytcfg(homepage)

    def _fetch_interpreter(self, request: PoTokenRequest,
                           challenge: dict,
                           deadline: float | None = None) -> str:
        inline = traverse_obj(
            challenge, ('interpreterJavascript',
                        'privateDoNotAccessOrElseSafeScriptWrappedValue'))
        if inline:
            return inline
        url = traverse_obj(
            challenge, ('interpreterUrl',
                        'privateDoNotAccessOrElseTrustedResourceUrlWrappedValue'))
        if not url:
            raise _PotMintError(
                'BotGuard challenge carries no interpreter (neither '
                'inline script nor interpreterUrl)')
        if url.startswith('//'):
            url = 'https:' + url
        elif url.startswith('/'):
            url = 'https://www.youtube.com' + url
        return self._fetch_text(request, url,
                                headers={'User-Agent': _USER_AGENT},
                                deadline=deadline)

    def _generate_it(self, request: PoTokenRequest, snapshot_response: str,
                     deadline: float | None = None):
        body = json.dumps([_WAA_REQUEST_KEY, snapshot_response]).encode()
        text = self._fetch_text(
            request, _WAA_GENERATE_IT_URL, data=body, headers={
                'Content-Type': 'application/json+protobuf',
                'X-Goog-Api-Key': _GOOG_API_KEY,
                'X-User-Agent': 'grpc-web-javascript/0.1',
                'User-Agent': _USER_AGENT,
            }, deadline=deadline)
        try:
            parsed = json.loads(text)
        except Exception as e:
            raise _PotMintError(f'GenerateIT response is not JSON: {e}')
        if not isinstance(parsed, list):
            raise _PotMintError('GenerateIT response is not an array')
        return parsed

    # -- page parsing (own implementation of the standard extraction)

    def _get_attestation(self, webpage: str | None):
        """Extract the BotGuard challenge (bgChallenge) embedded in a
        YouTube page's window.ytAtN(...) call (or the legacy
        window.ytAtR string form)."""
        if not webpage:
            return None
        raw = traverse_obj(
            self.ie._search_regex(
                r'''(?sx)window\s*\.\s*ytAtN\s*\(\s*
                    (?P<js>\{.+?}\s*)
                \s*\)\s*;''', webpage, 'ytAtN challenge', default=None),
            ({js_to_json}, {json.loads}, 'R'))
        if not raw:
            raw = traverse_obj(
                self.ie._search_regex(
                    r'''(?sx)window\.ytAtR\s*=\s*(?P<raw>(?P<q>['"])
                        (?:
                            \\.|
                            (?!(?P=q)).
                        )*
                    (?P=q))\s*;''', webpage, 'ytAtR challenge', default=None),
                ({js_to_json}, {json.loads}))
        challenge = traverse_obj(raw, ({json.loads}, 'bgChallenge'))
        return challenge or None

    def _parse_ytcfg(self, webpage: str | None):
        """The page's ytcfg.set({...}) object (installed as
        yt.config_ for the VM), or None when not found/parsable."""
        if not webpage:
            return None
        raw = self.ie._search_regex(
            r'ytcfg\.set\((\{.+?\})\);', webpage, 'ytcfg', default=None)
        if not raw:
            return None
        try:
            parsed = json.loads(js_to_json(raw))
        except Exception:
            return None
        return parsed if isinstance(parsed, dict) else None


@register_preference(VyraOnDevicePTP)
def vyra_ondevice_pot_preference(provider, request):
    # Above bgutil:http (130): when the owner explicitly enabled
    # on-device minting it is the preferred path; the server provider
    # (and no token at all) remain the fallbacks.
    return 1000


__all__ = [
    'VyraOnDevicePTP',
    'vyra_ondevice_pot_preference',
    'record_event',
    'drain_events',
]
