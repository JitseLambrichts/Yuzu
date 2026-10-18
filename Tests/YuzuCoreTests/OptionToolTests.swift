import AppKit
import Foundation
import Testing
@testable import YuzuCore

@Suite struct ToolCatalogTests {
    @Test func newToolsFollowSelection() {
        let image = URL(fileURLWithPath: "/tmp/a.png")
        let video = URL(fileURLWithPath: "/tmp/a.mov")
        let audio = URL(fileURLWithPath: "/tmp/a.mp3")
        #expect(ConversionCatalog.tools(for: [image]).contains(.cropImage))
        #expect(ConversionCatalog.tools(for: [image, URL(fileURLWithPath: "/tmp/b.jpg")]).contains(.cropImage))
        #expect(ConversionCatalog.tools(for: [video]).contains(.trimVideo))
        #expect(!ConversionCatalog.tools(for: [video, video]).contains(.trimVideo))
        #expect(ConversionCatalog.tools(for: [audio]).contains(.trimAudio))
        #expect(!ConversionCatalog.tools(for: [audio]).contains(.trimVideo))
    }

    @Test func optionPanelTools() {
        #expect(FileTool.allCases.filter(\.hasOptionsPanel) == [.compress, .cropImage, .trimVideo, .trimAudio])
    }

    @Test func toolsWithPanelRefuseWithoutOptions() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.makeImage(in: dir)
        await #expect(throws: YuzuError.self) {
            try await FileToolEngine.run(.cropImage, sources: [source])
        }
    }
}

@Suite struct CropGeometryTests {
    let size = CGSize(width: 1000, height: 500)

    @Test func largestRectIsCentered() {
        #expect(CropGeometry.largestRect(ratio: 1, in: size) == CGRect(x: 250, y: 0, width: 500, height: 500))
        #expect(CropGeometry.largestRect(ratio: 4, in: size) == CGRect(x: 0, y: 125, width: 1000, height: 250))
        #expect(CropGeometry.largestRect(ratio: nil, in: size) == CGRect(origin: .zero, size: size))
    }

    @Test func aspectRatioValues() {
        #expect(AspectRatio.ratio(16, 9).value(for: size) == 16.0 / 9.0)
        #expect(AspectRatio.original.value(for: size) == 2)
        #expect(AspectRatio.free.value(for: size) == nil)
        #expect(AspectRatio.presets.map(\.displayName).contains("1:1"))
    }

    @Test func clampKeepsRectInside() {
        let rect = CropGeometry.clamp(CGRect(x: 900.4, y: -20, width: 300, height: 100.6), to: size)
        #expect(rect == CGRect(x: 700, y: 0, width: 300, height: 101))
    }

    @Test func moveStopsAtEdges() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        #expect(CropGeometry.moved(rect, by: CGSize(width: 5000, height: -5000), in: size) == CGRect(x: 800, y: 0, width: 200, height: 200))
    }

    @Test func resizeFreeMovesOnlyDraggedCorner() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        let resized = CropGeometry.resized(rect, handle: .bottomRight, to: CGPoint(x: 600, y: 350), ratio: nil, in: size)
        #expect(resized == CGRect(x: 100, y: 100, width: 500, height: 250))
        let topLeft = CropGeometry.resized(rect, handle: .topLeft, to: CGPoint(x: -50, y: 50), ratio: nil, in: size)
        #expect(topLeft == CGRect(x: 0, y: 50, width: 300, height: 250))
    }

    @Test func resizeKeepsRatioAndBounds() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        let resized = CropGeometry.resized(rect, handle: .bottomRight, to: CGPoint(x: 900, y: 450), ratio: 1, in: size)
        #expect(resized == CGRect(x: 100, y: 100, width: 350, height: 350))
        let wide = CropGeometry.resized(rect, handle: .bottomRight, to: CGPoint(x: 2000, y: 2000), ratio: 16.0 / 9.0, in: size)
        #expect(wide.maxX <= size.width && wide.maxY <= size.height)
        #expect(abs(wide.width / wide.height - 16.0 / 9.0) < 0.001)
    }

    @Test func fitKeepsCenterAndRatio() {
        let fitted = CropGeometry.fit(CGRect(x: 400, y: 150, width: 200, height: 200), ratio: 4, in: size)
        #expect(abs(fitted.midX - 500) < 0.001 && abs(fitted.midY - 250) < 0.001)
        #expect(abs(fitted.width / fitted.height - 4) < 0.001)
    }

    @Test func optionsScaleToOtherImageSizes() {
        let options = CropOptions(rect: CGRect(x: 0, y: 0, width: 500, height: 500), referenceSize: size, aspectRatio: 1)
        #expect(options.pixelRect(for: size) == CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(options.pixelRect(for: CGSize(width: 2000, height: 1000)) == CGRect(x: 0, y: 0, width: 1000, height: 1000))
        // Andere verhouding: het kader blijft vierkant en binnen de afbeelding.
        let portrait = options.pixelRect(for: CGSize(width: 600, height: 900))
        #expect(portrait.width == portrait.height)
        #expect(portrait.maxX <= 600 && portrait.maxY <= 900)
    }
}

