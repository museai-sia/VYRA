//
//  PyBridge.h
//  VYRA — minimal C embedding layer for the bundled CPython interpreter.
//
//  The app talks to Python exclusively through JSON strings:
//  vyra_python_call("extract", "{...}") -> "{...}". The only Python ->
//  app callback is the `_host.run_js` module, which evaluates JavaScript
//  with JavaScriptCore (registered from Swift before initialization).
//

#ifndef VYRA_PYBRIDGE_H
#define VYRA_PYBRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Callback that evaluates `script` with JavaScriptCore and returns a
/// malloc'd UTF-8 string with everything written to console.log.
/// On failure returns a malloc'd error message and sets *is_error != 0.
typedef char *(*vyra_js_runner_t)(const char *script, int *is_error);

/// Registers the JavaScript runner used by `_host.run_js`.
/// Must be called before vyra_python_initialize.
void vyra_python_set_js_runner(vyra_js_runner_t runner);

/// Registers the runners used by `_host.pot_js` /
/// `_host.pot_js_reset` (on-device PO token minting). Unlike
/// `run_js`, `pot_js` evaluates in a PERSISTENT JavaScript
/// environment (the BotGuard VM state survives across calls) and
/// returns the evaluation's completion value (a JSON string), not
/// console output. `pot_js_reset` takes a backend preference
/// ("auto" / "webview" / "jsc"), tears the environment down, and
/// returns a malloc'd JSON string like {"backend": "webview"}.
/// Must be called before vyra_python_initialize.
void vyra_python_set_pot_js_runner(vyra_js_runner_t runner);
void vyra_python_set_pot_reset_runner(vyra_js_runner_t runner);

/// Initializes the embedded interpreter. `resource_path` is the app
/// bundle's resource path; it must contain:
///   python/lib/python3.14   (stdlib, installed by the build phase)
///   app_packages/           (yt_dlp, yt_dlp_ejs, certifi)
///   pybridge/               (vyra_bridge.py, jsc_provider.py)
/// Returns NULL on success, or a malloc'd error string (caller frees).
char *vyra_python_initialize(const char *resource_path);

/// Calls `vyra_bridge.<function>(json_arg)` and returns a malloc'd JSON
/// string (caller frees). Never returns NULL.
char *vyra_python_call(const char *function, const char *json_arg);

#ifdef __cplusplus
}
#endif

#endif /* VYRA_PYBRIDGE_H */
