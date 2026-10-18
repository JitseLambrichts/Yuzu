import Foundation

/// Quality level for lossy conversions.
public enum Quality: String, CaseIterable, Codable, Sendable {
    case compact, balanced, high

    public var imageQuality: Double {
        switch self {
        case .compact: return 0.6
        case .balanced: return 0.8
        case .high: return 0.93
        }
    }

    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .balanced: return "Balanced"
        case .high: return "High"
        }
    }
}

public struct ConversionSettings: Sendable, Equatable {
    public var quality: Quality
    public var preserveMetadata: Bool

    public init(quality: Quality = .balanced, preserveMetadata: Bool = true) {
        self.quality = quality
        self.preserveMetadata = preserveMetadata
    }
}

/// Tools on the ⌘ wheel. Most run without a window; tools with `hasOptionsPanel` ask for settings first.
public enum FileTool: String, CaseIterable, Sendable, Codable {
    case compress, cropImage, frameImage, annotateImage, trimVideo, trimAudio, removeMetadata, createPDF, mergePDF, splitPDF, muteVideo, normalizeAudio,
         extractArchive, readQRCode

    public var displayName: String {
        switch self {
        case .compress: return "Compress"
        case .cropImage: return "Crop"
        case .frameImage: return "Add Background"
        case .annotateImage: return "Annotate"
        case .trimVideo, .trimAudio: return "Trim"
        case .removeMetadata: return "Remove Metadata"
        case .createPDF: return "Create PDF"
        case .mergePDF: return "Merge"
        case .splitPDF: return "Split PDF"
        case .muteVideo: return "Mute"
        case .normalizeAudio: return "Normalize"
        case .extractArchive: return "Extract"
        case .readQRCode: return "Read QR"
        }
    }

    public var symbolName: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .cropImage: return "crop"
        case .frameImage: return "photo.artframe"
        case .annotateImage: return "pencil.tip.crop.circle"
        case .trimVideo: return "timeline.selection"
        case .trimAudio: return "waveform.path"
        case .removeMetadata: return "eye.slash"
        case .createPDF: return "doc.richtext"
        case .mergePDF: return "doc.on.doc"
        case .splitPDF: return "scissors"
        case .muteVideo: return "speaker.slash"
        case .normalizeAudio: return "waveform"
        case .extractArchive: return "archivebox"
        case .readQRCode: return "qrcode.viewfinder"
        }
    }

    /// Whether the tool opens an options panel after the drop (and therefore expects `FileToolOptions`).
    public var hasOptionsPanel: Bool {
        switch self {
        case .compress, .cropImage, .frameImage, .annotateImage, .trimVideo, .trimAudio: return true
        default: return false
        }
    }

    /// Whether the tool applies to this selection.
    public func applies(to categories: [FileCategory]) -> Bool {
        guard !categories.isEmpty else { return false }
        func all(_ allowed: Set<FileCategory>) -> Bool { categories.allSatisfy(allowed.contains) }
        switch self {
        case .compress: return all([.image, .video, .pdf])
        case .cropImage, .frameImage: return all([.image])
        case .annotateImage: return categories.count == 1 && all([.image])
        case .trimVideo: return categories.count == 1 && all([.video])
        case .trimAudio: return categories.count == 1 && all([.audio])
        case .removeMetadata: return all([.image, .audio, .video, .pdf])
        case .createPDF: return all([.image])
        case .mergePDF: return categories.count >= 2 && all([.pdf])
        case .splitPDF: return all([.pdf])
        case .muteVideo: return all([.video])
        case .normalizeAudio: return all([.audio, .video])
        case .extractArchive: return all([.archive])
        case .readQRCode: return all([.image])
        }
    }
}

/// Actions on the ⌃ wheel; they work on any file or folder.
public enum FileAction: String, CaseIterable, Sendable, Codable {
    case airDrop, float, copy, move, copyPath, openTerminal

    public var displayName: String {
        switch self {
        case .airDrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Copy"
        case .move: return "Move"
        case .copyPath: return "Copy Path"
        case .openTerminal: return "Terminal"
        }
    }

    public var symbolName: String {
        switch self {
        case .airDrop: return "airplayaudio"
        case .float: return "tray.and.arrow.down"
        case .copy: return "doc.on.clipboard"
        case .move: return "folder"
        case .copyPath: return "link"
        case .openTerminal: return "terminal"
        }
    }
}

public enum ConversionCatalog {
    /// Target formats per source category, in the order they appear on the wheel.
    public static func targets(for category: FileCategory) -> [ConversionFormat] {
        switch category {
        case .image:
            return [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf].filter { format in
                format == .pdf || format == .webp || ImageCapabilities.canWriteNatively(format)
            }
        case .audio: return [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
        case .video: return [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3]
        case .pdf: return [.docx, .txt, .md, .rtf, .html, .png, .jpg]
        case .document: return [.pdf, .docx, .rtf, .odt, .html, .txt, .md]
        case .spreadsheet: return [.xlsx, .csv, .tsv]
        case .subtitle: return [.srt, .vtt, .txt]
        case .archive, .folder: return [.zip, .tar, .tgz]
        case .other: return []
        }
    }

    /// Formats that are valid for every file in the selection, leaving out the files' own format.
    public static func targets(for urls: [URL]) -> [ConversionFormat] {
        guard let first = urls.first else { return [] }
        var result = targets(for: FileCategory.of(first))
        for url in urls {
            let allowed = Set(targets(for: FileCategory.of(url)))
            result = result.filter(allowed.contains)
        }
        let ownFormats = Set(urls.compactMap(ConversionFormat.matching))
        if urls.count == 1 || ownFormats.count == 1 {
            result.removeAll { ownFormats.contains($0) }
        }
        return result
    }

    public static func tools(for urls: [URL]) -> [FileTool] {
        let categories = urls.map(FileCategory.of)
        return FileTool.allCases.filter { $0.applies(to: categories) }
    }
}