@Suite struct CropToolTests {
    @Test func cropsLeftHalf() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.makeImage(in: dir)
        let options = CropOptions(rect: CGRect(x: 0, y: 10, width: 60, height: 50), referenceSize: CGSize(width: 120, height: 80))
        let output = try #require(try await FileToolEngine.run(.cropImage, sources: [source], options: .crop(options)).outputs.first)
        #expect(output.lastPathComponent == "sample bijgesneden.png")
        let (image, _) = try ImageConverter.loadOriented(output)
        #expect(image.width == 60 && image.height == 50)
        // De linkerhelft van het testbeeld is geel.
        let rep = NSBitmapImageRep(cgImage: image)
        let color = try #require(rep.colorAt(x: 59, y: 49)?.usingColorSpace(.sRGB))
        #expect(color.redComponent > 0.9 && color.blueComponent < 0.2)
    }

    @Test func cropsEveryImageInSelection() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let a = try TestFiles.makeImage(in: dir, name: "a.png")
        let b = try TestFiles.makeImage(in: dir, name: "b.jpg", type: .jpeg)
        let options = CropOptions(rect: CropGeometry.largestRect(ratio: 1, in: CGSize(width: 120, height: 80)),
                                  referenceSize: CGSize(width: 120, height: 80), aspectRatio: 1)
        let outputs = try await FileToolEngine.run(.cropImage, sources: [a, b], options: .crop(options)).outputs
        #expect(outputs.map(\.pathExtension) == ["png", "jpg"])
        for output in outputs {
            let (image, _) = try ImageConverter.loadOriented(output)
            #expect(image.width == 80 && image.height == 80)
        }
    }
}

@Suite struct TrimAndTimecodeTests {
    @Test func formatsTimecodes() {
        #expect(Timecode.string(from: 0) == "0:00.0")
        #expect(Timecode.string(from: 62.45) == "1:02.5")
        #expect(Timecode.string(from: 3723.25, fractionDigits: 2) == "1:02:03.25")
        #expect(Timecode.string(from: 59.96) == "1:00.0")
    }

    @Test func parsesTimecodes() {
        #expect(Timecode.parse("1:02.5") == 62.5)
        #expect(Timecode.parse("1:02,5") == 62.5)
        #expect(Timecode.parse("75") == 75)
        #expect(Timecode.parse("1:00:00") == 3600)
        #expect(Timecode.parse("1:75") == nil)
        #expect(Timecode.parse("abc") == nil)
        #expect(Timecode.parse("1:2:3:4") == nil)
    }

    @Test func validatesRanges() throws {
        #expect(try TrimOptions(start: -1, end: 5).validated(totalDuration: 10) == TrimOptions(start: 0, end: 5))
        #expect(try TrimOptions(start: 2, end: 20).validated(totalDuration: 10).end == 10)
        #expect(throws: YuzuError.self) { try TrimOptions(start: 3, end: 3.01).validated(totalDuration: 10) }
        #expect(throws: YuzuError.self) { try TrimOptions(start: 0, end: 10).validated(totalDuration: 10) }
        #expect(try TrimOptions(start: 2, end: 5).validated(totalDuration: nil).duration == 3)
    }

    @Test func trimArguments() {
        let input = URL(fileURLWithPath: "/tmp/in.mov")
        let output = URL(fileURLWithPath: "/tmp/out.mov")
        let precise = FFmpegArguments.trim(input: input, output: output, options: TrimOptions(start: 1.5, end: 4), format: .mov, isVideo: true)
        #expect(precise.starts(with: ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats", "-ss", "1.500", "-t", "2.500", "-i", "/tmp/in.mov"]))
        #expect(precise.contains("h264_videotoolbox"))
        #expect(precise.last == "/tmp/out.mov")

        let fast = FFmpegArguments.trim(input: input, output: output, options: TrimOptions(start: 0, end: 2, reencode: false), format: .mov, isVideo: true)
        #expect(fast.contains("copy"))
        #expect(!fast.contains("h264_videotoolbox"))

        let audio = FFmpegArguments.trim(input: input, output: output, options: TrimOptions(start: 0, end: 2), format: .mp3, isVideo: false)
        #expect(audio.contains("-vn") && audio.contains("libmp3lame"))
    }

    @Test func parsesFFprobeOutput() throws {
        let json = #"{"streams":[{"codec_type":"video","width":1920,"height":1080},{"codec_type":"audio"}],"format":{"duration":"12.500"}}"#
        let info = try #require(MediaProbe.parseFFprobe(Data(json.utf8)))
        #expect(info == MediaInfo(duration: 12.5, videoSize: CGSize(width: 1920, height: 1080), hasAudio: true, isPlayable: false))
    }

    @Test func waveformBucketsAreNormalized() {
        let peaks = Waveform.bucket([0, 100, 200, 400, 0, 0, 0, 800], count: 4)
        #expect(peaks == [0.125, 0.5, 0, 1])
    }
}

