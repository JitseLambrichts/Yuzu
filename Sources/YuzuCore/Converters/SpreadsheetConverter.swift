import Foundation

/// CSV/TSV en een minimale XLSX-lezer en -schrijver (eerste werkblad, waarden zonder opmaak).
public enum SpreadsheetConverter {
    public typealias Table = [[String]]

    // MARK: - Delimited

    public static func parseDelimited(_ text: String, delimiter: Character) -> Table {
        var rows: Table = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let character = pending { pending = nil; return character }
            return iterator.next()
        }
        while let character = next() {
            if inQuotes {
                if character == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { inQuotes = false; pending = following }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                inQuotes = true
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    public static func delimited(_ table: Table, delimiter: Character) -> String {
        table.map { row in
            row.map { field in
                if field.contains(delimiter) || field.contains("\"") || field.contains("\n") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: String(delimiter))
        }.joined(separator: "\n") + "\n"
    }

    // MARK: - XLSX schrijven

    static func columnName(_ index: Int) -> String {
        var index = index + 1
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            index = (index - 1) / 26
        }
        return name
    }

    /// Alleen "echte" getallen als getal opslaan; codes met voorloopnullen blijven tekst.
    static func isNumeric(_ value: String) -> Bool {
        guard value.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return false }
        return value.count <= 15
    }

    static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func writeXLSX(_ table: Table, to output: URL) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("yuzu-xlsx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for folder in ["_rels", "xl/_rels", "xl/worksheets"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        """
        for (rowIndex, row) in table.enumerated() {
            sheet += "<row r=\"\(rowIndex + 1)\">"
            for (columnIndex, value) in row.enumerated() where !value.isEmpty {
                let reference = "\(columnName(columnIndex))\(rowIndex + 1)"
                if isNumeric(value) {
                    sheet += "<c r=\"\(reference)\"><v>\(value)</v></c>"
                } else {
                    sheet += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"

        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """,
            "xl/workbook.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Blad1" sheetId="1" r:id="rId1"/></sheets></workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
            """,
            "xl/worksheets/sheet1.xml": sheet,
        ]
        for (path, content) in files {
            try content.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try? fm.removeItem(at: output)
        try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/zip"), ["-q", "-X", "-r", output.path, "."], currentDirectory: root)
    }

    // MARK: - XLSX lezen

    public static func readXLSX(_ url: URL) async throws -> Table {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("yuzu-xlsx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", "-o", url.path, "-d", root.path])

        var shared: [String] = []
        if let data = try? Data(contentsOf: root.appendingPathComponent("xl/sharedStrings.xml")) {
            let parser = SharedStringsParser()
            shared = parser.parse(data)
        }
        let worksheets = root.appendingPathComponent("xl/worksheets")
        let sheets = (try? fm.contentsOfDirectory(atPath: worksheets.path))?.filter { $0.hasSuffix(".xml") }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        } ?? []
        guard let first = sheets.first, let data = try? Data(contentsOf: worksheets.appendingPathComponent(first)) else {
            throw YuzuError.unreadable(url.lastPathComponent)
        }
        return SheetParser(sharedStrings: shared).parse(data)
    }

    public static func convert(_ source: URL, to format: ConversionFormat, output: URL) async throws {
        let table: Table
        switch SourceExtension.normalized(source) {
        case "csv": table = parseDelimited(try DocumentConverter.readText(source), delimiter: detectDelimiter(try DocumentConverter.readText(source)))
        case "tsv": table = parseDelimited(try DocumentConverter.readText(source), delimiter: "\t")
        case "xlsx": table = try await readXLSX(source)
        default: throw YuzuError.unsupported(source.pathExtension)
        }
        switch format {
        case .csv: try delimited(table, delimiter: ",").write(to: output, atomically: true, encoding: .utf8)
        case .tsv: try delimited(table, delimiter: "\t").write(to: output, atomically: true, encoding: .utf8)
        case .xlsx: try await writeXLSX(table, to: output)
        default: throw YuzuError.unsupported("spreadsheet naar \(format.displayName)")
        }
    }

    /// Europese CSV's gebruiken vaak `;` als scheidingsteken.
    static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" }
        return firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ","
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inText = false

    func parse(_ data: Data) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "si" { current = "" }
        if name == "t" { inText = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inText = false }
        if name == "si" { strings.append(current) }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var cells: [(row: Int, column: Int, value: String)] = []
    private var reference = ""
    private var type = ""
    private var value = ""
    private var capturing = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parse(_ data: Data) -> SpreadsheetConverter.Table {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        let rowCount = (cells.map(\.row).max() ?? -1) + 1
        let columnCount = (cells.map(\.column).max() ?? -1) + 1
        var table = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
        for cell in cells { table[cell.row][cell.column] = cell.value }
        return table
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "c":
            reference = attributes["r"] ?? ""
            type = attributes["t"] ?? "n"
            value = ""
        case "v", "t":
            capturing = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t":
            capturing = false
        case "c":
            guard let (row, column) = Self.position(reference) else { return }
            var resolved = value
            if type == "s", let index = Int(value), sharedStrings.indices.contains(index) { resolved = sharedStrings[index] }
            if type == "b" { resolved = value == "1" ? "TRUE" : "FALSE" }
            cells.append((row, column, resolved))
        default:
            break
        }
    }

    static func position(_ reference: String) -> (Int, Int)? {
        let letters = reference.prefix { $0.isLetter }
        guard let row = Int(reference.dropFirst(letters.count)), !letters.isEmpty else { return nil }
        var column = 0
        for scalar in letters.uppercased().unicodeScalars {
            column = column * 26 + Int(scalar.value) - 64
        }
        return (row - 1, column - 1)
    }
}
