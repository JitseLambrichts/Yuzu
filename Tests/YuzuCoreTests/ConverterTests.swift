import AppKit
import Foundation
import PDFKit
import Testing
@testable import YuzuCore

@Suite struct ImageConverterTests {
    @Test(arguments: [ConversionFormat.jpg, .heic, .tiff, .bmp, .webp, .pdf])
    func pngConvertsTo(_ format: ConversionFormat) async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.makeImage(in: dir)
        let outputs = try await ConversionEngine.convert(source, to: format)
        #expect(outputs.count == 1)
        let output = try #require(outputs.first)
        #expect(output.pathExtension == format.fileExtension)
        if format == .pdf {
            #expect(PDFDocument(url: output)?.pageCount == 1)
        } else {
            #expect(TestFiles.imageType(output) == ImageCapabilities.utType(for: format)?.identifier)
        }
    }

    @Test func transparentPngToJpgIsFlattened() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.makeImage(in: dir, alpha: true)
        let output = try #require(try await ConversionEngine.convert(source, to: .jpg).first)
        let (image, _) = try ImageConverter.loadOriented(output)
        #expect(!image.hasAlpha)
    }

    @Test func metadataCanBeDropped() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.makeImage(in: dir, name: "meta.jpg", type: .jpeg, metadata: true)
        #expect(TestFiles.imageProperties(source)[kCGImagePropertyGPSDictionary] != nil)
        let output = try #require(try await ConversionEngine.convert(source, to: .png,
                                                                     settings: .init(preserveMetadata: false)).first)
        #expect(TestFiles.imageProperties(output)[kCGImagePropertyGPSDictionary] == nil)
    }
}

@Suite struct FileToolTests {
    @Test func removeMetadataStripsGPS() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.makeImage(in: dir, name: "meta.jpg", type: .jpeg, metadata: true)
        let result = try await FileToolEngine.run(.removeMetadata, sources: [source])
        let output = try #require(result.outputs.first)
        #expect(TestFiles.imageProperties(output)[kCGImagePropertyGPSDictionary] == nil)
        #expect(TestFiles.imageType(output) == "public.jpeg")
    }

    @Test func createMergeAndSplitPDF() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let a = try TestFiles.makeImage(in: dir, name: "a.png")
        let b = try TestFiles.makeImage(in: dir, name: "b.png")
        let created = try #require(try await FileToolEngine.run(.createPDF, sources: [a, b]).outputs.first)
        #expect(PDFDocument(url: created)?.pageCount == 2)

        let single = try #require(try await ConversionEngine.convert(a, to: .pdf).first)
        let merged = try #require(try await FileToolEngine.run(.mergePDF, sources: [created, single]).outputs.first)
        #expect(PDFDocument(url: merged)?.pageCount == 3)

        let folder = try #require(try await FileToolEngine.run(.splitPDF, sources: [merged]).outputs.first)
        let pages = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(pages.count == 3)
    }

    @Test func compressImageIsSmallerOrReportsNothingToDo() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.makeImage(in: dir, name: "big.tiff", type: .tiff)
        let result = try await FileToolEngine.run(.compress, sources: [source])
        let output = try #require(result.outputs.first)
        let size = { (url: URL) in try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        #expect(try size(output) < size(source))
    }
}

@Suite struct DocumentConverterTests {
    @Test func markdownRoundTripKeepsStructure() {
        let markdown = "# Titel\n\nEen **vette** en *cursieve* zin.\n\n- eerste\n- tweede\n"
        let attributed = Markdown.attributedString(from: markdown)
        #expect(attributed.string.contains("Titel"))
        let back = Markdown.markdown(from: attributed)
        #expect(back.contains("# Titel"))
        #expect(back.contains("**vette**"))
        #expect(back.contains("*cursieve*"))
        #expect(back.contains("- eerste"))
    }

