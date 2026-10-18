import Foundation

/// Kwaliteitsniveau voor lossy conversies.
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
        case .balanced: return "Gebalanceerd"
        case .high: return "Hoog"
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

/// Tools uit het ⌘-wiel. Elke tool werkt zonder extra venster met verstandige standaardwaarden.
public enum FileTool: String, CaseIterable, Sendable, Codable {
    case compress, removeMetadata, createPDF, mergePDF, splitPDF, muteVideo, normalizeAudio, extractArchive, readQRCode

    public var displayName: String {
        switch self {
        case .compress: return "Comprimeer"
        case .removeMetadata: return "Metadata weg"
        case .createPDF: return "Maak PDF"
        case .mergePDF: return "Voeg samen"
        case .splitPDF: return "Splits PDF"
        case .muteVideo: return "Dempen"
        case .normalizeAudio: return "Normaliseer"
        case .extractArchive: return "Uitpakken"
        case .readQRCode: return "Lees QR"
        }
    }

    public var symbolName: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
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

    /// Of de tool op deze selectie van toepassing is.
    public func applies(to categories: [FileCategory]) -> Bool {
        guard !categories.isEmpty else { return false }
        func all(_ allowed: Set<FileCategory>) -> Bool { categories.allSatisfy(allowed.contains) }
        switch self {
        case .compress: return all([.image, .video, .pdf])
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

/// Acties uit het ⌃-wiel; werken op elk bestand of elke map.
public enum FileAction: String, CaseIterable, Sendable, Codable {
    case airDrop, float, copy, move, copyPath, openTerminal

    public var displayName: String {
        switch self {
        case .airDrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Kopieer"
        case .move: return "Verplaats"
        case .copyPath: return "Kopieer pad"
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
    /// Doelformaten per bron-categorie, in de volgorde waarin ze op het wiel staan.
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

    /// Formaten die geldig zijn voor álle bestanden in de selectie, met weglating van het eigen formaat.
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
