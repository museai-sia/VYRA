import Foundation

/// Derives the selectable formats/qualities from information that is
/// actually available (Phase 3, spec §7). Nothing is invented: a format is
/// offered only when a verified source reports it, or when the URL itself
/// is a direct media file.
enum MediaFormatService {
    static let supportedExtensions: Set<String> = ["mp4", "mov", "m4a"]

    static func isDirectMediaURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func directFormat(for url: URL) -> DownloadFormat? {
        DownloadFormat(rawValue: url.pathExtension.lowercased())
    }

    /// The single real option for a direct file URL: its own container and
    /// "Original" quality (there are no other renditions to choose from).
    static func optionsForDirectURL(_ url: URL, contentType: String? = nil, contentLength: Int64? = nil) -> [MediaFormatOption] {
        guard let format = directFormat(for: url) else { return [] }
        return [MediaFormatOption(
            id: "direct-\(format.rawValue)",
            container: format.rawValue,
            fileExtension: format.fileExtension,
            mimeType: contentType ?? MediaFormatOption.mimeType(forExtension: format.fileExtension),
            displayName: format.displayName,
            isVideo: !format.isAudioOnly,
            isAudio: format.isAudioOnly,
            qualityLabel: DownloadQuality.original.displayName,
            estimatedFileSize: contentLength
        )]
    }

    /// Options from a source's reported formats.
    ///
    /// Offering is NOT narrowed by codec or container (しあ's
    /// order, 2026-11-25): every distinct height yt-dlp reports
    /// becomes one option, and the saved file is always an
    /// AVKit-playable MP4. Per height, the winning format is chosen
    /// by a fixed preference:
    ///   1. a combined HTTPS format that can be saved as-is (avc1
    ///      video + AAC audio in an MP4 container) — processing
    ///      .direct;
    ///   2. a combined HLS format with the same copyable codecs —
    ///      yt-dlp's native HLS downloader delivers MPEG-TS bytes,
    ///      remuxed in-process to MP4 (processing .remuxSingle).
    ///      HLS is NEVER silently dropped: for some videos the ONLY
    ///      formats above 360p a session returns are the HLS
    ///      renditions (the DASH URLs being withheld, e.g. under
    ///      the SABR experiment), and those heights must stay
    ///      selectable;
    ///   3. a split HTTPS pair that can be stream-copied together
    ///      (processing .remux);
    ///   4. otherwise the best-quality format at that height
    ///      regardless of codec/container/protocol (VP9/AV1,
    ///      MP4/WebM, non-copyable HLS) — transcoded in-process to
    ///      H.264 + AAC (.transcode).
    /// Split winners pair with `bestPairedAudio` (AAC preferred,
    /// best other audio otherwise). A split height with NO audio
    /// format at all is not offered: a silent video file is not a
    /// complete download.
    ///
    /// Excluded:
    /// - audio-only formats in a video container (YouTube's ultralow
    ///   audio itags 599/600/233/234 are .mp4 files with no picture —
    ///   offering them as "MP4 video" was the bug behind a 2.2 MB
    ///   "MP4 Original" that contained no video at all). Audio-only
    ///   formats in ANY container are offered as M4A options instead
    ///   (opus/WebM audio is transcoded to AAC);
    /// - HLS *video-only* formats: a split pair is always formed
    ///   within one protocol (the paired audio comes from the plain
    ///   HTTPS formats), so an HLS rendition without its own audio
    ///   track cannot be completed and is not offered.
    static func options(from metadata: VideoMetadata) -> [MediaFormatOption] {
        guard let available = metadata.availableFormats else { return [] }
        let pairedAudio = bestPairedAudio(in: available)
        var options: [MediaFormatOption] = []

        // Audio-only options: one per reported audio format; the
        // selection step picks the best (AAC/direct first).
        for entry in available where entry.isAudioOnly {
            if isHLS(entry) { continue }
            // Audio disguised in a video container stays out of the
            // video list, but as an AUDIO option it is legitimate
            // when its container is a real audio container only —
            // the ultralow .mp4 audio itags are junk renditions and
            // better audio always exists alongside them.
            guard entry.container.lowercased() == "m4a"
                    || entry.container.lowercased() == "webm" else { continue }
            options.append(audioOption(for: entry))
        }

        // Video options: one per distinct height. HLS combined
        // formats compete at their height like everything else;
        // HLS video-only formats are the one exclusion (see the
        // doc comment above).
        var byHeight: [Int: [AvailableMediaFormat]] = [:]
        for entry in available where !entry.isAudioOnly {
            if isHLS(entry), entry.requiresMerge { continue }
            guard let height = entry.height else { continue }
            byHeight[height, default: []].append(entry)
        }
        for height in byHeight.keys.sorted() {
            guard let entries = byHeight[height],
                  let winner = bestVideoCandidate(in: entries) else { continue }
            if winner.requiresMerge {
                // Split winner: needs the paired audio to be a
                // complete file.
                guard let audio = pairedAudio, let audioID = audio.formatID else { continue }
                options.append(splitOption(for: winner, audio: audio, audioID: audioID))
            } else {
                options.append(combinedOption(for: winner))
            }
        }
        return options
    }

