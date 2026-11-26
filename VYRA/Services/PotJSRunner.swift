import Foundation
import JavaScriptCore
import UIKit
import WebKit

/// Host side of `_host.pot_js` / `_host.pot_js_reset`: the JavaScript
/// environment the on-device PO token provider (pot_ondevice.py)
/// runs Google's BotGuard VM in.
///
/// The environment must be PERSISTENT across bridge calls — the VM,
/// its snapshot state and the WebPO minter live in it while Python
/// performs the network steps (challenge fetch, GenerateIT) between
/// JS phases — and each call returns the evaluation's completion
/// value (the driver's JSON op result), not console output.
///
/// Backends, chosen at reset:
///  - `webview` (preferred): a hidden WKWebView holding an empty
///    page on the youtube.com origin. The BotGuard VM gets a real
///    WebKit DOM — the class of environment it accepts (the same
///    approach as Android WebView PO token generators). The page is
///    a clean room: no YouTube scripts run in it, and the extraction
///    session's cookies are NOT shared with it — session binding
///    comes from yt-dlp's PoTokenRequest, which Python mints for;
///    the WebView only supplies the execution environment.
///  - `jsc`: a bare persistent JSContext with the driver's
///    hand-written shims. The machinery works (VM executes,
///    snapshot completes, GenerateIT round trip succeeds), but a
///    bare engine's snapshot is environment-poor, so Google may
///    answer GenerateIT with only a websafe fallback token. Kept as
///    the fallback when no WebView can be created.
final class PotJSRunner: @unchecked Sendable {
    static let shared = PotJSRunner()

    private enum Backend {
        case webview
        case jsc
    }

    private let lock = NSLock()
    private var backend: Backend?
    private var jscContext: JSContext?
    private var jscException: String?
    private let webViewHost = PotWebViewHost()

    private init() {}

    /// Tears the current environment down and creates a fresh one.
    /// `preference` is "auto", "webview" or "jsc" (provider setting).
    /// Returns the JSON the Python side expects: {"backend": ...}.
    func reset(preference: String) -> (output: String, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return resetLocked(preference: preference)
    }

    /// Starts the WebView backend's process and first page load
    /// in the background (fire and forget). See
    /// vyraRegisterPotRunners for why this happens at startup.
    func warmUpWebView() {
        webViewHost.warmUp()
    }

    /// Evaluates one driver op script in the current environment
    /// (creating an "auto" environment first if none exists) and
    /// returns its completion value.
    func eval(_ script: String) -> (output: String, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        if backend == nil {
            let resetResult = resetLocked(preference: "auto")
            if let error = resetResult.error { return ("", error) }
        }
        switch backend {
        case .webview:
            // The host dispatches to the main queue and waits
            // itself; wrapping it in a blocking main.sync would
            // freeze the very loop WebKit needs.
            let (value, error) = webViewHost.evaluate(script)
            if let error { return ("", error) }
            return (value ?? "", nil)
        case .jsc, .none:
            let (value, error) = jscEval(script)
            if let error { return ("", error) }
            return (value ?? "", nil)
        }
    }

    // MARK: Private

    private func resetLocked(preference: String) -> (output: String, error: String?) {
        // No teardown of the WebView host: a fresh JS context does
        // not need a fresh WKWebView. Reloading the empty page
        // gives the session a clean JS realm while the WebContent
        // process stays warm — recreating the WebView paid the
        // full process launch again on every reset (10-30s in the
        // CI simulator, and a real cost on device too).
        jscContext = nil
        backend = nil
        if preference != "jsc" {
            let prepareError = webViewHost.resetPage()
            if prepareError == nil {
                backend = .webview
                return ("{\"backend\": \"webview\"}", nil)
            }
            if preference == "webview" {
                return ("", "WKWebView POT environment unavailable: \(prepareError ?? "unknown error")")
            }
            // "auto": fall through to the JSC backend.
        }
        jscContext = JSContext()
        if jscContext == nil {
            return ("", "Could not create JSContext for the POT environment")
        }
        backend = .jsc
        return ("{\"backend\": \"jsc\"}", nil)
    }