@Suite struct CompressionTargetTests {
    @Test func targetBytes() {
        #expect(CompressionTarget.automatic.targetBytes(forOriginal: 1000) == nil)
        #expect(CompressionTarget.percentage(40).targetBytes(forOriginal: 1000) == 400)
        #expect(CompressionTarget.percentage(500).targetBytes(forOriginal: 1000) == 990)
        #expect(CompressionTarget.size(2_000_000).targetBytes(forOriginal: 1000) == 2_000_000)
    }

    @Test func videoPlanSplitsBitrate() throws {
        // 10 MB voor 60 s ≈ 1,29 Mbit/s totaal.
        let plan = try CompressionPlanner.videoPlan(targetBytes: 10_000_000, duration: 60, sourceHeight: 2160, hasAudio: true)
        #expect(plan.audioBitrate == 128_000)
        #expect(plan.videoBitrate == Int(10_000_000.0 * 8 * 0.97 / 60) - 128_000)
        #expect(plan.maxHeight == 720)

        let silent = try CompressionPlanner.videoPlan(targetBytes: 100_000_000, duration: 60, sourceHeight: 720, hasAudio: false)
        #expect(silent.audioBitrate == 0)
        #expect(silent.maxHeight == nil)
    }

    @Test func tooSmallTargetIsRejected() {
        #expect(throws: YuzuError.self) {
            try CompressionPlanner.videoPlan(targetBytes: 100_000, duration: 600, sourceHeight: 1080, hasAudio: true)
        }
        #expect(CompressionPlanner.minimumBytes(duration: 8, hasAudio: true) == Int64((164_000.0 * 8 / 8 / 0.97).rounded(.up)))
    }

    @Test func compressArguments() {
        let plan = CompressionPlanner.VideoPlan(videoBitrate: 800_000, audioBitrate: 96_000, maxHeight: 720)
        let args = FFmpegArguments.compressVideo(input: URL(fileURLWithPath: "/tmp/a.mov"), output: URL(fileURLWithPath: "/tmp/b.mp4"), plan: plan)
        #expect(args.contains("800k") && args.contains("96k"))
        #expect(args.contains("scale=-2:'min(ih,720)'"))
        #expect(args.last == "/tmp/b.mp4")
    }

    @Test func imageReachesTargetSize() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.makeNoiseImage(in: dir)
        let original = Int64(FileToolEngine.fileSize(source))
        for target in [CompressionTarget.percentage(30), .size(20_000)] {
            let output = try #require(try await FileToolEngine.run(.compress, sources: [source],
                                                                   options: .compress(.init(target: target))).outputs.first)
            let bytes = try #require(target.targetBytes(forOriginal: original))
            #expect(Int64(FileToolEngine.fileSize(output)) <= bytes)
        }
    }
}

@Suite(.enabled(if: ToolLocator.find("ffmpeg") != nil))
struct OptionMediaTests {
    @Test func trimsVideo() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let clip = try await MediaTests.makeVideo(in: dir, duration: 3)
        let output = try #require(try await FileToolEngine.run(.trimVideo, sources: [clip],
                                                               options: .trim(TrimOptions(start: 0.5, end: 1.5))).outputs.first)
        #expect(output.lastPathComponent == "clip ingekort.mov")
        let duration = try #require(await MediaConverter.duration(of: output))
        #expect(abs(duration - 1) < 0.2)
    }

    @Test func trimsAudioWithoutReencoding() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let tone = try await MediaTests.makeTone(in: dir, duration: 3)
        let output = try #require(try await FileToolEngine.run(.trimAudio, sources: [tone],
                                                               options: .trim(TrimOptions(start: 1, end: 2, reencode: false))).outputs.first)
        #expect(output.pathExtension == "wav")
        let duration = try #require(await MediaConverter.duration(of: output))
        #expect(abs(duration - 1) < 0.05)
    }

    @Test func waveformOfTone() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let tone = try await MediaTests.makeTone(in: dir)
        let peaks = try await Waveform.peaks(of: tone, count: 50)
        #expect(peaks.count == 50)
        #expect(peaks.max() == 1)
    }

    @Test func probesMedia() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let clip = try await MediaTests.makeVideo(in: dir)
        let info = await MediaProbe.info(of: clip)
        #expect(info.videoSize == CGSize(width: 320, height: 240))
        #expect(info.hasAudio)
        #expect(info.isPlayable)
    }

    @Test func compressesVideoToTarget() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let clip = try await MediaTests.makeNoiseVideo(in: dir)
        let original = FileToolEngine.fileSize(clip)
        let output = try #require(try await FileToolEngine.run(.compress, sources: [clip],
                                                               options: .compress(.init(target: .percentage(40)))).outputs.first)
        #expect(output.pathExtension == "mp4")
        #expect(Double(FileToolEngine.fileSize(output)) <= Double(original) * 0.4 * 1.1)
    }
}
