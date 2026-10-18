import AppKit
import Foundation

/// Simple Markdown ↔ NSAttributedString translation: headings, lists, quotes, code blocks and inline styling.
public enum Markdown {
    static let bodySize: CGFloat = 12
    static let headingSizes: [CGFloat] = [24, 20, 17, 15, 13, 13]

    public static func attributedString(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var paragraph: [String] = []
        var inCodeBlock = false
        var codeLines: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            append(inline(paragraph.joined(separator: " "), baseFont: .systemFont(ofSize: bodySize)), style: bodyStyle())
            paragraph.removeAll()
        }
        func append(_ text: NSAttributedString, style: NSParagraphStyle) {
            let line = NSMutableAttributedString(attributedString: text)
            line.append(NSAttributedString(string: "\n"))
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            result.append(line)
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCodeBlock {
                    let code = NSAttributedString(string: codeLines.joined(separator: "\n"),
                                                  attributes: [.font: NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)])
                    append(code, style: bodyStyle())
                    codeLines.removeAll()
                } else {
                    flushParagraph()
                }
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock {
                codeLines.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if let level = headingLevel(line) {
                flushParagraph()
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                let font = NSFont.boldSystemFont(ofSize: headingSizes[level - 1])
                append(inline(text, baseFont: font), style: headingStyle())
                continue
            }
            if let (marker, text) = listItem(line) {
                flushParagraph()
                let item = NSMutableAttributedString(string: "\(marker)\t", attributes: [.font: NSFont.systemFont(ofSize: bodySize)])
                item.append(inline(text, baseFont: .systemFont(ofSize: bodySize)))
                append(item, style: listStyle())
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                let text = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                let quote = NSMutableAttributedString(attributedString: inline(text, baseFont: italic(.systemFont(ofSize: bodySize))))
                quote.addAttribute(.foregroundColor, value: NSColor.darkGray, range: NSRange(location: 0, length: quote.length))
                append(quote, style: quoteStyle())
                continue
            }
            paragraph.append(line)
        }
        if inCodeBlock, !codeLines.isEmpty {
            append(NSAttributedString(string: codeLines.joined(separator: "\n"),
                                      attributes: [.font: NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)]),
                   style: bodyStyle())
        }
        flushParagraph()
        return result
    }

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    static func listItem(_ line: String) -> (String, String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return ("•", String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return ("\(digits).", String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    /// Inline styling (bold, italic, code, links) through Foundation's Markdown parser.
    static func inline(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: baseFont])
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var font = baseFont
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { font = bold(font) }
                if intent.contains(.emphasized) { font = italic(font) }
                if intent.contains(.code) { font = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = font
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }

    // MARK: - Back to Markdown

    public static func markdown(from attributed: NSAttributedString) -> String {
        let string = attributed.string as NSString
        var lines: [String] = []
        var location = 0
        while location < string.length {
            let paragraphRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraphRange)
            var contentRange = paragraphRange
            while contentRange.length > 0,
                  let scalar = UnicodeScalar(string.character(at: NSMaxRange(contentRange) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                contentRange.length -= 1
            }
            guard contentRange.length > 0 else {
                lines.append("")
                continue
            }
            let paragraph = attributed.attributedSubstring(from: contentRange)
            lines.append(markdownLine(paragraph))
            lines.append("")
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    static func markdownLine(_ paragraph: NSAttributedString) -> String {
        let plain = paragraph.string
        let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let size = font?.pointSize ?? bodySize
        let isBold = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
        let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

        if size >= 22 { return "# " + plain }
        if size >= 18 { return "## " + plain }
        if size >= 15, isBold { return "### " + plain }

        var prefix = ""
        var body = paragraph
        let trimmed = plain.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, "•◦▪–-".contains(first) {
            prefix = "- "
            let dropCount = (plain as NSString).range(of: String(first)).upperBound
            var skip = dropCount
            while skip < (plain as NSString).length, let scalar = UnicodeScalar((plain as NSString).character(at: skip)),
                  CharacterSet.whitespaces.contains(scalar) {
                skip += 1
            }
            body = paragraph.attributedSubstring(from: NSRange(location: skip, length: paragraph.length - skip))
        } else if let lists = style?.textLists, !lists.isEmpty {
            prefix = "- "
        }
        return prefix + inlineMarkdown(body)
    }

    static func inlineMarkdown(_ text: NSAttributedString) -> String {
        var output = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var piece = (text.string as NSString).substring(with: range)
            let core = piece.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else {
                output += piece
                return
            }
            let leading = String(piece.prefix { $0 == " " })
            let trailing = String(piece.reversed().prefix { $0 == " " })
            piece = core
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { piece = "**\(piece)**" }
                if traits.contains(.italicFontMask) { piece = "*\(piece)*" }
                if font.isFixedPitch { piece = "`\(core)`" }
            }
            if let link = attributes[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !url.isEmpty { piece = "[\(piece)](\(url))" }
            }
            output += leading + piece + trailing
        }
        return output
    }

    // MARK: - Styles

    static func bold(_ font: NSFont) -> NSFont { NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
    static func italic(_ font: NSFont) -> NSFont { NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }

    static func bodyStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        return style
    }

    static func headingStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 10
        style.paragraphSpacing = 6
        return style
    }

    static func listStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
        style.headIndent = 18
        style.paragraphSpacing = 3
        return style
    }

    static func quoteStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 18
        style.headIndent = 18
        style.paragraphSpacing = 8
        return style
    }
}