    private static func isHLS(_ entry: AvailableMediaFormat) -> Bool {
        entry.protocolName?.contains("m3u8") ?? false
    }

    /// True when the entry's video can be stream-copied into an MP4:
    /// H.264 (avc1) in an MP4 container.
    static func isCopyableVideo(_ entry: AvailableMediaFormat) -> Bool {
        guard !entry.isAudioOnly else { return false }
        guard entry.container.lowercased() == "mp4" else { return false }
        let codec = (entry.videoCodec ?? "").lowercased()
        return codec.hasPrefix("avc1") || codec == "h264"
    }

    /// True when the entry's audio is AAC (stream-copyable into MP4/M4A).
    static func isAACAudio(_ entry: AvailableMediaFormat) -> Bool {
        (entry.audioCodec ?? "").lowercased().hasPrefix("mp4a")
    }

    /// The per-height winner under the documented preference:
    /// the candidateRank tier decides first (direct HTTPS combined,
    /// then HLS combined, then split, then anything), and within a
    /// tier: combined before split, then best quality (total
    /// bitrate, then size, then fps).
    static func bestVideoCandidate(in entries: [AvailableMediaFormat]) -> AvailableMediaFormat? {
        entries.max { candidateRank($0) < candidateRank($1) }
    }

    /// Preference tier of one video candidate (higher wins):
    /// 4 = combined + copyable + plain HTTPS (saves as-is);
    /// 3 = combined + copyable + HLS (TS remux);
    /// 2 = split + copyable video (pair remux/transcode);
    /// 1 = everything else (transcode).
    private static func candidateTier(_ entry: AvailableMediaFormat) -> Int {
        if !entry.requiresMerge, isCopyableVideo(entry), isAACAudio(entry) {
            return isHLS(entry) ? 3 : 4
        }
        if entry.requiresMerge, isCopyableVideo(entry) {
            return 2
        }
        return 1
    }

    /// Lexicographic rank of one video candidate; higher is better.
    /// (Written as a named function: the inline tuple version of this
    /// comparison exceeded the type checker's reasonable-time limit.)
    private static func candidateRank(_ entry: AvailableMediaFormat) -> (Int, Int, Double, Int64, Double) {
        let combinedScore = entry.requiresMerge ? 0 : 1
        let bitrate = entry.totalBitrate ?? -1
        let size = entry.estimatedFileSize ?? -1
        let fps = entry.fps ?? -1
        return (candidateTier(entry), combinedScore, bitrate, size, fps)
    }

    private static func combinedOption(for entry: AvailableMediaFormat) -> MediaFormatOption {
        let copyable = isCopyableVideo(entry) && isAACAudio(entry)
        // A copyable HLS combined format downloads as MPEG-TS bytes
        // and is remuxed to MP4 in-process; a copyable HTTPS one is
        // already the final file. Anything else transcodes.
        let processing: MediaProcessingKind
        if copyable {
            processing = isHLS(entry) ? .remuxSingle : .direct
        } else {
            processing = .transcode
        }
        return MediaFormatOption(
            id: "verified-\(entry.formatID ?? entry.container)-\(entry.qualityLabel ?? "original")",
            container: DownloadFormat.mp4.rawValue,
            fileExtension: DownloadFormat.mp4.fileExtension,
            mimeType: MediaFormatOption.mimeType(forExtension: DownloadFormat.mp4.fileExtension),
            displayName: DownloadFormat.mp4.displayName,
            isVideo: true,
            isAudio: false,
            qualityLabel: entry.qualityLabel,
            estimatedFileSize: entry.estimatedFileSize,
            ytDlpFormatID: entry.formatID,
            audioYtDlpFormatID: nil,
            processing: processing,
            videoCodec: entry.videoCodec,
            audioCodec: entry.audioCodec,
            sourceContainer: entry.container.lowercased(),
            urlExpiresAt: FormatURLExpiry.usableUntil(of: entry.formatURL)
        )
    }

