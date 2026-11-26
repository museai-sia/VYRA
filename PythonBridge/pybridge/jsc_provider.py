"""yt-dlp JS challenge provider backed by JavaScriptCore (VYRA).

Written for VYRA against yt-dlp's JS Challenge Provider API
(``yt_dlp.extractor.youtube.jsc.provider``, yt-dlp 2026.x). iOS cannot
spawn the external JS runtimes yt-dlp normally uses (deno/node/bun/qjs
have no iOS builds and subprocesses are forbidden in the sandbox), so
this provider registers a runtime named ``jsc`` whose solver scripts
(the official yt-dlp-ejs bundles) are evaluated in-process by the app
through the ``_host`` module, which the app implements in C on top of
JavaScriptCore: ``_host.run_js(script) -> str`` evaluates the script
and returns everything it wrote to ``console.log``.

Importing this module registers the provider globally; if the import
fails (e.g. a future yt-dlp moved its internals), the bridge catches it
and yt-dlp simply runs without a JS runtime (reduced format set).
"""
from __future__ import annotations

import _host

from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeProviderError,
    register_preference,
    register_provider,
)
from yt_dlp.extractor.youtube.pot._provider import BuiltinIEContentProvider
from yt_dlp.globals import supported_js_runtimes
from yt_dlp.utils._jsruntime import JsRuntime, JsRuntimeInfo


class _JavaScriptCoreRuntime(JsRuntime):
    """A JsRuntime that needs no executable: evaluation is in-process."""

    def _info(self):
        return JsRuntimeInfo(
            name='javascriptcore', path='builtin',
            version='1.0', version_tuple=(1, 0))


supported_js_runtimes.value['jsc'] = _JavaScriptCoreRuntime


@register_provider
class JavaScriptCoreJCP(EJSBaseJCP, BuiltinIEContentProvider):
    # Class name must end in "JCP" (yt-dlp provider registry rule).
    PROVIDER_NAME = 'javascriptcore'
    JS_RUNTIME_NAME = 'jsc'

    def _run_js_runtime(self, stdin: str, /) -> str:
        try:
            return _host.run_js(stdin)
        except RuntimeError as e:
            raise JsChallengeProviderError(
                f'JavaScriptCore evaluation failed: {e}') from e


@register_preference(JavaScriptCoreJCP)
def _jsc_preference(provider, requests):
    # Prefer the in-process runtime over any external one (none can run
    # on iOS anyway, but keep the ordering explicit).
    return 900
