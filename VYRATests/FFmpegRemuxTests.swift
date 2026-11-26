import XCTest
import AVFoundation
@testable import VYRA

/// Real-remux tests: the bundled FFmpeg libraries merge the tiny
/// committed fixtures (video-only MP4 + audio-only M4A) in-process,
/// and the output is verified with AVAsset — track layout, duration
/// and playability. No mocks for the remux core.
final class FFmpegRemuxTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-RemuxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private static func fixtureURL(named name: String) -> URL? {
        let bundle = Bundle(for: FFmpegRemuxTests.self)
        if let url = bundle.url(forResource: name, withExtension: nil) {
            return url
        }
        // Folder-synchronized targets may nest resources; search.
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

    func testRemuxMergesVideoAndAudioFixtures() async throws {
        let video = try copyFixture(named: "remux-video-only.mp4")
        let audio = try copyFixture(named: "remux-audio-only.m4a")
        let output = tempDir.appendingPathComponent("merged.mp4")

        try await FFmpegRemuxer.remux(videoURL: video, audioURL: audio,
                                      outputURL: output, job: FFmpegRemuxJob())

        let size = try XCTUnwrap(FileStorageService.fileSizeForTest(at: output))
        XCTAssertGreaterThan(size, 10_000, "merged file must contain both streams")

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1, "merged file must have exactly one video track")
        XCTAssertEqual(audioTracks.count, 1, "merged file must have exactly one audio track")
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2.0, accuracy: 0.6,
                       "merged duration must match the 2s fixtures, got \(duration.seconds)")
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "merged file must be playable by AVKit")
        try await assertVideoFrameDecodes(from: asset)
    }

    /// The property the Library's playback depends on: the video
    /// track must not merely EXIST and report playable — a real
    /// frame must decode. (On device, a file whose video track
    /// AVFoundation cannot decode presents as audio-only playback.)
    private func assertVideoFrameDecodes(from asset: AVAsset) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        let result = try await generator.image(
            at: CMTime(seconds: 0.5, preferredTimescale: 600))
        XCTAssertGreaterThan(result.image.width, 0,
                             "a video frame must decode from the remuxed file")
    }

    func testRemuxSingleConvertsTSFixtureToPlayableMP4() async throws {
        // The HLS path: one MPEG-TS file (a segment of the committed
        // HLS fixture — H.264 + AAC) stream-copies into an MP4 that
        // AVFoundation can load and play.
        let ts = try copyFixture(named: "seg00.bin")
        let output = tempDir.appendingPathComponent("hls-remuxed.mp4")

        try await FFmpegRemuxer.remuxSingle(inputURL: ts, outputURL: output,
                                            job: FFmpegRemuxJob())

        let size = try XCTUnwrap(FileStorageService.fileSizeForTest(at: output))
        XCTAssertGreaterThan(size, 10_000, "remuxed file must contain both streams")

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1, "remuxed file must have exactly one video track")
        XCTAssertEqual(audioTracks.count, 1, "remuxed file must have exactly one audio track")
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1.0, accuracy: 0.6,
                       "segment duration must be ~1s, got \(duration.seconds)")
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "remuxed file must be playable by AVKit")
        try await assertVideoFrameDecodes(from: asset)
    }

    func testRemuxReportsRealErrorForMissingInput() async throws {
        let audio = try copyFixture(named: "remux-audio-only.m4a")
        let missing = tempDir.appendingPathComponent("no-such-video.mp4")
        let output = tempDir.appendingPathComponent("merged.mp4")
        do {
            try await FFmpegRemuxer.remux(videoURL: missing, audioURL: audio,
                                          outputURL: output, job: FFmpegRemuxJob())
            XCTFail("remux of a missing input must fail")
        } catch let error as FFmpegRemuxError {
            guard case .failed(let message) = error else {
                return XCTFail("expected .failed, got \(error)")
            }
            XCTAssertTrue(message.contains("opening video input"),
                          "error must name the failing stage, got: \(message)")
        }
    }

    func testRemuxRejectsAudioInVideoSlot() async throws {
        // Swapped inputs: the "video" file has no video stream, so the
        // remux must fail honestly instead of producing a broken file.
        let audioAsVideo = try copyFixture(named: "remux-audio-only.m4a")
        let audio = tempDir.appendingPathComponent("second.m4a")
        try FileManager.default.copyItem(at: audioAsVideo, to: audio)
        let output = tempDir.appendingPathComponent("merged.mp4")
        do {
            try await FFmpegRemuxer.remux(videoURL: audioAsVideo, audioURL: audio,
                                          outputURL: output, job: FFmpegRemuxJob())
            XCTFail("remux without a video stream must fail")
        } catch let error as FFmpegRemuxError {
            guard case .failed = error else {
                return XCTFail("expected .failed, got \(error)")
            }
        }
    }
}

private extension FileStorageService {
    static func fileSizeForTest(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }
}
