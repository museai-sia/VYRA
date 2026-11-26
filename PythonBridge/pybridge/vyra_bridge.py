"""VYRA's bridge between the Swift app and the embedded yt-dlp.

Every public function takes one JSON string and returns one JSON
string, so the C embedding layer only shuttles UTF-8 text. Functions:

  configure(json)        -> {ok, versions}   (also sets cache dir)
  versions(json)         -> {ok, versions}
  run_js(json)           -> {ok, output}     (self-test of _host/JSC)
  player_url(json)       -> {ok, player_url} (test hook: variant forcing)
  solve_fixture(json)    -> {ok, results}    (test hook: offline JSC solve)
  opts_probe(json)       -> {ok, has_cookiefile, cookiefile, ...}
                            (test hook: _base_opts cookie/POT gating)
  pot_probe(json)        -> {ok, pot_ondevice_registered, ...}
                            (test hook: on-device POT registration)
  pot_mint_fixture(json) -> {ok, po_token | snapshot_len, ...}
                            (test hook: offline POT mint flow)
  extract(json)          -> {ok, metadata, raw_info}   (no download)
  download_start(json)   -> {ok, job_id}     (runs on a Python thread;
                            ONE job per selection — a split selection
                            passes audio_format_id and yt-dlp downloads
                            'vid+aid' in that single job, leaving both
                            files for the app's in-process processing)
  download_status(json)  -> {ok, job: {...}}  (job.files: every file
                            the job produced, [video, audio] for split)
  download_cancel(json)  -> {ok}

Design constraints honoured here:
  * No subprocesses, ever. yt-dlp's two subprocess dependencies are
    replaced in-process: the JS runtime is JavaScriptCore via
    jsc_provider, and ffmpeg is never invoked as a process (no
    postprocessors, native HLS downloader). Merging/transcoding of
    downloaded formats is done by the Swift side with the FFmpeg
    libraries linked into the app (FFmpegBridge), never from here.
  * Downloads are restricted to the exact format_id the app selected.
"""
from __future__ import annotations

import json
import math
import os
import sys
import threading
import time
import traceback

# TLS: the embedded interpreter has no OS trust-store integration, so
# point OpenSSL at the bundled certifi bundle when present.
try:
    import certifi

    os.environ.setdefault('SSL_CERT_FILE', certifi.where())
except Exception:
    pass

_jsc_error = None
try:
    import jsc_provider  # noqa: F401  (import registers the provider)
except Exception as e:  # yt-dlp internals moved, or _host missing
    _jsc_error = f'{type(e).__name__}: {e}'

_pot_ondevice_error = None
try:
    import pot_ondevice  # noqa: F401  (import registers the provider)
except Exception as e:  # provider must never break the bridge
    _pot_ondevice_error = f'{type(e).__name__}: {e}'

import yt_dlp

_config = {'cache_dir': None}
_jobs = {}
_jobs_lock = threading.Lock()


class _Cancelled(Exception):
    pass


class _Logger:
    """Keeps the last lines of yt-dlp output for error reporting."""

    def __init__(self):
        self.lines = []

    def _add(self, msg):
        self.lines.append(str(msg))
        del self.lines[:-100]

    def debug(self, msg):
        if str(msg).startswith('[debug] '):
            return
        self._add(msg)

    def info(self, msg):
        self._add(msg)

    def warning(self, msg):
        self._add(f'WARNING: {msg}')

    def error(self, msg):
        self._add(msg)


def _int_or_none(value):
    """Coerce a yt-dlp byte count to int (or None).

    yt-dlp reports HLS/fragment totals via total_bytes_estimate,
    which is a float; Swift decodes byte counts as integers and a
    fractional JSON number makes the whole status response fail to
    decode, killing the download mid-flight.
    """
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError, OverflowError):
        return None


