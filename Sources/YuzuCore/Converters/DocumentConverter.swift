import AppKit
import Foundation
import PDFKit

/// Text documents through NSAttributedString (DOCX, DOC, RTF, RTFD, ODT, HTML, TXT, Markdown) and PDF export.
public enum DocumentConverter {
    public static func read(_ url: URL) async throws -> NSAttributedString {
        let ext = SourceExtension.normalized(url)
        switch ext {
        case "txt", "text":
            let text = try readText(url)
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        case "md", "markdown":
            return Markdown.attributedString(from: try readText(url))
        case "html", "htm", "webarchive":
            // The HTML importer uses WebKit and must run on the main thread.
            let type: NSAttributedString.DocumentType = ext == "webarchive" ? .webArchive : .html
            return try await MainActor.run {
                UncheckedSendable(try NSAttributedString(url: url, options: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue],
                                                         documentAttributes: nil))
            }.value
        case "pdf":
            return try PDFConverter.attributedText(of: url)
        default:
            let types: [String: NSAttributedString.DocumentType] = [
                "docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "rtfd": .rtfd, "odt": .openDocument,
            ]
            guard let type = types[ext] else { throw YuzuError.unsupported("reading .\(ext)") }
            do {
                return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
            } catch {
                throw YuzuError.unreadable(url.lastPathComponent)
            }
        }
    }

    static func readText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) { return text }
        throw YuzuError.unreadable(url.lastPathComponent)
    }

    public static func write(_ text: NSAttributedString, as format: ConversionFormat, to output: URL) async throws {
        let range = NSRange(location: 0, length: text.length)
        switch format {
        case .pdf:
            let box = UncheckedSendable(text)
            try await MainActor.run { try PDFTextRenderer.render(box.value, to: output) }
        case .txt:
            try text.string.write(to: output, atomically: true, encoding: .utf8)
        case .md:
            try Markdown.markdown(from: text).write(to: output, atomically: true, encoding: .utf8)
        case .docx, .rtf, .odt, .html:
            let types: [ConversionFormat: NSAttributedString.DocumentType] = [
                .docx: .officeOpenXML, .rtf: .rtf, .odt: .openDocument, .html: .html,
            ]
            let data = try text.data(from: range, documentAttributes: [.documentType: types[format]!])
            try data.write(to: output, options: .atomic)
        default:
            throw YuzuError.unsupported("document to \(format.displayName)")
        }
    }

    public static func convert(_ source: URL, to format: ConversionFormat, output: URL) async throws {
        let text = try await read(source)
        try await write(text, as: format, to: output)
    }
}

/// Lays out an NSAttributedString as PDF pages through TextKit, including images and tables.
@MainActor
public enum PDFTextRenderer {
    public static func render(_ text: NSAttributedString, to output: URL,
                              pageSize: CGSize = CGSize(width: 595, height: 842), margin: CGFloat = 56) throws {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let contentSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)

        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
            let range = layoutManager.glyphRange(for: container)
            if NSMaxRange(range) >= layoutManager.numberOfGlyphs || range.length == 0 { break }
        } while containers.count < 5000

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
            throw YuzuError.writeFailed(output.lastPathComponent)
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let glyphs = layoutManager.glyphRange(for: container)
            let origin = CGPoint(x: margin, y: margin)
            layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }
}

/// Moves a non-Sendable value to/from the main actor; only for values that aren't shared afterwards.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
