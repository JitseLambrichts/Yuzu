import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rough classification of a source file; decides which converters and tools apply.
public enum FileCategory: String, CaseIterable, Sendable {
    case image, audio, video, pdf, document, spreadsheet, subtitle, archive, folder, other

    /// Determines the category from the extension (and the directory flag for folders).
    public static func of(_ url: URL) -> FileCategory {
        let ext = SourceExtension.normalized(url)
        if let category = SourceExtension.table[ext] { return category }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .folder
        }
        return .other
    }
}

/// Target formats Yuzu can write.
public enum ConversionFormat: String, CaseIterable, Sendable, Identifiable, Codable {
    // Images
    case jpg, png, webp, heic, tiff, avif, bmp, gif
    // Audio
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    // Video
    case mp4, mov, mkv, webm, avi, wmv
    // Documents
    case pdf, docx, rtf, odt, html, txt, md
    // Spreadsheets
    case xlsx, csv, tsv
    // Subtitles
    case srt, vtt
    // Archives
    case zip, tar, tgz

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .tgz: return "tar.gz"
        default: return rawValue
        }
    }

    public var displayName: String {
        switch self {
        case .tgz: return "TAR.GZ"
        case .md: return "Markdown"
        default: return rawValue.uppercased()
        }
    }

    /// The format that belongs to a source file, so we don't convert to the same format.
    public static func matching(_ url: URL) -> ConversionFormat? {
        switch SourceExtension.normalized(url) {
        case "jpeg", "jpe": return .jpg
        case "heif": return .heic
        case "tif": return .tiff
        case "aif": return .aiff
        case "htm": return .html
        case "markdown": return .md
        case "text": return .txt
        default: return ConversionFormat(rawValue: SourceExtension.normalized(url))
        }
    }

    public var isVideoFormat: Bool { [.mp4, .mov, .mkv, .webm, .avi, .wmv].contains(self) }
    public var isAudioFormat: Bool { [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma].contains(self) }
}

enum SourceExtension {
    static func normalized(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return "tgz" }
        return url.pathExtension.lowercased()
    }

    static let table: [String: FileCategory] = {
        var table: [String: FileCategory] = [:]
        for ext in ["jpg", "jpeg", "jpe", "png", "webp", "heic", "heif", "tiff", "tif", "avif", "bmp", "gif", "svg", "ico", "psd", "dng", "cr2", "nef", "arw"] {
            table[ext] = .image
        }
        for ext in ["mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "aif", "aiff", "wma", "caf", "m4b"] {
            table[ext] = .audio
        }
        for ext in ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "ts", "mts", "m2ts"] {
            table[ext] = .video
        }
        table["pdf"] = .pdf
        for ext in ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "txt", "text", "md", "markdown", "webarchive"] {
            table[ext] = .document
        }
        for ext in ["xlsx", "csv", "tsv"] {
            table[ext] = .spreadsheet
        }
        for ext in ["srt", "vtt"] {
            table[ext] = .subtitle
        }
        for ext in ["zip", "tar", "tgz", "gz", "tbz", "bz2", "xz", "rar", "7z"] {
            table[ext] = .archive
        }
        return table
    }()
}

/// Determines which formats ImageIO can write on this system (AVIF/WebP differ per macOS version).
public enum ImageCapabilities {
    public static let writableTypeIdentifiers: Set<String> = {
        let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return Set(ids)
    }()

    public static func utType(for format: ConversionFormat) -> UTType? {
        switch format {
        case .jpg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .gif: return .gif
        case .webp: return .webP
        case .avif: return UTType("public.avif")
        default: return nil
        }
    }

    public static func canWriteNatively(_ format: ConversionFormat) -> Bool {
        guard let type = utType(for: format) else { return false }
        return writableTypeIdentifiers.contains(type.identifier)
    }
}
