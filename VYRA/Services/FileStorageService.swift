import Foundation

/// File storage inside the app sandbox (Phase 3, spec §12).
/// - User files: Documents/VYRA
/// - In-progress downloads: temporaryDirectory/VYRA-Downloads
/// Files are moved (never loaded into memory) and names are deduplicated.
struct FileStorageService: Sendable {
    var documentsDirectory: URL
    var temporaryDirectory: URL
    var fileManager: FileManager = .default

    static var appDefault: FileStorageService {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return FileStorageService(documentsDirectory: docs, temporaryDirectory: fm.temporaryDirectory)
    }

    init(documentsDirectory: URL, temporaryDirectory: URL, fileManager: FileManager = .default) {
        self.documentsDirectory = documentsDirectory
        self.temporaryDirectory = temporaryDirectory
        self.fileManager = fileManager
    }

    var libraryDirectory: URL { documentsDirectory.appendingPathComponent("VYRA", isDirectory: true) }
    var downloadsTemporaryDirectory: URL { temporaryDirectory.appendingPathComponent("VYRA-Downloads", isDirectory: true) }

    func ensureDirectories() throws {
        do {
            try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: downloadsTemporaryDirectory, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.fileSystem(description: error.localizedDescription)
        }
    }

    func url(forRelativePath relativePath: String) -> URL {
        documentsDirectory.appendingPathComponent(relativePath)
    }

    func relativePath(for url: URL) -> String? {
        let base = documentsDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    func fileExists(relativePath: String) -> Bool {
        fileManager.fileExists(atPath: url(forRelativePath: relativePath).path)
    }

    func fileSize(relativePath: String) -> Int64? {
        fileSize(at: url(forRelativePath: relativePath))
    }

    func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    /// Moves a finished temporary download into the Library directory,
    /// resolving duplicate file names. Returns the final URL and its path
    /// relative to the Documents directory (what SwiftData persists).
    func moveIntoLibrary(tempFileURL: URL, desiredFileName: String) throws -> (url: URL, relativePath: String) {
        try ensureDirectories()
        let destination = try moveIntoDirectory(
            tempFileURL: tempFileURL, desiredFileName: desiredFileName, directory: libraryDirectory)
        guard let relative = relativePath(for: destination) else {
            throw DownloadError.fileSystem(description: "relative path computation failed")
        }
        return (destination, relative)
    }

    /// Moves a finished temporary download into an arbitrary directory
    /// (the user-chosen external save folder), resolving duplicate
    /// file names exactly like the app Library. The caller is
    /// responsible for security-scoped access to the directory.
    func moveIntoDirectory(tempFileURL: URL, desiredFileName: String, directory: URL) throws -> URL {
        let finalName = FileNameValidator.nextAvailableName(for: desiredFileName) { name in
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        let destination = directory.appendingPathComponent(finalName)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: tempFileURL, to: destination)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError {
                throw DownloadError.insufficientStorage
            }
            throw DownloadError.fileSystem(description: error.localizedDescription)
        }
        return destination
    }

    /// Copies data written by stub engines into the temporary area.
    func writeTemporaryFile(data: Data, fileName: String) throws -> URL {
        try ensureDirectories()
        let url = downloadsTemporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + fileName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw DownloadError.fileSystem(description: error.localizedDescription)
        }
    }

    func deleteFile(relativePath: String) throws {
        let url = url(forRelativePath: relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw DownloadError.fileSystem(description: error.localizedDescription)
        }
    }

    func deleteTemporaryFile(at url: URL?) {
        guard let url, fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Removes leftover partial downloads from previous sessions.
    func cleanupTemporaryDownloads() {
        guard let entries = try? fileManager.contentsOfDirectory(at: downloadsTemporaryDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries { try? fileManager.removeItem(at: entry) }
    }

    var totalLibraryBytes: Int64 {
        guard let entries = try? fileManager.contentsOfDirectory(at: libraryDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return entries.reduce(0) { $0 + (fileSize(at: $1) ?? 0) }
    }
}
