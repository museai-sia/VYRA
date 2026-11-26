import XCTest
import AVFoundation
@testable import VYRA

/// Real-transcode tests: the bundled FFmpeg libraries decode the
/// committed VP9/Opus WebM fixtures and re-encode them in-process
/// (H.264 via VideoToolbox + native AAC), and the output is verified
/// with AVAsset — codec subtypes, track layout, duration and
/// playability. No mocks for the transcode core.
final class FFmpegTranscodeTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-TranscodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private static func fixtureURL(named name: String) -> URL? {
        let bundle = Bundle(for: FFmpegTranscodeTests.self)
        if let url = bundle.url(forResource: name, withExtension: nil) {
            return url
        }
        guard let enumerator = FileManager.default.enumerator(
            at: bundle.bundleURL, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    private func copyFixture(named name: String) throws -> URL {
        let source = try XCTUnwrap(
            Self.fixtureURL(named: name), "fixture \(name) missing from the test bundle")
        let destination = tempDir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Asserts the output is a playable MP4 whose video track (when
    /// present) is H.264 and whose audio track is AAC.
    private func assertPlayableH264AAC(_ output: URL, expectVideo: Bool) async throws {
        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, expectVideo ? 1 : 0,
                       "unexpected video track count in \(output.lastPathComponent)")
        XCTAssertEqual(audioTracks.count, 1,
                       "output must have exactly one audio track")
        if expectVideo, let videoTrack = videoTracks.first {
            let descriptions = try await videoTrack.load(.formatDescriptions)
            let subtype = descriptions.first.map(CMFormatDescriptionGetMediaSubType)
            XCTAssertEqual(subtype, kCMVideoCodecType_H264,
                           "video must be re-encoded to H.264 (avc1), got \(String(describing: subtype))")
        }
        if let audioTrack = audioTracks.first {
            let descriptions = try await audioTrack.load(.formatDescriptions)
            let subtype = descriptions.first.map(CMFormatDescriptionGetMediaSubType)
            XCTAssertEqual(subtype, kAudioFormatMPEG4AAC,
                           "audio must be re-encoded to AAC, got \(String(describing: subtype))")
        }
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2.0, accuracy: 0.6,
                       "duration must match the 2s fixtures, got \(duration.seconds)")
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "output must be playable by AVKit")
    }

    func testTranscodeSplitVP9OpusPairToH264AAC() async throws {
        let video = try copyFixture(named: "transcode-video-only.webm")
        let audio = try copyFixture(named: "transcode-audio-only.webm")
        let output = tempDir.appendingPathComponent("split.mp4")

        let progressLock = NSLock()
        var fractions: [Double] = []
        try await FFmpegTranscoder.transcode(
            videoURL: video, audioURL: audio, outputURL: output,
            videoBitrate: 400_000, audioBitrate: 96_000,
            job: FFmpegTranscodeJob(),
            progress: { fraction in
                progressLock.lock()
                fractions.append(fraction)
                progressLock.unlock()
            })

        try await assertPlayableH264AAC(output, expectVideo: true)
        XCTAssertFalse(fractions.isEmpty, "transcode must report progress")
        XCTAssertEqual(fractions.last ?? -1, 1.0, accuracy: 0.001,
                       "progress must end at 1.0")
    }

    func testTranscodeCombinedWebMToH264AAC() async throws {
        let combined = try copyFixture(named: "transcode-combined.webm")
        let output = tempDir.appendingPathComponent("combined.mp4")

        try await FFmpegTranscoder.transcode(
            videoURL: combined, audioURL: combined, outputURL: output,
            videoBitrate: 400_000, audioBitrate: 96_000,
            job: FFmpegTranscodeJob(), progress: { _ in })

        try await assertPlayableH264AAC(output, expectVideo: true)
    }

    func testTranscodeAudioOnlyOpusToAAC() async throws {
        let audio = try copyFixture(named: "transcode-audio-only.webm")
        let output = tempDir.appendingPathComponent("audio.m4a")

        try await FFmpegTranscoder.transcode(
            videoURL: nil, audioURL: audio, outputURL: output,
            videoBitrate: 0, audioBitrate: 96_000,
            job: FFmpegTranscodeJob(), progress: { _ in })

        try await assertPlayableH264AAC(output, expectVideo: false)
    }

    func testTranscodeReportsRealErrorForMissingInput() async throws {
        let audio = try copyFixture(named: "transcode-audio-only.webm")
        let missing = tempDir.appendingPathComponent("no-such-video.webm")
        let output = tempDir.appendingPathComponent("split.mp4")
        do {
            try await FFmpegTranscoder.transcode(
                videoURL: missing, audioURL: audio, outputURL: output,
                videoBitrate: 400_000, audioBitrate: 96_000,
                job: FFmpegTranscodeJob(), progress: { _ in })
            XCTFail("transcode of a missing input must fail")
        } catch let error as FFmpegTranscodeError {
            guard case .failed(let message) = error else {
                return XCTFail("expected .failed, got \(error)")
            }
            XCTAssertTrue(message.contains("opening video input"),
                          "error must name the failing stage, got: \(message)")
        }
    }
}
