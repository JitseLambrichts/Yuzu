import Foundation
import Testing
@testable import YuzuCore

@Suite struct CatalogTests {
    @Test func categoriesFromExtensions() {
        #expect(FileCategory.of(URL(fileURLWithPath: "/tmp/a.JPEG")) == .image)
        #expect(FileCategory.of(URL(fileURLWithPath: "/tmp/a.mov")) == .video)
        #expect(FileCategory.of(URL(fileURLWithPath: "/tmp/a.flac")) == .audio)
        #expect(FileCategory.of(URL(fileURLWithPath: "/tmp/a.tar.gz")) == .archive)
        #expect(FileCategory.of(URL(fileURLWithPath: "/tmp/a.docx")) == .document)
        #expect(FileCategory.of(URL(fileURLWithPath: "/tmp/a.srt")) == .subtitle)
        #expect(FileCategory.of(URL(fileURLWithPath: "/tmp/a.unknownext")) == .other)
    }

    @Test func ownFormatIsExcluded() {
        let targets = ConversionCatalog.targets(for: [URL(fileURLWithPath: "/tmp/photo.jpeg")])
        #expect(!targets.contains(.jpg))
        #expect(targets.contains(.png))
        #expect(targets.contains(.pdf))
    }

    @Test func mixedSelectionUsesIntersection() {
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.mp4")]
        #expect(ConversionCatalog.targets(for: urls).isEmpty)
        let images = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.heic")]
        let targets = ConversionCatalog.targets(for: images)
        #expect(targets.contains(.png))
        #expect(targets.contains(.jpg))
    }

    @Test func videoCanBecomeGifAndMp3() {
        let targets = ConversionCatalog.targets(for: [URL(fileURLWithPath: "/tmp/clip.mov")])
        #expect(targets.contains(.gif))
        #expect(targets.contains(.mp3))
        #expect(!targets.contains(.mov))
    }

    @Test func toolsFollowSelection() {
        let pdfs = [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf")]
        #expect(ConversionCatalog.tools(for: pdfs).contains(.mergePDF))
        #expect(!ConversionCatalog.tools(for: [pdfs[0]]).contains(.mergePDF))
        #expect(ConversionCatalog.tools(for: [URL(fileURLWithPath: "/tmp/a.png")]).contains(.readQRCode))
        #expect(ConversionCatalog.tools(for: [URL(fileURLWithPath: "/tmp/a.zip")]) == [.extractArchive])
    }

    @Test func modifierSymbolsUseMacOrder() {
        #expect(ModifierSet([.command, .shift, .control]).symbols == "⌃⇧⌘")
    }
}

@Suite struct OutputNamingTests {
    @Test func picksFreeName() throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = dir.appendingPathComponent("photo.png")
        #expect(OutputNaming.output(for: source, fileExtension: "jpg").lastPathComponent == "photo.jpg")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("photo.jpg").path, contents: Data())
        #expect(OutputNaming.output(for: source, fileExtension: "jpg").lastPathComponent == "photo 2.jpg")
        #expect(OutputNaming.output(for: source, fileExtension: "jpg", suffix: "gecomprimeerd").lastPathComponent == "photo gecomprimeerd.jpg")
    }

    @Test func tarGzBaseName() {
        #expect(OutputNaming.baseName(of: URL(fileURLWithPath: "/tmp/backup.tar.gz")) == "backup")
    }
}
