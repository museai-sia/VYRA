import Foundation

/// Classifies yt-dlp failure text into the taxonomy しあ's LAN
/// worker (worker.js `classifyTerminalFailure`) uses, so the app and
/// the worker agree on what a failure MEANS:
///
/// - Terminal (video-specific, never fixable by retrying with another
///   cookie): members_only, deleted, private, copyright_removed,
///   account_terminated, drm_protected, live_scheduled,
///   premiere_scheduled. These feed `TerminalFailureStore`.
/// - `unavailable`: may be account/session state — classified for
///   display, but NEVER cached as terminal in-app (the worker's
///   5-consecutive rule is a server-scale mechanism).
/// - Account rate-limited: explicitly NOT terminal and NEVER cached.
///
/// The classified Japanese message is what the UI shows as the
/// primary text; the raw yt-dlp text stays in the detail line and
/// the debug log, unchanged.
struct ClassifiedYtDlpFailure: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case rateLimited
        case liveScheduled
        case premiereScheduled
        case membersOnly
        case deleted
        case `private`
        case copyrightRemoved
        case accountTerminated
        case drmProtected
        case unavailable
    }

    var kind: Kind
    /// Stable machine code (same strings as worker.js).
    var code: String { kind.rawValue }
    /// Primary user-facing Japanese message.
    var message: String
    /// True when the failure is a property of the video itself:
    /// retrying cannot change it, and the result may be cached by
    /// TerminalFailureStore. Rate-limited is NEVER terminal (it is
    /// an account/session state, per the worker's explicit rule),
    /// and `unavailable` is not cached either (the worker's
    /// consecutive-failure counting is server-scale machinery that
    /// しあ rejected for this personal app).
    var isTerminal: Bool {
        switch kind {
        case .rateLimited, .unavailable: return false
        default: return true
        }
    }
}

enum YtDlpFailureClassifier {
    /// Mirrors worker.js exactly: the rate-limit check runs FIRST
    /// (it must win over every other pattern), then the definitions
    /// in the worker's order. Returns nil for unclassified text.
    static func classify(_ text: String) -> ClassifiedYtDlpFailure? {
        if matches("account has been rate-limited by YouTube|this content isn't available, try again later",
                   in: text) {
            return ClassifiedYtDlpFailure(
                kind: .rateLimited,
                message: "YouTubeによりこのアカウントが一時的にレート制限されています。時間をおくか、別のCookieで再試行してください。")
        }
        if let message = scheduledMessage(kind: .liveScheduled, text: text) {
            return ClassifiedYtDlpFailure(kind: .liveScheduled, message: message)
        }
        if let message = scheduledMessage(kind: .premiereScheduled, text: text) {
            return ClassifiedYtDlpFailure(kind: .premiereScheduled, message: message)
        }
        if matches("members-only content|join this channel to get access", in: text) {
            return ClassifiedYtDlpFailure(
                kind: .membersOnly,
                message: "この動画はメンバー限定コンテンツのため取得できません。")
        }
        if matches("this video has been (?:removed|deleted)|video (?:has been|was) deleted|removed by the uploader",
                   in: text) {
            return ClassifiedYtDlpFailure(
                kind: .deleted,
                message: "この動画は削除されているため取得できません。")
        }
        if matches("private video|sign in if you've been granted access", in: text) {
            return ClassifiedYtDlpFailure(
                kind: .private,
                message: "この動画は非公開のため取得できません。")
        }
        if matches("no longer available due to a copyright|copyright claim", in: text) {
            return ClassifiedYtDlpFailure(
                kind: .copyrightRemoved,
                message: "この動画は著作権上の理由で削除されているため取得できません。")
        }
        if matches("account associated with this video has been terminated|uploader has closed their youtube account",
                   in: text) {
            return ClassifiedYtDlpFailure(
                kind: .accountTerminated,
                message: "投稿者のアカウントが停止または削除されているため取得できません。")
        }
        if matches("This video is drm protected and only images are available for download", in: text) {
            return ClassifiedYtDlpFailure(
                kind: .drmProtected,
                message: "この動画はDRM保護されており、画像以外の形式を取得できません。")
        }
        if matches("video unavailable|this video is unavailable", in: text) {
            return ClassifiedYtDlpFailure(
                kind: .unavailable,
                message: "この動画は視聴できない状態のため取得できません。")
        }
        return nil
    }

    /// The classified Japanese message for raw yt-dlp error text, or
    /// nil when the text matches no known pattern.
    static func userMessage(for errorText: String) -> String? {
        classify(errorText)?.message
    }

    // MARK: - Regex helpers (patterns are the worker's, case-insensitive)

    private static func matches(_ pattern: String, in text: String) -> Bool {
        firstMatch(pattern, in: text) != nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Builds the Japanese message for the two scheduled kinds from
    /// the worker's patterns, mapping the captured unit through the
    /// worker's unitJa table (second→秒, minute→分, hour→時間,
    /// day→日）. Returns nil when the pattern does not match.
    static func scheduledMessage(kind: ClassifiedYtDlpFailure.Kind, text: String) -> String? {
        let pattern: String
        let template: (String) -> String
        switch kind {
        case .liveScheduled:
            pattern = "This live event will begin in\\s+(\\d+)\\s+(second|minute|hour|day)s?\\.?"
            template = { "このライブ配信は\($0)後に開始される予約動画です。" }
        case .premiereScheduled:
            pattern = "Premieres in\\s+(\\d+)\\s+(second|minute|hour|day)s?\\.?"
            template = { "この動画は\($0)後にプレミア公開される予約動画です。" }
        default:
            return nil
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 3,
              let amountRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        let amount = String(text[amountRange])
        let unitJa: String
        switch text[unitRange].lowercased() {
        case "second": unitJa = "秒"
        case "minute": unitJa = "分"
        case "hour": unitJa = "時間"
        case "day": unitJa = "日"
        default: return nil
        }
        return template("\(amount)\(unitJa)")
    }
}

/// Format-URL expiry, mirroring worker.js `getExpireMs`: googlevideo
/// URLs carry an `expire` query parameter (epoch seconds); the
/// worker treats a format as usable until 60 seconds BEFORE that
/// instant. Used to notice — before starting a download — that a
/// previously extracted format's URL has gone stale.
enum FormatURLExpiry {
    static let safetyMarginSeconds: TimeInterval = 60

    /// The `expire` instant of a format URL, or nil when the URL has
    /// no usable expire parameter.
    static func expirationDate(of urlString: String?) -> Date? {
        guard let urlString,
              let components = URLComponents(string: urlString),
              let raw = components.queryItems?.first(where: { $0.name == "expire" })?.value,
              let epoch = TimeInterval(raw), epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// When the format stops being safely usable (expiry − 60s), or
    /// nil when no expiry is known (unknown is NOT treated as stale).
    static func usableUntil(of urlString: String?) -> Date? {
        expirationDate(of: urlString)?.addingTimeInterval(-safetyMarginSeconds)
    }

    static func isStale(_ urlString: String?, now: Date = Date()) -> Bool {
        guard let until = usableUntil(of: urlString) else { return false }
        return now >= until
    }
}


