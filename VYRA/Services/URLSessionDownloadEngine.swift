import Foundation
import os

/// Production download engine (Phase 3, spec §6): a native URLSession
/// download task. It downloads DIRECT HTTPS media file URLs only — the
/// resolver layer refuses page URLs (e.g. YouTube watch pages) before an
/// engine is ever invoked, and this engine additionally rejects non-HTTPS
/// URLs and non-2xx responses.
///
/// Foreground session only: downloads continue while the app is active.
/// No background-session support is claimed (spec §15) — see
/// PHASE_3_DOWNLOAD.md. No `paused` state is offered because arbitrary
/// servers do not guarantee byte-range resume.
final class URLSessionDownloadEngine: NSObject, DownloadService, URLSessionDownloadDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.siatube.vyra", category: "download")
    private var session: URLSession!
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
    private var progressHandlers: [Int: @Sendable (DownloadProgress) -> Void] = [:]
    private var taskIDsBySessionTask: [Int: UUID] = [:]
    private var sessionTasksByID: [UUID: URLSessionDownloadTask] = [:]
    private var startDates: [Int: Date] = [:]
    private var lastSamples: [Int: (bytes: Int64, date: Date, speed: Double?)] = [:]
    private var httpStatusCodes: [Int: Int] = [:]

    init(configuration: URLSessionConfiguration = .default) {
        super.init()
        let config = configuration
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func download(request: DownloadRequest,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        guard request.sourceURL.scheme?.lowercased() == "https" else {
            throw DownloadError.invalidURL
        }
        let task = session.downloadTask(with: request.sourceURL)
        lock.lock()
        taskIDsBySessionTask[task.taskIdentifier] = request.taskID
        sessionTasksByID[request.taskID] = task
        progressHandlers[task.taskIdentifier] = progress
        startDates[task.taskIdentifier] = Date()
        lock.unlock()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                lock.lock()
                continuations[task.taskIdentifier] = continuation
                lock.unlock()
                progress(DownloadProgress(state: .downloading))
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func cancel(taskID: UUID) async {
        lock.lock()
        let task = sessionTasksByID[taskID]
        lock.unlock()
        task?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let key = downloadTask.taskIdentifier
        if let response = downloadTask.response as? HTTPURLResponse {
            lock.lock(); httpStatusCodes[key] = response.statusCode; lock.unlock()
        }
        let now = Date()
        var speed: Double?
        lock.lock()
        if let last = lastSamples[key] {
            let elapsed = now.timeIntervalSince(last.date)
            if elapsed >= 0.25 {
                let delta = Double(totalBytesWritten - last.bytes)
                speed = elapsed > 0 ? delta / elapsed : nil
                lastSamples[key] = (totalBytesWritten, now, speed)
            } else {
                speed = last.speed
            }
        } else {
            lastSamples[key] = (totalBytesWritten, now, nil)
        }
        let handler = progressHandlers[key]
        lock.unlock()

        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        var eta: TimeInterval?
        if let total, let speed, speed > 0 {
            eta = Double(total - totalBytesWritten) / speed
        }
        handler?(DownloadProgress(
            downloadedBytes: totalBytesWritten,
            totalBytes: total,
            speedBytesPerSecond: speed,
            estimatedRemainingTime: eta,
            state: .downloading
        ))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let key = downloadTask.taskIdentifier
        lock.lock()
        let continuation = continuations.removeValue(forKey: key)
        let status = httpStatusCodes[key]
        lock.unlock()
        guard let continuation else { return }
        if let status, !(200...299).contains(status) {
            try? FileManager.default.removeItem(at: location)
            continuation.resume(throwing: DownloadError.httpStatus(status))
            return
        }
        // The system deletes `location` when this delegate method returns,
        // so move it to our own temporary area first (file move, no copy
        // into memory).
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-Downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString + "-" + (downloadTask.originalRequest?.url?.lastPathComponent ?? "download"))
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation.resume(returning: destination)
        } catch {
            continuation.resume(throwing: DownloadError.fileSystem(description: error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = task.taskIdentifier
        lock.lock()
        let continuation = continuations.removeValue(forKey: key)
        if let taskID = taskIDsBySessionTask.removeValue(forKey: key) {
            sessionTasksByID.removeValue(forKey: taskID)
        }
        progressHandlers.removeValue(forKey: key)
        startDates.removeValue(forKey: key)
        lastSamples.removeValue(forKey: key)
        httpStatusCodes.removeValue(forKey: key)
        lock.unlock()
        guard let continuation else { return }
        // Success is resumed in didFinishDownloadingTo; reaching here with a
        // continuation still pending means an error (or cancellation).
        if let error {
            continuation.resume(throwing: DownloadError.from(error))
        } else {
            continuation.resume(throwing: DownloadError.network(description: "download finished without a file"))
        }
    }
}

/// Test/preview engine: writes rights-free sample bytes to a temporary
/// file in chunks and reports progress. Never touches the network.
final class StubDownloadEngine: DownloadService, @unchecked Sendable {
    enum Behavior: Sendable {
        case success(totalBytes: Int64, chunkBytes: Int64)
        case failure(DownloadError)
        /// Reports partial progress, then waits until cancelled.
        case hangAfterFirstChunk(totalBytes: Int64)
    }

    var behavior: Behavior
    var chunkDelayNanoseconds: UInt64
    private let lock = NSLock()
    private var cancelledIDs: Set<UUID> = []
    private(set) var startedTaskIDs: [UUID] = []

    init(behavior: Behavior = .success(totalBytes: 4_096, chunkBytes: 1_024),
         chunkDelayNanoseconds: UInt64 = 1_000_000) {
        self.behavior = behavior
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
    }

    func cancel(taskID: UUID) async {
        lock.lock(); cancelledIDs.insert(taskID); lock.unlock()
    }

    private func isCancelled(_ taskID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledIDs.contains(taskID)
    }

    func download(request: DownloadRequest,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        lock.lock(); startedTaskIDs.append(request.taskID); lock.unlock()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-Downloads", isDirectory: true)
            .appendingPathComponent(request.taskID.uuidString + "-" + request.fileName)
        try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)

        func abort(_ error: Error) throws -> Never {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        switch behavior {
        case .failure(let error):
            try abort(error)
        case .hangAfterFirstChunk(let totalBytes):
            try handle.write(contentsOf: Data(count: 512))
            progress(DownloadProgress(downloadedBytes: 512, totalBytes: totalBytes, state: .downloading))
            while !Task.isCancelled && !isCancelled(request.taskID) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try abort(DownloadError.cancelled)
        case .success(let totalBytes, let chunkBytes):
            var written: Int64 = 0
            while written < totalBytes {
                if Task.isCancelled || isCancelled(request.taskID) {
                    try abort(DownloadError.cancelled)
                }
                let chunk = Int64(min(Int64(chunkBytes), totalBytes - written))
                try handle.write(contentsOf: Data(count: Int(chunk)))
                written += chunk
                progress(DownloadProgress(
                    downloadedBytes: written,
                    totalBytes: totalBytes,
                    speedBytesPerSecond: 1_000_000,
                    estimatedRemainingTime: Double(totalBytes - written) / 1_000_000,
                    state: .downloading
                ))
                if chunkDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: chunkDelayNanoseconds)
                }
            }
            try handle.close()
            return tempURL
        }
    }
}
