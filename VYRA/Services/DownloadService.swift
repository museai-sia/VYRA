import Foundation

/// The download-engine boundary (Phase 3, spec §5/§6). ViewModels never
/// touch URLSession directly; they go through `DownloadTaskManager`, which
/// drives an engine conforming to this protocol. Engines are interchangeable:
/// `URLSessionDownloadEngine` is the production engine, `StubDownloadEngine`
/// serves tests and previews.
///
/// An engine downloads `request.sourceURL` (which must already have been
/// resolved to a direct media file URL by `DirectMediaResolver`) into a
/// temporary file, reports real progress, and returns the temporary file's
/// URL. Moving the file into the Library is the manager/storage layer's job.
protocol DownloadService: Sendable {
    func download(request: DownloadRequest,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL
    func cancel(taskID: UUID) async
}