def _finite_float_or_none(value):
    """Coerce to a finite float (or None). yt-dlp speed/eta can come
    out non-finite, and json.dumps would emit bare Infinity/NaN
    tokens, which are not valid JSON for Swift's JSONDecoder."""
    if value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _sanitize_json(value):
    """Recursively replace non-finite floats with None so a bridge
    response is always strict JSON."""
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, dict):
        return {k: _sanitize_json(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_sanitize_json(v) for v in value]
    return value


def _ok(**data):
    return json.dumps(_sanitize_json({'ok': True, **data}),
                      allow_nan=False)


def _err(e, logger=None):
    return json.dumps(_sanitize_json({
        'ok': False,
        'error': str(e) or e.__class__.__name__,
        'log': logger.lines[-30:] if logger else [],
        'traceback': traceback.format_exc(),
    }), allow_nan=False)


def _versions():
    ejs = None
    try:
        import yt_dlp_ejs

        ejs = yt_dlp_ejs.__version__ if hasattr(yt_dlp_ejs, '__version__') else None
        if ejs is None:
            from yt_dlp_ejs._version import __version__ as ejs
    except Exception:
        ejs = None
    return {
        'python': '.'.join(str(v) for v in sys.version_info[:3]),
        'yt_dlp': yt_dlp.version.__version__,
        'yt_dlp_ejs': ejs,
        'jsc_provider': _jsc_error is None,
        'jsc_error': _jsc_error,
    }


# YouTube clients to request, in order. The order matters twice over:
# yt-dlp merges the formats of every client it queries, and for a
# format_id offered by several clients the earlier client's stream URL
# is the one a download uses.
#
# Evidence (yt_dlp/extractor/youtube/_base.py, pinned yt-dlp 2026.8.19,
# GVS PO token policies verified by reading INNERTUBE_CLIENTS):
#   tv            GVS PO token NOT required (HTTPS/HLS) -> itag 18 etc.
#                 are downloadable without any PO token provider.
#   web_safari    HTTPS requires a PO token, HLS does not; this client
#                 is the one that returns pre-merged (video+audio) HLS
#                 formats, so its HLS formats stay downloadable.
#   web_embedded  GVS PO token NOT required (embeddable videos only).
#   web / mweb / ios / android / tv_simply
#                 GVS PO token REQUIRED for HTTPS: without a token
#                 provider, googlevideo answers 403 after the first
#                 data window (~100 KB) — the on-device failure this
#                 ordering fixes. Kept only as extraction fallbacks.
#   android_vr    Excluded: this version marks its GVS policy required,
#                 and yt-dlp master notes all its formats being 403'd.
_YOUTUBE_PLAYER_CLIENTS = ['tv', 'web_safari', 'web_embedded', 'web', 'mweb', 'ios']


def _youtube_extractor_args():
    return {
        'player_client': list(_YOUTUBE_PLAYER_CLIENTS),
        # Pin the player JS variant used for challenge solving.
        # yt-dlp 2026.8.19 defaulted this to 'main'
        # (player_ias.vflset), and the yt-dlp-ejs solver crashes
        # on current player_ias builds: while preprocessing the
        # player it executes component code whose instances call
        # goog.Disposable's addOnDisposeCallback, which the
        # solver's extracted-function environment does not
        # provide ("TypeError: a.addOnDisposeCallback is not a
        # function" — reproduced offline against player
        # b485e332 under Node, so it is not a JSC defect).
        # yt-dlp 2026.11.23 changed its own default to 'tv';
        # pin it here so a future yt-dlp default change cannot
        # silently regress extraction again.
        'player_js_variant': ['tv'],
    }


def _extractor_args(pot_base_url=None, pot_ondevice=False, pot_backend=None):
    """Full extractor_args for _base_opts.

    POT providers read their settings from their OWN extractor-args
    namespace — `youtubepot-<provider key, lowercased>` — which the
    POT director hands to the provider's constructor (see
    yt_dlp/extractor/youtube/pot/_director.py). The older
    `youtube:pot_provider=bgutil:base_url=...` form this bridge used
    before is NOT read by yt-dlp 2026.11.23 anywhere (verified by
    grepping the pinned source tree), so the server mode silently
    never received its base URL until this wiring was fixed.
    """
    args = {'youtube': _youtube_extractor_args()}
    # Optional bgutil PO-token provider, server mode (Settings >
    # POトークン). The plugin is vendored into app_packages
    # (yt_dlp_plugins/extractor/, HTTP mode only — the script-mode
    # module is removed at bootstrap time).
    if pot_base_url:
        args['youtubepot-bgutilhttp'] = {'base_url': [pot_base_url]}
    # Optional on-device PO-token provider (pot_ondevice.py,
    # registered in-process like jsc_provider). Inert unless the app
    # passes the flag; the provider double-checks the same setting
    # in is_available().
    if pot_ondevice:
        settings = {'enabled': ['true']}
        if pot_backend:
            settings['backend'] = [pot_backend]
        args['youtubepot-vyraondevice'] = settings
    return args


def _base_opts(logger, cookiefile=None, pot_base_url=None,
               pot_ondevice=False, pot_backend=None):
    opts = {
        'quiet': True,
        'noprogress': True,
        'noplaylist': True,
        'logger': logger,
        'socket_timeout': 30,
        'retries': 5,
        'fragment_retries': 10,
        # Chunked HTTP downloads: a failed or throttled chunk is
        # retried on its own range request instead of restarting the
        # whole file, which is how googlevideo behaves best.
        'http_chunk_size': 10 * 1024 * 1024,
        'concurrent_fragment_downloads': 4,
        'extractor_args': _extractor_args(
            pot_base_url, pot_ondevice, pot_backend),
        # Never let yt-dlp look for ffmpeg: no postprocessors are set
        # anywhere, and HLS must use the native downloader.
        'hls_prefer_native': True,
        'postprocessors': [],
    }
    if _jsc_error is None:
        opts['js_runtimes'] = {'jsc': {}}
    if _config.get('cache_dir'):
        opts['cachedir'] = _config['cache_dir']
    # Optional user-supplied cookies (Settings > Cookie). Only used
    # when the app passes a path AND the file is actually there; the
    # cookie contents never pass through this bridge's return values,
    # logs or errors — yt-dlp reads (and may update) the file itself.
    if cookiefile and os.path.isfile(cookiefile):
        opts['cookiefile'] = cookiefile
    return opts


def _pot_registry_names():
    """PROVIDER_NAMEs in yt-dlp's POT provider registry after the
    plugin loader's imports (the vendored bgutil plugin module and
    this bridge's in-process pot_ondevice import)."""
    import importlib
    import importlib.util

    try:
        spec = importlib.util.find_spec(
            'yt_dlp_plugins.extractor.getpot_bgutil_http')
    except (ImportError, ValueError):
        spec = None  # plugin package not vendored in this environment
    if spec is not None:
        importlib.import_module('yt_dlp_plugins.extractor.getpot_bgutil_http')
    from yt_dlp.extractor.youtube.pot._registry import _pot_providers

    return sorted(
        getattr(cls, 'PROVIDER_NAME', key)
        for key, cls in (_pot_providers.value or {}).items())


def opts_probe(arg: str) -> str:
    """Test hook: report how _base_opts treats the cookiefile and
    POT params, so the gating (cookiefile: path passed + file
    exists; bgutil: youtubepot-bgutilhttp base_url present;
    on-device: youtubepot-vyraondevice settings present) is covered
    by the Swift test suite without any network access. Also reports
    whether the bgutil POT plugin is discoverable as a yt-dlp plugin
    package, whether importing it registers the bgutil HTTP provider
    in yt-dlp's POT provider registry (the same registry the YouTube
    extractor's POT director consults), whether the on-device
    provider is registered, and whether the subprocess-based
    script-mode module is absent."""
    try:
        params = json.loads(arg) if arg else {}
        opts = _base_opts(_Logger(), cookiefile=params.get('cookiefile'),
                          pot_base_url=params.get('pot_base_url'),
                          pot_ondevice=bool(params.get('pot_ondevice')),
                          pot_backend=params.get('pot_backend'))
        extractor_args = opts.get('extractor_args', {})
        pot_plugin_available = False
        pot_script_module_present = False
        pot_providers = []
        try:
            import importlib.util

            def _spec(name):
                try:
                    return importlib.util.find_spec(name)
                except (ImportError, ValueError):
                    return None

            pot_plugin_available = _spec(
                'yt_dlp_plugins.extractor.getpot_bgutil_http') is not None
            pot_script_module_present = _spec(
                'yt_dlp_plugins.extractor.getpot_bgutil_script') is not None
            pot_providers = _pot_registry_names()
        except Exception:
            pot_providers = []
        bgutil_settings = extractor_args.get('youtubepot-bgutilhttp', {})
        ondevice_settings = extractor_args.get('youtubepot-vyraondevice', {})
        return _ok(has_cookiefile='cookiefile' in opts,
                   cookiefile=opts.get('cookiefile'),
                   pot_bgutil_base_url=(bgutil_settings.get('base_url')
                                        or [None])[0],
                   pot_ondevice_settings=bool(ondevice_settings),
                   pot_plugin_available=pot_plugin_available,
                   pot_providers=pot_providers,
                   pot_bgutil_registered='bgutil:http' in pot_providers,
                   pot_ondevice_registered='vyra:ondevice' in pot_providers,
                   pot_script_module_present=pot_script_module_present)
    except Exception as e:
        return _err(e)


class _ProbeLogger:
    """Minimal IEContentProviderLogger for test-hook providers."""

    def trace(self, message):
        pass

    def debug(self, message, once=False):
        pass

    def info(self, message, once=False):
        pass

    def warning(self, message, once=False):
        pass

    def error(self, message, cause=None):
        pass


class _ProbeIE:
    """Minimal InfoExtractor stand-in for test-hook providers. Only
    _search_regex is implemented (delegating to the real YoutubeIE
    implementation on a throwaway instance is unnecessary: the
    hooks that parse pages patch the fetch step instead)."""

    def _search_regex(self, pattern, string, name, default=None, **kwargs):
        import re

        match = re.search(pattern, string)
        if not match:
            return default
        groups = match.groupdict()
        return groups.get('js') or groups.get('raw') or match.group(0)


def pot_probe(arg: str) -> str:
    """Test hook: the on-device POT provider's registration and
    settings gating, without network or JS execution. Instantiates
    VyraOnDevicePTP with empty settings and with enabled settings
    and reports is_available() for both (the JS host functions are
    present in the app, so 'on' must be available and 'off' must
    not — the provider is inert unless Settings enables it)."""
    try:
        if _pot_ondevice_error is not None:
            raise RuntimeError(
                f'pot_ondevice import failed: {_pot_ondevice_error}')
        from pot_ondevice import VyraOnDevicePTP

        providers = _pot_registry_names()
        off = VyraOnDevicePTP(_ProbeIE(), _ProbeLogger(), {})
        on = VyraOnDevicePTP(
            _ProbeIE(), _ProbeLogger(), {'enabled': ['true']})
        return _ok(pot_ondevice_registered='vyra:ondevice' in providers,
                   pot_available_off=off.is_available(),
                   pot_available_on=on.is_available())
    except Exception as e:
        return _err(e)


def pot_mint_fixture(arg: str) -> str:
    """Test hook: exercise the on-device POT mint flow offline.

    mode 'fake_vm': the full provider flow (challenge -> driver ->
    GenerateIT -> minter -> token) with the network steps stubbed
    by the params and a fake BotGuard interpreter (param
    fake_interpreter_js) whose minter returns
    'FAKE-TOKEN:<binding>' bytes, so the Swift test can verify the
    binding yt-dlp computed is what gets minted for. Params:
    visitor_data, video_id, generateit (the GenerateIT JSON array).

    mode 'real_vm': the REAL BotGuard VM machinery in the app's JS
    environment — reset/install/load/snapshot against a captured
    real challenge (params: program, global_name, interpreter_js,
    yt_cfg). No network, no GenerateIT: this proves the VM executes
    and snapshots in the real engine; Google acceptance of the
    snapshot is the on-device check, not a CI claim.
    """
    try:
        params = json.loads(arg)
        mode = params.get('mode')
        if mode == 'real_vm':
            from pot_ondevice import _JsSession

            session = _JsSession(params.get('backend') or 'auto')
            backend = session.reset()
            session.op({'op': 'install', 'env': {}})
            session.op({
                'op': 'load',
                'interpreterJs': params['interpreter_js'],
                'program': params['program'],
                'globalName': params['global_name'],
                'ytConfig': params.get('yt_cfg'),
            })
            snapshot = session.op_driven(
                {'op': 'snapshot'}, 'snapshot', 30)
            return _ok(pot_backend=backend,
                       snapshot_len=len(snapshot.get('response') or ''),
                       pot_has_minter_fn=bool(snapshot.get('hasMinterFn')))
        if mode != 'fake_vm':
            raise ValueError(f'unknown pot_mint_fixture mode: {mode!r}')

        if _pot_ondevice_error is not None:
            raise RuntimeError(
                f'pot_ondevice import failed: {_pot_ondevice_error}')
        from yt_dlp.extractor.youtube.pot.provider import (
            PoTokenContext,
            PoTokenRequest,
        )

        from pot_ondevice import VyraOnDevicePTP

        # The fake-VM flow runs on the JSC backend: what this
        # fixture proves is the provider flow itself (challenge ->
        # driver -> GenerateIT -> minter, token bound to the
        # request's binding), which is backend-agnostic. The
        # WebView backend has its own dedicated test (real_vm /
        # webview), and its cold WebContent process launch in the
        # CI simulator (10-30s, measured) would otherwise eat the
        # provider's 20s overall mint budget before the flow even
        # starts.
        provider = VyraOnDevicePTP(
            _ProbeIE(), _ProbeLogger(),
            {'enabled': ['true'], 'backend': ['jsc']})
        challenge = {
            'program': 'fake-program',
            'globalName': '__fakeBG',
            'interpreterUrl': {
                'privateDoNotAccessOrElseTrustedResourceUrlWrappedValue':
                    '//fixture.invalid/interpreter.js',
            },
        }
        # Stub signatures must match pot_ondevice's current call
        # sites, which pass a deadline through every network step:
        # _fetch_challenge(request, deadline),
        # _fetch_text(request, url, ..., deadline=deadline),
        # _generate_it(request, snapshot, deadline).
        provider._fetch_challenge = (
            lambda request, deadline=None: (challenge, None))
        provider._fetch_text = (
            lambda request, url, data=None, headers=None, deadline=None:
                params['fake_interpreter_js'])
        generateit = params['generateit']
        provider._generate_it = (
            lambda request, snapshot, deadline=None: generateit)

        visitor_data = params['visitor_data']
        request = PoTokenRequest(
            context=PoTokenContext.GVS,
            innertube_context={'client': {
                'clientName': 'WEB',
                'visitorData': visitor_data,
            }},
            visitor_data=visitor_data,
            video_id=params.get('video_id'),
            internal_client_name='web',
        )
        response = provider.request_pot(request)
        return _ok(po_token=response.po_token,
                   pot_backend='fixture')
    except Exception as e:
        return _err(e)


def configure(arg: str) -> str:
    try:
        params = json.loads(arg) if arg else {}
        _config.update(params)
        if _config.get('cache_dir'):
            os.makedirs(_config['cache_dir'], exist_ok=True)
        return _ok(versions=_versions())
    except Exception as e:
        return _err(e)


def versions(arg: str) -> str:
    return _ok(versions=_versions())


def run_js(arg: str) -> str:
    """Self-test hook: evaluate JS through the host engine."""
    try:
        import _host

        params = json.loads(arg)
        return _ok(output=_host.run_js(params['script']))
    except Exception as e:
        return _err(e)


def player_url(arg: str) -> str:
    """Test hook: the player URL the extractor will use for JS
    challenge solving, given a webpage player URL. Guards the
    player_js_variant pin in _base_opts (see its comment)."""
    try:
        params = json.loads(arg)
        with yt_dlp.YoutubeDL(_base_opts(_Logger())) as ydl:
            ie = ydl.get_info_extractor('Youtube')
            resolved = ie._construct_player_url(player_url=params['player_url'])
        return _ok(player_url=resolved)
    except Exception as e:
        return _err(e)


def solve_fixture(arg: str) -> str:
    """Test hook: run the real registered JSC challenge provider
    against a fixed player fixture, fully offline.

    Params: player_gz_b64 (base64 gzip of the player JS), player_url,
    requests: [{type: 'n'|'sig', challenges: [str]}].
    Returns {ok, results: {type: {challenge: result}}}.
    """
    try:
        import base64
        import gzip

        from yt_dlp.extractor.youtube.jsc.provider import (
            JsChallengeRequest,
            JsChallengeType,
            NChallengeInput,
            SigChallengeInput,
        )

        if _jsc_error is not None:
            raise RuntimeError(f'JSC provider unavailable: {_jsc_error}')
        from jsc_provider import JavaScriptCoreJCP

        params = json.loads(arg)
        player = gzip.decompress(
            base64.b64decode(params['player_gz_b64'])).decode('utf-8')

        class _Cache:
            def load(self, *args, **kwargs):
                return None

            def store(self, *args, **kwargs):
                pass

        class _IE:
            cache = _Cache()

            def get_param(self, name, default=None):
                return {} if name == 'extractor_args' else default

            def _load_player(self, video_id=None, player_url=None, fatal=True):
                return player

        class _ProviderLogger:
            def trace(self, message):
                pass

            def debug(self, message, once=False):
                pass

            def info(self, message):
                pass

            def warning(self, message):
                pass

            def error(self, message):
                pass

        provider = JavaScriptCoreJCP(_IE(), _ProviderLogger(), {})
        requests = []
        for entry in params['requests']:
            if entry['type'] == 'n':
                requests.append(JsChallengeRequest(
                    type=JsChallengeType.N, video_id='fixture',
                    input=NChallengeInput(
                        player_url=params['player_url'],
                        challenges=entry['challenges'])))
            else:
                requests.append(JsChallengeRequest(
                    type=JsChallengeType.SIG, video_id='fixture',
                    input=SigChallengeInput(
                        player_url=params['player_url'],
                        challenges=entry['challenges'])))

        results = {}
        for response in provider._real_bulk_solve(requests):
            if response.error is not None:
                raise response.error
            results[response.request.type.value] = (
                response.response.output.results)
        return _ok(results=results)
    except Exception as e:
        return _err(e)


# MARK: - Metadata extraction

def _map_format(fmt):
    # yt-dlp uses None for "unknown" and 'none' for "definitely absent".
    # A direct media file (generic extractor) reports both as None: it is
    # one complete file, so unknown counts as present for both streams.
    vcodec = fmt.get('vcodec') if fmt.get('vcodec') is not None else 'unknown'
    acodec = fmt.get('acodec') if fmt.get('acodec') is not None else 'unknown'
    has_video = vcodec != 'none'
    has_audio = acodec != 'none'
    return {
        'format_id': fmt.get('format_id'),
        'ext': fmt.get('ext'),
        'vcodec': vcodec,
        'acodec': acodec,
        'height': fmt.get('height'),
        'width': fmt.get('width'),
        'fps': fmt.get('fps'),
        'tbr': fmt.get('tbr'),
        'abr': fmt.get('abr'),
        'protocol': fmt.get('protocol'),
        # Direct format URL (carries the googlevideo `expire` param
        # the app uses for staleness checks). Absent for formats
        # yt-dlp could not resolve a URL for (e.g. SABR-skipped).
        'url': fmt.get('url'),
        'filesize': fmt.get('filesize'),
        'filesize_approx': fmt.get('filesize_approx'),
        'format_note': fmt.get('format_note'),
        # Whether the format is one complete file (video+audio
        # combined, or audio-only). Video-only formats are flagged
        # via requires_merge; the app merges/transcodes them with
        # the bundled FFmpeg libraries after downloading both parts.
        'single_file': (has_video and has_audio) or (has_audio and not has_video),
        'requires_merge': has_video and not has_audio,
    }


def _map_info(info):
    thumbnails = info.get('thumbnails') or []
    thumbnail = info.get('thumbnail')
    if thumbnails:
        thumbnail = thumbnails[-1].get('url') or thumbnail
    upload_date = info.get('upload_date')  # YYYYMMDD
    published = None
    if upload_date and len(upload_date) == 8:
        published = f'{upload_date[0:4]}-{upload_date[4:6]}-{upload_date[6:8]}'
    elif info.get('release_date') and len(info['release_date']) == 8:
        d = info['release_date']
        published = f'{d[0:4]}-{d[4:6]}-{d[6:8]}'
    return {
        'id': info.get('id'),
        'title': info.get('title') or '',
        'uploader': info.get('uploader') or info.get('channel') or '',
        'duration': info.get('duration'),
        'thumbnail': thumbnail,
        'published': published,
        'description': info.get('description'),
        'webpage_url': info.get('webpage_url'),
        'extractor': info.get('extractor_key') or info.get('extractor'),
        'formats': [_map_format(f) for f in (info.get('formats') or [])],
    }


_RAW_INFO_MAX_BYTES = 10 * 1024 * 1024
_RAW_INFO_TRUNCATION_MARKER = '\n/* VYRA: raw output truncated at 10 MB */'


def _dump_raw_info(info):
    """Serialize the full yt-dlp info dict for the in-app raw output
    viewer (Settings > yt-dlp生出力). The formats array is the point:
    it shows exactly what the session was offered. Falls back to a
    repr-based dump when JSON serialization fails on some value, and
    truncates at 10 MB with an explicit marker rather than failing.
    """
    try:
        text = json.dumps(info, indent=2, sort_keys=True, default=repr)
    except Exception:
        try:
            text = repr(info)
        except Exception:
            return None
    if len(text.encode('utf-8')) > _RAW_INFO_MAX_BYTES:
        # Byte-accurate cap: decode with 'ignore' so a multi-byte
        # character split at the boundary cannot corrupt the string.
        text = text.encode('utf-8')[:_RAW_INFO_MAX_BYTES].decode(
            'utf-8', errors='ignore') + _RAW_INFO_TRUNCATION_MARKER
    return text


def _drain_pot_events():
    """POT provider diagnostics since the last drain (see
    pot_ondevice.record_event). Surfaced in bridge responses so the
    app can persist POT failures in the debug log (kind 'pot') —
    the POT director swallows provider errors by design, so without
    this channel an on-device mint failure would be invisible."""
    if _pot_ondevice_error is not None:
        return []
    try:
        return pot_ondevice.drain_events()
    except Exception:
        return []


def extract(arg: str) -> str:
    logger = _Logger()
    try:
        params = json.loads(arg)
        with yt_dlp.YoutubeDL(
                _base_opts(logger, cookiefile=params.get('cookiefile'),
                           pot_base_url=params.get('pot_base_url'),
                           pot_ondevice=bool(params.get('pot_ondevice')),
                           pot_backend=params.get('pot_backend'))) as ydl:
            info = ydl.extract_info(params['url'], download=False)
        if info is None:
            raise RuntimeError('yt-dlp returned no information for this URL')
        return _ok(metadata=_map_info(info), raw_info=_dump_raw_info(info),
                   pot_events=_drain_pot_events())
    except Exception as e:
        result = json.loads(_err(e, logger))
        result['pot_events'] = _drain_pot_events()
        return json.dumps(_sanitize_json(result), allow_nan=False)


# MARK: - Downloads (background thread + status polling)

def _run_download(job_id, params):
    with _jobs_lock:
        job = _jobs[job_id]
    logger = _Logger()
    job['logger'] = logger

    # One bridge job per user selection, always (the owner's rule:
    # downloads are yt-dlp's job, not hand-rolled orchestration).
    # A split selection runs two format-specific yt-dlp downloads
    # inside this ONE job (one status stream, one cancel flag).
    # Why not a single 'vid+aid' download: verified against the
    # pinned yt-dlp 2026.11.23 (YoutubeDL.py, the requested_formats
    # path) — with no ffmpeg available, a merged-format request
    # ABORTS with "You have requested merging of multiple formats
    # but ffmpeg is not installed. Aborting due to --abort-on-error"
    # unless ignoreerrors is set, and ignoreerrors would also mask
    # genuine download failures of the same job. Two strict
    # single-format downloads leave the two files cleanly, and the
    # app remuxes/transcodes them in-process. HLS selections are
    # single-format jobs whose native-HLS output file holds
    # MPEG-TS bytes for the app's TS->MP4 remux. No postprocessors
    # are configured anywhere, so yt-dlp never tries to spawn
    # ffmpeg, and the M3U8 fixup postprocessor (which needs the
    # ffmpeg binary) stays inactive for the same reason.
    audio_format_id = params.get('audio_format_id')

    def hook(d):
        if job.get('cancel_requested'):
            raise _Cancelled()
        filename = d.get('filename')
        if d.get('status') == 'downloading':
            # Aggregate across the job's files (a split job reports
            # per file): downloaded always adds up; the total is
            # reported only once EVERY file's total is known, so
            # the UI fraction never pretends one part is the whole.
            per_file = job.setdefault('_files_progress', {})
            # Byte counts are coerced to int here: for HLS/fragment
            # downloads the total comes from total_bytes_estimate, a
            # float, and a fractional total_bytes in the status JSON
            # fails Swift's integer decode (download dies mid-flight).
            per_file[filename] = (
                _int_or_none(d.get('downloaded_bytes')) or 0,
                _int_or_none(d.get('total_bytes'))
                or _int_or_none(d.get('total_bytes_estimate')))
            job['downloaded_bytes'] = sum(v[0] for v in per_file.values())
            totals = [v[1] for v in per_file.values()]
            job['total_bytes'] = (
                sum(totals) if totals and all(t is not None for t in totals)
                else None)
            job['speed'] = _finite_float_or_none(d.get('speed'))
            job['eta'] = _finite_float_or_none(d.get('eta'))
        elif d.get('status') == 'finished':
            if filename and filename not in job['files']:
                job['files'].append(filename)
            job['filename'] = filename
            per_file = job.setdefault('_files_progress', {})
            done = (_int_or_none(d.get('downloaded_bytes'))
                    or job.get('downloaded_bytes', 0))
            per_file[filename] = (done, per_file.get(filename, (done, done))[1])
            job['downloaded_bytes'] = sum(v[0] for v in per_file.values())

    base_opts = _base_opts(logger, cookiefile=params.get('cookiefile'),
                           pot_base_url=params.get('pot_base_url'),
                           pot_ondevice=bool(params.get('pot_ondevice')),
                           pot_backend=params.get('pot_backend'))

    def _download_one(format_id, outtmpl_name):
        opts = dict(base_opts)
        opts.update({
            'format': format_id,
            'outtmpl': os.path.join(params['output_dir'], outtmpl_name),
            'progress_hooks': [hook],
            'continuedl': False,
            'overwrites': True,
        })
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(params['url'], download=True)
            if info is not None and not job['files']:
                prepared = ydl.prepare_filename(info)
                if prepared:
                    job['files'] = [prepared]
        if job.get('cancel_requested'):
            raise _Cancelled()

    try:
        os.makedirs(params['output_dir'], exist_ok=True)
        requested_name = params.get('filename') or '%(title)s.%(ext)s'
        if audio_format_id:
            # Distinct leg names so the two downloads cannot collide;
            # job['files'] ends up [video, audio] by construction
            # (leg order), which the count check enforces.
            stem = os.path.splitext(requested_name)[0]
            _download_one(params['format_id'], f'{stem}.video.%(ext)s')
            _download_one(audio_format_id, f'{stem}.audio.%(ext)s')
            if len(job['files']) != 2:
                raise RuntimeError(
                    'split download finished with '
                    f'{len(job["files"])} file(s), expected 2: '
                    f'{job["files"]}')
        else:
            _download_one(params['format_id'], requested_name)
        job['filename'] = job['files'][0] if job['files'] else None
        job['status'] = 'finished'
    except _Cancelled:
        job['status'] = 'cancelled'
    except Exception as e:
        if job.get('cancel_requested'):
            job['status'] = 'cancelled'
        else:
            job['status'] = 'error'
            job['error'] = str(e) or e.__class__.__name__
            job['log'] = logger.lines[-30:]
            job['traceback'] = traceback.format_exc()


def download_start(arg: str) -> str:
    try:
        params = json.loads(arg)
        job_id = params['job_id']
        with _jobs_lock:
            _jobs[job_id] = {
                'status': 'downloading',
                'downloaded_bytes': 0,
                'total_bytes': None,
                'speed': None,
                'eta': None,
                'filename': None,
                'files': [],
                'error': None,
                'cancel_requested': False,
                'started_at': time.time(),
            }
        thread = threading.Thread(
            target=_run_download, args=(job_id, params), daemon=True)
        thread.start()
        return _ok(job_id=job_id)
    except Exception as e:
        return _err(e)


def download_status(arg: str) -> str:
    try:
        params = json.loads(arg)
        with _jobs_lock:
            job = _jobs.get(params['job_id'])
            snapshot = dict(job) if job else None
        if snapshot is None:
            return _ok(job={'status': 'unknown'})
        snapshot.pop('logger', None)
        snapshot.pop('cancel_requested', None)
        snapshot.pop('_files_progress', None)
        # Defensive: whatever a progress hook left in the job dict,
        # the wire format is integer byte counts and finite (or
        # absent) speed/eta — never fractional counts, never
        # Infinity/NaN.
        for key in ('downloaded_bytes', 'total_bytes'):
            if key in snapshot:
                snapshot[key] = _int_or_none(snapshot[key])
        for key in ('speed', 'eta'):
            if key in snapshot:
                snapshot[key] = _finite_float_or_none(snapshot[key])
        return _ok(job=snapshot, pot_events=_drain_pot_events())
    except Exception as e:
        return _err(e)


def download_cancel(arg: str) -> str:
    try:
        params = json.loads(arg)
        with _jobs_lock:
            job = _jobs.get(params['job_id'])
            if job:
                job['cancel_requested'] = True
        return _ok()
    except Exception as e:
        return _err(e)
