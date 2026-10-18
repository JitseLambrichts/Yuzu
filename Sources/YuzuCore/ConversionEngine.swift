import Foundation

/// Stuurt een conversie naar de juiste converter en schrijft de uitvoer naast het origineel.
public enum ConversionEngine {
    @discardableResult
    public static func convert(_ source: URL, to format: ConversionFormat, settings: ConversionSettings = .init(),
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [URL] {
        let category = FileCategory.of(source)
        guard ConversionCatalog.targets(for: category).contains(format) else {
            throw YuzuError.unsupported("\(source.lastPathComponent) naar \(format.displayName)")
        }

        // PDF → afbeeldingen kan meerdere bestanden of een map opleveren.
        if category == .pdf {
            return try await PDFConverter.convert(source, to: format, settings: settings)
        }

        let output = OutputNaming.output(for: source, fileExtension: format.fileExtension)
        do {
            switch category {
            case .image:
                try await ImageConverter.convert(source, to: format, settings: settings, output: output)
            case .audio, .video:
                try await MediaConverter.convert(source, to: format, settings: settings, output: output, progress: progress)
            case .document:
                try await DocumentConverter.convert(source, to: format, output: output)
            case .spreadsheet:
                try await SpreadsheetConverter.convert(source, to: format, output: output)
            case .subtitle:
                try SubtitleConverter.convert(source, to: format, output: output)
            case .archive, .folder:
                try await ArchiveConverter.convert(source, to: format, output: output)
            case .pdf, .other:
                throw YuzuError.unsupported(source.lastPathComponent)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(1)
        return [output]
    }
}
