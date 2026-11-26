import Foundation

/// How PO tokens are obtained (Settings > POトークン）. The default
/// (nothing stored yet) is ON-DEVICE: the on-device mint runs under a
/// hard 20 s budget and fails open, so a token is minted automatically
/// when extraction needs one and a failed mint degrades to tokenless
/// extraction instead of blocking. A mode the user has explicitly
/// stored is always honoured as stored.
enum PotMode: String, CaseIterable, Sendable {
    /// No PO token provider is configured.
    case off
    /// Mint on-device (pot_ondevice.py + the app's JS environment:
    /// a hidden WKWebView, falling back to JavaScriptCore).
    case onDevice
    /// Ask a bgutil PO-token server (LAN PC etc.) via the vendored
    /// bgutil-ytdlp-pot-provider plugin's HTTP mode.
    case server
}

/// PO token provider settings (Settings > POトークン）.
///
/// Mode `server`: when a base URL is set, the bridge passes it to
/// yt-dlp as the `youtubepot-bgutilhttp` extractor-args namespace
/// (base_url) — the settings the pinned yt-dlp's POT director
/// actually hands to the vendored bgutil plugin (GPL-3.0, v2.0.2;
/// only its HTTP mode is bundled, the subprocess-based script mode
/// module is deleted at bootstrap time — see
/// Documentation/THIRD_PARTY_LICENSES.md).
///
/// Mode `onDevice`: the bridge enables the in-process provider
/// (youtubepot-vyraondevice) which mints tokens on the device; see
/// pot_ondevice.py. Minting failure never blocks extraction — the
/// POT director continues without a token and the failure lands in
/// the debug log (kind 'pot').
final class PotProviderSettings: @unchecked Sendable {
    static let shared = PotProviderSettings()

    static let modeDefaultsKey = "vyra.pot.mode"
    static let baseURLDefaultsKey = "vyra.pot.baseURL"
    /// Legacy (pre-mode) server toggle; read only for migration.
    static let enabledDefaultsKey = "vyra.pot.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var mode: PotMode {
        get {
            if let raw = defaults.string(forKey: Self.modeDefaultsKey),
               let stored = PotMode(rawValue: raw) {
                return stored
            }
            // Migration: the pre-mode UI had a single server toggle.
            // Anything else unset falls through to the default:
            // on-device (see the PotMode doc above).
            return defaults.bool(forKey: Self.enabledDefaultsKey) ? .server : .onDevice
        }
        set { defaults.set(newValue.rawValue, forKey: Self.modeDefaultsKey) }
    }

    var baseURLString: String {
        get { defaults.string(forKey: Self.baseURLDefaultsKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.baseURLDefaultsKey) }
    }

    /// Whether on-device minting is enabled (bridge flag).
    var onDeviceEnabled: Bool { mode == .onDevice }

    /// The validated bgutil base URL to hand to the bridge, or nil
    /// unless the mode is `server` and the text is a usable
    /// http(s) URL.
    var activeBaseURL: URL? {
        guard mode == .server else { return nil }
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    /// Whether the current text is non-empty but unusable (Settings
    /// shows a hint instead of silently ignoring it).
    var hasInvalidBaseURLText: Bool {
        mode == .server
            && !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && activeBaseURL == nil
    }
}