    private static func splitOption(for video: AvailableMediaFormat,
                                    audio: AvailableMediaFormat,
                                    audioID: String) -> MediaFormatOption {
        let size: Int64?
        if let videoSize = video.estimatedFileSize, let audioSize = audio.estimatedFileSize {
            size = videoSize + audioSize
        } else {
            size = nil
        }
        let copyable = isCopyableVideo(video) && isAACAudio(audio)
            && audio.container.lowercased() == "m4a"
        return MediaFormatOption(
            id: "verified-\(video.formatID ?? video.container)-\(video.qualityLabel ?? "original")+\(audioID)",
            container: DownloadFormat.mp4.rawValue,
            fileExtension: DownloadFormat.mp4.fileExtension,
            mimeType: MediaFormatOption.mimeType(forExtension: DownloadFormat.mp4.fileExtension),
            displayName: DownloadFormat.mp4.displayName,
            isVideo: true,
            isAudio: false,
            qualityLabel: video.qualityLabel,
            estimatedFileSize: size,
            ytDlpFormatID: video.formatID,
            audioYtDlpFormatID: audioID,
            processing: copyable ? .remux : .transcode,
            videoCodec: video.videoCodec,
            audioCodec: audio.audioCodec,
            sourceContainer: video.container.lowercased(),
            urlExpiresAt: [FormatURLExpiry.usableUntil(of: video.formatURL),
                           FormatURLExpiry.usableUntil(of: audio.formatURL)]
                .compactMap { $0 }.min()
        )
    }

    private static func audioOption(for entry: AvailableMediaFormat) -> MediaFormatOption {
        let direct = isAACAudio(entry) && entry.container.lowercased() == "m4a"
        return MediaFormatOption(
            id: "verified-\(entry.formatID ?? entry.container)-audio",
            container: DownloadFormat.m4a.rawValue,
            fileExtension: DownloadFormat.m4a.fileExtension,
            mimeType: MediaFormatOption.mimeType(forExtension: DownloadFormat.m4a.fileExtension),
            displayName: DownloadFormat.m4a.displayName,
            isVideo: false,
            isAudio: true,
            qualityLabel: nil,
            estimatedFileSize: entry.estimatedFileSize,
            ytDlpFormatID: entry.formatID,
            audioYtDlpFormatID: nil,
            processing: direct ? .direct : .transcode,
            videoCodec: nil,
            audioCodec: entry.audioCodec,
            sourceContainer: entry.container.lowercased(),
            urlExpiresAt: FormatURLExpiry.usableUntil(of: entry.formatURL)
        )
    }

    /// The audio half of every split pair. AAC (mp4a) is preferred —
    /// it can be stream-copied and needs no transcode — with M4A
    /// containers preferred among AAC; otherwise the best audio-only
    /// format of any codec/container (e.g. Opus in WebM, transcoded
    /// to AAC during the merge). Within a class: highest bitrate,
    /// then largest size. One shared choice keeps pairing
    /// deterministic at every height.
    static func bestPairedAudio(in available: [AvailableMediaFormat]) -> AvailableMediaFormat? {
        available
            .filter { entry in
                guard entry.isAudioOnly, entry.formatID != nil else { return false }
                if isHLS(entry) { return false }
                if let codec = entry.audioCodec?.lowercased(), codec == "none" { return false }
                return true
            }
            .max { pairedAudioRank($0) < pairedAudioRank($1) }
    }

    /// Lexicographic rank of a pairing-audio candidate; higher is
    /// better. AAC first (M4A container first among AAC), then
    /// bitrate, then size.
    private static func pairedAudioRank(_ entry: AvailableMediaFormat) -> (Int, Int, Double, Int64) {
        let aac = isAACAudio(entry)
        let aacScore = aac ? 1 : 0
        let m4aScore = aac && entry.container.lowercased() == "m4a" ? 1 : 0
        return (aacScore, m4aScore, entry.totalBitrate ?? -1, entry.estimatedFileSize ?? -1)
    }