    @Test(arguments: [ConversionFormat.docx, .pdf, .rtf, .odt, .html, .txt])
    func markdownConvertsTo(_ format: ConversionFormat) async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.write("# Hallo\n\nDit is **Yuzu**.\n", to: dir, name: "notes.md")
        let output = try #require(try await ConversionEngine.convert(source, to: format).first)
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size > 0)
        if format == .pdf {
            let text = PDFDocument(url: output)?.string ?? ""
            #expect(text.contains("Yuzu"))
        }
    }

    @Test func docxRoundTrip() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.write("Regel een\nRegel twee\n", to: dir, name: "plain.txt")
        let docx = try #require(try await ConversionEngine.convert(source, to: .docx).first)
        let back = try #require(try await ConversionEngine.convert(docx, to: .txt).first)
        let text = try String(contentsOf: back, encoding: .utf8)
        #expect(text.contains("Regel twee"))
    }

    @Test func pdfToTextAndImages() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.write("Pagina met tekst over citrus.\n", to: dir, name: "doc.txt")
        let pdf = try #require(try await ConversionEngine.convert(source, to: .pdf).first)
        let txt = try #require(try await ConversionEngine.convert(pdf, to: .txt).first)
        #expect(try String(contentsOf: txt, encoding: .utf8).contains("citrus"))
        let png = try #require(try await ConversionEngine.convert(pdf, to: .png).first)
        #expect(TestFiles.imageType(png) == "public.png")
    }
}

@Suite struct TextFormatTests {
    @Test func srtToVttAndBack() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,500\nHallo\n\n2\n00:00:03,000 --> 00:00:04,000\n<i>Wereld</i>\n"
        let cues = SubtitleConverter.parse(srt)
        #expect(cues == [SubtitleCue(start: 1, end: 2.5, text: "Hallo"), SubtitleCue(start: 3, end: 4, text: "<i>Wereld</i>")])
        let vtt = SubtitleConverter.vtt(cues)
        #expect(vtt.hasPrefix("WEBVTT"))
        #expect(vtt.contains("00:00:01.000 --> 00:00:02.500"))
        #expect(SubtitleConverter.parse(vtt) == cues)
        #expect(SubtitleConverter.plainText(cues) == "Hallo\nWereld\n")
    }

    @Test func vttShortTimestamps() {
        let cues = SubtitleConverter.parse("WEBVTT\n\nintro\n01:02.500 --> 01:04.000 align:start\nHoi\n")
        #expect(cues == [SubtitleCue(start: 62.5, end: 64, text: "Hoi")])
    }

    @Test func csvParsingHandlesQuotes() {
        let table = SpreadsheetConverter.parseDelimited("naam,notitie\n\"Jansen, P\",\"zei \"\"hoi\"\"\"\n", delimiter: ",")
        #expect(table == [["naam", "notitie"], ["Jansen, P", "zei \"hoi\""]])
        #expect(SpreadsheetConverter.delimited(table, delimiter: ",") == "naam,notitie\n\"Jansen, P\",\"zei \"\"hoi\"\"\"\n")
    }

    @Test func csvToXlsxAndBack() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.write("product;prijs;code\nYuzu;3.5;007\nCitroen;1;12\n", to: dir, name: "lijst.csv")
        let xlsx = try #require(try await ConversionEngine.convert(source, to: .xlsx).first)
        let table = try await SpreadsheetConverter.readXLSX(xlsx)
        #expect(table == [["product", "prijs", "code"], ["Yuzu", "3.5", "007"], ["Citroen", "1", "12"]])
        let tsv = try #require(try await ConversionEngine.convert(xlsx, to: .tsv).first)
        #expect(try String(contentsOf: tsv, encoding: .utf8).hasPrefix("product\tprijs\tcode\n"))
    }

    @Test func columnNames() {
        #expect(SpreadsheetConverter.columnName(0) == "A")
        #expect(SpreadsheetConverter.columnName(25) == "Z")
        #expect(SpreadsheetConverter.columnName(26) == "AA")
    }
}