    private func jscEval(_ script: String) -> (value: String?, error: String?) {
        if jscContext == nil { jscContext = JSContext() }
        guard let context = jscContext else {
            return (nil, "Could not create JSContext")
        }
        jscException = nil
        context.exceptionHandler = { [weak self] _, exception in
            self?.jscException = exception?.toString() ?? "Unknown JavaScript error"
        }
        let value = context.evaluateScript(script)
        if let jscException { return (nil, jscException) }
        return (value?.toString(), nil)
    }
}

/// The hidden WKWebView holding the POT page.
///
/// Threading: the bridge calls in from Python (background)
/// threads, and WebKit must be driven from the main thread —
/// but the main thread must keep running its OWN run loop while
/// a load or an evaluation is in flight. The previous design
/// blocked the main thread in a hand-spun run loop
/// (RunLoop.run(mode: .default)) while waiting for WebKit
/// callbacks, and in the CI simulator the WebContent process
/// launch then "completed" 0.1-0.6s AFTER whatever deadline
/// the spin used — 10s, 30s and 60s deadlines alike (runs
/// 45650890081 / 45714802910 / 45723307845 / 45727666214):
/// the spin itself starved the launch/navigation machinery,
/// which only finished once the spin ended and the main loop
/// returned to its normal operation. So now the work is
/// dispatched to the main queue and the CALLER waits on a
/// semaphore; WebKit callbacks arrive on the untouched main
/// loop, exactly as in normal app operation. (A caller already
/// on the main thread falls back to the legacy spin, since
/// there is no free loop to wait behind.)
private final class PotWebViewHost: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loadFinished = false
    private var loadFailure: String?
    /// Signalled by the navigation delegate when the in-flight
    /// load resolves. Main-thread access only.
    private var loadWaiter: DispatchSemaphore?
    /// The navigation the current load state belongs to; delegate
    /// callbacks for a superseded navigation (e.g. one that
    /// finished late, after its wait already timed out) must not
    /// resolve a newer load's state.
    private var currentNavigation: WKNavigation?
    /// Environment snapshot taken when a load starts, included
    /// in timeout errors. Written on the main thread.
    private var loadDiagnostics = ""

    private static let pageHTML =
        "<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>"

    /// Creates the WebView and starts its first load without
    /// waiting. The navigation delegate records the outcome;
    /// the next resetPage reloads the page anyway, on what is
    /// then a warm WebContent process.
    func warmUp() {
        let start = {
            if self.webView == nil {
                self.createLocked()
            }
        }
        if Thread.isMainThread {
            start()
        } else {
            DispatchQueue.main.async(execute: start)
        }
    }

    /// Resets the session's page for a fresh JS realm: creates
    /// the WebView on first use, otherwise reloads the empty
    /// page in the existing one so the WebContent process stays
    /// warm across sessions. Returns an error string on failure.
    func resetPage() -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        let start = {
            if self.loadFailure != nil {
                // A page whose load failed gets a fresh WebView.
                self.teardownLocked()
            }
            if self.webView == nil {
                self.createLocked()
            } else {
                self.reloadLocked()
            }
            self.loadWaiter = semaphore
            if self.loadFinished || self.loadFailure != nil {
                semaphore.signal()
            }
        }
        // First-load bound: sub-second on device; this only ever
        // engages on a genuinely stuck load. The Python side's
        // overall mint budget still bounds the full flow.
        let completed = waitForWebKit(timeout: 60, start: start,
                                      semaphore: semaphore)
        if let loadFailure { return loadFailure }
        if completed && loadFinished { return nil }
        return "POT WebView page load timed out (\(loadDiagnostics))"
    }

    /// Evaluates a script and waits for its completion value.
    func evaluate(_ script: String) -> (value: String?, error: String?) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        var failure: String?
        var notPrepared = false
        let start = {
            guard let webView = self.webView else {
                notPrepared = true
                semaphore.signal()
                return
            }
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    failure = error.localizedDescription
                } else if let string = value as? String {
                    result = string
                } else if let value {
                    result = String(describing: value)
                }
                semaphore.signal()
            }
        }
        // 15s cap: bounds how far one evaluation can overshoot
        // the provider's 20s overall mint budget.
        let completed = waitForWebKit(timeout: 15, start: start,
                                      semaphore: semaphore)
        if notPrepared { return (nil, "POT WebView not prepared") }
        if !completed { return (nil, "POT WebView evaluation timed out") }
        return (result, failure)
    }

    // MARK: Main-thread work (the *Locked methods)

    private func createLocked() {
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        wv.navigationDelegate = self
        // Being in a window (hidden) keeps WebKit from treating
        // the page as backgrounded/throttled.
        if let window = Self.keyWindow() {
            wv.isHidden = true
            window.addSubview(wv)
        }
        webView = wv
        loadDiagnostics = Self.diagnostics(
            windowAttached: Self.keyWindow() != nil)
        loadFinished = false
        loadFailure = nil
        currentNavigation = wv.loadHTMLString(
            Self.pageHTML,
            baseURL: URL(string: "https://www.youtube.com/"))
    }

    private func reloadLocked() {
        guard let webView else { return }
        loadDiagnostics = Self.diagnostics(
            windowAttached: webView.window != nil)
        loadFinished = false
        loadFailure = nil
        currentNavigation = webView.loadHTMLString(
            Self.pageHTML,
            baseURL: URL(string: "https://www.youtube.com/"))
    }

    private func teardownLocked() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView?.navigationDelegate = nil
        webView = nil
        loadFinished = false
        loadFailure = nil
        currentNavigation = nil
    }

    /// Dispatches `start` to the main queue and waits on
    /// `semaphore` (signalled by a WebKit callback) for up to
    /// `timeout` seconds, leaving the main run loop to run
    /// normally in the meantime. A caller already on the main
    /// thread runs `start` inline and spins the run loop
    /// instead, as there is no free loop to wait behind.
    /// Returns false on timeout.
    private func waitForWebKit(timeout: TimeInterval,
                               start: @escaping () -> Void,
                               semaphore: DispatchSemaphore) -> Bool {
        if Thread.isMainThread {
            start()
            let deadline = Date().addingTimeInterval(timeout)
            while semaphore.wait(timeout: .now()) != .success {
                if Date() >= deadline { return false }
                RunLoop.main.run(mode: .default,
                                 before: Date(timeIntervalSinceNow: 0.05))
            }
            return true
        }
        DispatchQueue.main.async(execute: start)
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    private static func diagnostics(windowAttached: Bool) -> String {
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        return "appState=\(state), windowAttached=\(windowAttached)"
    }

    // MARK: WKNavigationDelegate

    private func isCurrent(_ navigation: WKNavigation!) -> Bool {
        guard let currentNavigation else { return true }
        return navigation === currentNavigation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isCurrent(navigation) else { return }
        loadFinished = true
        loadWaiter?.signal()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        guard isCurrent(navigation) else { return }
        loadFailure = error.localizedDescription
        loadWaiter?.signal()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard isCurrent(navigation) else { return }
        loadFailure = error.localizedDescription
        loadWaiter?.signal()
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        return scenes.first?.windows.first
    }
}

// MARK: - C callbacks for the Python `_host` module

private let vyraPotJSRunner: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>? = { code, isError in
    guard let code else { return nil }
    let (output, error) = PotJSRunner.shared.eval(String(cString: code))
    if let error {
        isError?.pointee = 1
        return strdup(error)
    }
    return strdup(output)
}

private let vyraPotResetRunner: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>? = { code, isError in
    guard let code else { return nil }
    let (output, error) = PotJSRunner.shared.reset(preference: String(cString: code))
    if let error {
        isError?.pointee = 1
        return strdup(error)
    }
    return strdup(output)
}

/// Registers the POT runners with the C bridge. Called from
/// YtDlpRuntime before vyra_python_initialize.
func vyraRegisterPotRunners() {
    vyra_python_set_pot_js_runner(vyraPotJSRunner)
    vyra_python_set_pot_reset_runner(vyraPotResetRunner)
    // Pay the WebContent process launch now, in the background:
    // the first mint of a session otherwise waits out the cold
    // launch inside its own budget (and in the CI simulator that
    // launch alone has taken over a minute). If POT is never
    // used, the warmed page simply sits idle and hidden.
    PotJSRunner.shared.warmUpWebView()
}