    /// Picks the ONE option a (format, quality) selection means.
    ///
    /// "Original" is the BEST option — highest picture height, then
    /// combined-before-split, then largest size — never merely the
    /// first match (yt-dlp lists formats worst-first, so the old
    /// first-match rule picked the *worst* format, and because
    /// heights outside the named cases collapse into the `.original`
    /// bucket, that was an ultralow audio-only file). A specific
    /// quality picks the exact height label (options are already
    /// reduced to one winner per height by `options(from:)`, under
    /// the copyable-first preference documented there). Audio picks
    /// a directly-savable AAC file first, then the largest
    /// (best-bitrate) audio file.
    static func selectOption(in options: [MediaFormatOption],
                             format: DownloadFormat,
                             quality: DownloadQuality?) -> MediaFormatOption? {
        let candidates = options.filter { $0.format == format }
        guard !candidates.isEmpty else { return nil }
        if format.isAudioOnly {
            return candidates.max {
                ($0.processing == .direct ? 1 : 0, $0.estimatedFileSize ?? 0)
                    < ($1.processing == .direct ? 1 : 0, $1.estimatedFileSize ?? 0)
            }
        }
        let videos = candidates.filter { $0.isVideo }
        guard !videos.isEmpty else { return nil }
        if let quality, quality != .original {
            let label = quality.displayName.lowercased()
            let exact = videos.filter { $0.qualityLabel?.lowercased() == label }
            if !exact.isEmpty {
                return exact.max {
                    ($0.isSplitPair ? 0 : 1, $0.estimatedFileSize ?? 0)
                        < ($1.isSplitPair ? 0 : 1, $1.estimatedFileSize ?? 0)
                }
            }
        }
        return videos.max {
            ($0.heightPixels ?? -1, $0.isSplitPair ? 0 : 1, $0.estimatedFileSize ?? 0)
                < ($1.heightPixels ?? -1, $1.isSplitPair ? 0 : 1, $1.estimatedFileSize ?? 0)
        }
    }

    static func formats(from options: [MediaFormatOption]) -> [DownloadFormat] {
        var seen: [DownloadFormat] = []
        for option in options {
            if let format = option.format, !seen.contains(format) { seen.append(format) }
        }
        return seen
    }

    static func qualities(for format: DownloadFormat, in options: [MediaFormatOption]) -> [DownloadQuality] {
        var seen: [DownloadQuality] = []
        for option in options where option.format == format {
            if !seen.contains(option.quality) { seen.append(option.quality) }
        }
        // "Original" (= best height) is always offered for video,
        // alongside every distinct height.
        if !format.isAudioOnly, !seen.isEmpty, !seen.contains(.original) {
            seen.append(.original)
        }
        return seen
    }
}

/// Decides whether — and how — a download may start.
/// Three honest routes exist:
/// 1. The source URL itself is a direct HTTPS media file (.mp4/.mov/.m4a)
///    → the URLSession engine downloads the file itself.
/// 2. The metadata came from the embedded yt-dlp engine and carries a
///    concrete format_id for the selection → the yt-dlp engine downloads
///    from the page URL. When the selection is a split pair,
///    `audioFormatID` carries the audio format_id and the engine
///    downloads both streams and remuxes them (see MediaFormatService).
/// 3. A permission-verified provider supplied a direct file URL.
/// Everything else is refused with a reason.
enum DirectMediaResolver {
    enum Resolution: Equatable, Sendable {
        case downloadable(url: URL, option: MediaFormatOption)
        case ytDlp(formatID: String, audioFormatID: String?, option: MediaFormatOption)
        case unavailable(reason: String)
    }

    static func resolve(sourceURL: URL,
                        format: DownloadFormat,
                        quality: DownloadQuality? = nil,
                        metadata: VideoMetadata? = nil,
                        capability: DownloadCapability? = nil) -> Resolution {
        guard sourceURL.scheme?.lowercased() == "https" else {
            return .unavailable(reason: DownloadError.invalidURL.userMessage)
        }
        if MediaFormatService.isDirectMediaURL(sourceURL) {
            guard MediaFormatService.directFormat(for: sourceURL) == format else {
                return .unavailable(reason: "このURLのファイル形式は \(sourceURL.pathExtension.uppercased()) です。選択した形式とは異なるためダウンロードできません。")
            }
            let option = MediaFormatService.optionsForDirectURL(sourceURL)[0]
            return .downloadable(url: sourceURL, option: option)
        }
        if let metadata {
            let options = MediaFormatService.options(from: metadata)
            if let option = MediaFormatService.selectOption(in: options, format: format, quality: quality),
               let formatID = option.ytDlpFormatID {
                return .ytDlp(formatID: formatID, audioFormatID: option.audioYtDlpFormatID, option: option)
            }
        }
        if let capability, capability.isDownloadable,
           let metadata,
           MediaFormatService.options(from: metadata).first(where: { $0.format == format }) != nil {
            // A verified format is known, but downloading still requires the
            // provider to hand out a direct file URL; the watch/page URL
            // itself is never downloaded as if it were a media file.
            return .unavailable(reason: "許可済みソースから直接ファイルURLが提供されていないため、ダウンロードできません。")
        }
        return .unavailable(reason: DownloadError.permissionNotVerified(reason: "no direct file URL").userMessage)
    }
}
