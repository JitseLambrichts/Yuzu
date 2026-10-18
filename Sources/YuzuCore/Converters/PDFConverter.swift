import AppKit
import Foundation
import PDFKit

public enum PDFConverter {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw YuzuError.unreadable(url.lastPathComponent) }
        if document.isLocked { throw YuzuError.unsupported("encrypted PDF") }
        return document
    }

    /// Text of all pages, keeping the formatting PDFKit recognizes.
    public static func attributedText(of url: URL) throws -> NSAttributedString {
        let document = try open(url)
        let result = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.attributedString else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(text)
        }
        return result
    }

    /// Renders pages as images at 300 DPI. One page gives one file, several pages give a folder.
    public static func renderPages(_ url: URL, format: ConversionFormat, quality: Quality, dpi: CGFloat = 300) throws -> [URL] {
        guard let document = CGPDFDocument(url as CFURL) else { throw YuzuError.unreadable(url.lastPathComponent) }
        if document.isEncrypted, !document.isUnlocked { throw YuzuError.unsupported("encrypted PDF") }
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { throw YuzuError.nothingToDo("This PDF has no pages.") }

        var outputs: [URL] = []
        let folder: URL? = pageCount > 1 ? try OutputNaming.folder(for: url, name: "\(OutputNaming.baseName(of: url)) \(format.displayName)") : nil
        for number in 1...pageCount {
            guard let page = document.page(at: number) else { continue }
            let image = try render(page, dpi: dpi)
            let output = folder.map { $0.appendingPathComponent("Page \(number).\(format.fileExtension)") }
                ?? OutputNaming.output(for: url, fileExtension: format.fileExtension)
            try ImageConverter.write(image, properties: [:], format: format, quality: quality.imageQuality, to: output)
            outputs.append(output)
        }
        return folder.map { [$0] } ?? outputs
    }

    static func render(_ page: CGPDFPage, dpi: CGFloat) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = dpi / 72
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw YuzuError.writeFailed("PDF page")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw YuzuError.writeFailed("PDF page") }
        return image
    }

    public static func convert(_ source: URL, to format: ConversionFormat, settings: ConversionSettings) async throws -> [URL] {
        switch format {
        case .png, .jpg:
            return try renderPages(source, format: format, quality: settings.quality)
        case .txt:
            let output = OutputNaming.output(for: source, fileExtension: format.fileExtension)
            try (try open(source).string ?? "").write(to: output, atomically: true, encoding: .utf8)
            return [output]
        default:
            let output = OutputNaming.output(for: source, fileExtension: format.fileExtension)
            try await DocumentConverter.write(try attributedText(of: source), as: format, to: output)
            return [output]
        }
    }

    // MARK: - Tools

    public static func merge(_ sources: [URL], into output: URL) throws {
        let merged = PDFDocument()
        for source in sources {
            let document = try open(source)
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        guard merged.write(to: output) else { throw YuzuError.writeFailed(output.lastPathComponent) }
    }

    public static func split(_ source: URL) throws -> URL {
        let document = try open(source)
        let folder = try OutputNaming.folder(for: source, name: "\(OutputNaming.baseName(of: source)) pages")
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let output = folder.appendingPathComponent("Page \(index + 1).pdf")
            guard single.write(to: output) else { throw YuzuError.writeFailed(output.lastPathComponent) }
        }
        return folder
    }

    public static func compress(_ source: URL, into output: URL) throws {
        let document = try open(source)
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard document.write(to: output, withOptions: options) else { throw YuzuError.writeFailed(output.lastPathComponent) }
    }

    public static func removeMetadata(_ source: URL, into output: URL) throws {
        let document = try open(source)
        document.documentAttributes = [:]
        guard document.write(to: output) else { throw YuzuError.writeFailed(output.lastPathComponent) }
    }
}
