import Foundation

enum FileNameError: Error, Equatable, Sendable {
    case empty
    case invalidExtension

    var userMessage: String {
        switch self {
        case .empty: return "ファイル名を入力してください。"
        case .invalidExtension: return "ファイル形式に合った拡張子が必要です。"
        }
    }
}

/// Safe file-name handling (Phase 3, spec §8/§12/§18): strips path
/// separators and forbidden characters, rejects empty names, and always
/// protects the extension chosen by the selected format.
enum FileNameValidator {
    static let forbiddenCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        .union(.controlCharacters)
        .union(.newlines)

    /// Sanitizes a user-typed base name (without extension).
    static func sanitizedBaseName(_ raw: String) -> String {
        let stripped = raw.unicodeScalars
            .filter { !forbiddenCharacters.contains($0) }
        var result = String(String.UnicodeScalarView(stripped))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would make a hidden file / extension-only name.
        while result.hasPrefix(".") { result.removeFirst() }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse internal whitespace runs.
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return String(result.prefix(120))
    }

    /// Extracts the editable base name from a full file name.
    static func baseName(of fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    /// Builds the final file name from a user-edited base name, forcing the
    /// format's extension (extension protection). Throws `.empty` when the
    /// sanitized base name is empty.
    static func validatedFileName(baseName rawBase: String, format: DownloadFormat) throws -> String {
        let base = sanitizedBaseName(rawBase)
        guard !base.isEmpty else { throw FileNameError.empty }
        return base + "." + format.fileExtension
    }

    /// Validates a complete file name against a format: the extension must
    /// match the format, the base must survive sanitization non-empty.
    static func validate(fileName: String, format: DownloadFormat) throws -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard ext == format.fileExtension else { throw FileNameError.invalidExtension }
        return try validatedFileName(baseName: baseName(of: fileName), format: format)
    }

    /// "name.ext" -> "name 1.ext", "name 1.ext" -> "name 2.ext", …
    static func nextAvailableName(for fileName: String, exists: (String) -> Bool) -> String {
        guard exists(fileName) else { return fileName }
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var stem = base
        var counter = 1
        // If the base already ends with " N", continue numbering from N+1.
        if let spaceRange = base.range(of: " ", options: .backwards),
           let number = Int(base[spaceRange.upperBound...]), number > 0 {
            stem = String(base[..<spaceRange.lowerBound])
            counter = number + 1
        }
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }
}