@Suite struct ArchiveTests {
    @Test func folderToZipToTarAndExtract() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let folder = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try TestFiles.write("inhoud", to: folder, name: "readme.txt")

        let zip = try #require(try await ConversionEngine.convert(folder, to: .zip).first)
        #expect(zip.lastPathComponent == "project.zip")
        let tgz = try #require(try await ConversionEngine.convert(zip, to: .tgz).first)
        #expect(tgz.lastPathComponent == "project.tar.gz")

        let extracted = try #require(try await FileToolEngine.run(.extractArchive, sources: [tgz]).outputs.first)
        let readme = extracted.appendingPathComponent("project/readme.txt")
        #expect(try String(contentsOf: readme, encoding: .utf8) == "inhoud")
    }
}

@Suite(.enabled(if: ToolLocator.find("ffmpeg") != nil))
struct MediaTests {
    static func makeTone(in dir: URL, duration: Int = 1) async throws -> URL {
        let url = dir.appendingPathComponent("tone.wav")
        try await ProcessRunner.runChecked(try ToolLocator.require("ffmpeg"),
                                           ["-hide_banner", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=\(duration)", url.path])
        return url
    }

    static func makeVideo(in dir: URL, duration: Int = 1) async throws -> URL {
        let url = dir.appendingPathComponent("clip.mov")
        try await ProcessRunner.runChecked(try ToolLocator.require("ffmpeg"),
                                           ["-hide_banner", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15:duration=\(duration)",
                                            "-f", "lavfi", "-i", "sine=duration=\(duration)", "-shortest", "-c:v", "mpeg4", "-c:a", "aac", url.path])
        return url
    }

    /// Ruis comprimeert slecht, dus de doelgrootte wordt echt op de proef gesteld.
    static func makeNoiseVideo(in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("ruis.mov")
        try await ProcessRunner.runChecked(try ToolLocator.require("ffmpeg"),
                                           ["-hide_banner", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=25:duration=3",
                                            "-f", "lavfi", "-i", "sine=duration=3", "-shortest", "-vf", "noise=alls=60:allf=t",
                                            "-c:v", "mpeg4", "-q:v", "2", "-c:a", "aac", url.path])
        return url
    }

    @Test(arguments: [ConversionFormat.mp3, .m4a, .flac, .ogg, .opus, .aiff, .wma])
    func audioConvertsTo(_ format: ConversionFormat) async throws {
        let dir = try TestFiles.temporaryDirectory()
        let tone = try await Self.makeTone(in: dir)
        let output = try #require(try await ConversionEngine.convert(tone, to: format).first)
        #expect((try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
    }

    @Test(arguments: [ConversionFormat.mp4, .webm, .avi, .wmv, .gif, .mp3])
    func videoConvertsTo(_ format: ConversionFormat) async throws {
        let dir = try TestFiles.temporaryDirectory()
        let clip = try await Self.makeVideo(in: dir)
        let output = try #require(try await ConversionEngine.convert(clip, to: format).first)
        #expect((try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
    }

    @Test func progressIsReported() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let clip = try await Self.makeVideo(in: dir)
        let box = ProgressBox()
        _ = try await ConversionEngine.convert(clip, to: .mp4) { box.record($0) }
        #expect(box.maximum == 1)
    }

    @Test func muteAndNormalize() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let clip = try await Self.makeVideo(in: dir)
        #expect(try await FileToolEngine.run(.muteVideo, sources: [clip]).outputs.count == 1)
        let tone = try await Self.makeTone(in: dir)
        #expect(try await FileToolEngine.run(.normalizeAudio, sources: [tone]).outputs.count == 1)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var maximum = 0.0
    func record(_ value: Double) {
        lock.lock()
        maximum = max(maximum, value)
        lock.unlock()
    }
}
