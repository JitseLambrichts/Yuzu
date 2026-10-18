import AppKit
import Foundation
import Testing
@testable import YuzuCore

/// Reads one pixel of a CGImage, with the origin at the top left.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> NSColor {
    try #require(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
}

@Suite struct FrameToolTests {
    @Test func catalogOffersNewImageTools() {
        let image = URL(fileURLWithPath: "/tmp/a.png")
        let tools = ConversionCatalog.tools(for: [image])
        #expect(tools.contains(.frameImage) && tools.contains(.annotateImage))
        #expect(ConversionCatalog.tools(for: [image, image]).contains(.frameImage))
        #expect(!ConversionCatalog.tools(for: [image, image]).contains(.annotateImage))
        #expect(FileTool.frameImage.hasOptionsPanel && FileTool.annotateImage.hasOptionsPanel)
    }

    @Test func layoutAddsPaddingAndRatio() {
        let size = CGSize(width: 400, height: 200)
        let auto = FrameGeometry.layout(imageSize: size, options: FrameOptions(padding: 0.25, ratio: .auto))
        #expect(auto.canvas == CGSize(width: 500, height: 300))
        #expect(auto.imageRect == CGRect(x: 50, y: 50, width: 400, height: 200))

        let square = FrameGeometry.layout(imageSize: size, options: FrameOptions(padding: 0.25, ratio: .square))
        #expect(square.canvas == CGSize(width: 500, height: 500))
        #expect(square.imageRect.origin == CGPoint(x: 50, y: 150))

        let story = FrameGeometry.layout(imageSize: size, options: FrameOptions(padding: 0, ratio: .story))
        #expect(abs(story.canvas.width / story.canvas.height - 9.0 / 16.0) < 0.01)
        #expect(story.canvas.width == 400)
    }

    @Test func rendersBackgroundAroundImage() throws {
        let dir = try TestFiles.temporaryDirectory()
        let (image, _) = try ImageConverter.loadOriented(try TestFiles.makeImage(in: dir))
        let options = FrameOptions(background: .solid(RGBAColor(0, 0, 1)), padding: 0.25, cornerRadius: 0.2, shadow: 0)
        let framed = try FrameRenderer.render(image, options: options)
        #expect(framed.width == 160 && framed.height == 120)
        // Corner of the canvas: background. Middle of the left half of the image: yellow.
        let corner = try pixel(framed, 2, 2)
        #expect(corner.blueComponent > 0.95 && corner.redComponent < 0.05)
        let inside = try pixel(framed, 50, 60)
        #expect(inside.redComponent > 0.9 && inside.blueComponent < 0.2)
        // The rounded corner of the image shows the background too.
        let rounded = try pixel(framed, 21, 21)
        #expect(rounded.blueComponent > 0.9)
    }

    @Test func meshAndImageBackgroundsRender() throws {
        let dir = try TestFiles.temporaryDirectory()
        let (image, _) = try ImageConverter.loadOriented(try TestFiles.makeImage(in: dir))
        for background in [FrameBackground.meshPresets[0], .image(dir.appendingPathComponent("missing.png"))] {
            let framed = try FrameRenderer.render(image, options: FrameOptions(background: background, ratio: .widescreen))
            #expect(abs(Double(framed.width) / Double(framed.height) - 16.0 / 9.0) < 0.02)
        }
    }

    @Test func writesFramedFileNextToOriginal() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.makeImage(in: dir, name: "shot.jpg", type: .jpeg)
        let background = try TestFiles.makeImage(in: dir, name: "wallpaper.png")
        let options = FrameOptions(background: .image(background), padding: 0.1, ratio: .square)
        let output = try #require(try await FileToolEngine.run(.frameImage, sources: [source], options: .frame(options)).outputs.first)
        #expect(output.lastPathComponent == "shot with background.jpg")
        let (framed, _) = try ImageConverter.loadOriented(output)
        #expect(framed.width == framed.height)
    }
}

@Suite struct AnnotationTests {
    let red = RGBAColor(1, 0, 0)

    @Test func rendersShapesOnTopOfImage() throws {
        let dir = try TestFiles.temporaryDirectory()
        let (image, _) = try ImageConverter.loadOriented(try TestFiles.makeImage(in: dir))
        let annotations = [
            Annotation(kind: .rectangle(CGRect(x: 70, y: 10, width: 40, height: 30)), color: red, lineWidth: 4),
            Annotation(kind: .step(1, at: CGPoint(x: 20, y: 60)), color: RGBAColor(0, 0, 1), lineWidth: 3),
        ]
        let result = try AnnotationRenderer.render(image, annotations: annotations)
        #expect(result.width == image.width && result.height == image.height)
        // The top edge of the rectangle (y = 10, top-left origin) is red on the green half.
        let edge = try pixel(result, 90, 10)
        #expect(edge.redComponent > 0.9 && edge.greenComponent < 0.2)
        // Inside the rectangle the image is untouched (green).
        let inside = try pixel(result, 90, 25)
        #expect(inside.greenComponent > 0.4 && inside.redComponent < 0.2)
        // The callout is a filled blue circle; its center is white or blue, never the yellow underneath.
        let callout = try pixel(result, 14, 60)
        #expect(callout.blueComponent > 0.8)
    }

    @Test func everyKindDraws() throws {
        let dir = try TestFiles.temporaryDirectory()
        let (image, _) = try ImageConverter.loadOriented(try TestFiles.makeImage(in: dir))
        let kinds: [Annotation.Kind] = [
            .pen([CGPoint(x: 5, y: 5), CGPoint(x: 30, y: 20), CGPoint(x: 60, y: 10)]),
            .highlighter([CGPoint(x: 10, y: 70), CGPoint(x: 100, y: 70)]),
            .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 60)),
            .ellipse(CGRect(x: 20, y: 20, width: 50, height: 30)),
            .text("Hi\nthere", at: CGPoint(x: 10, y: 10)),
            .magnifier(center: CGPoint(x: 60, y: 40), radius: 20),
        ]
        for kind in kinds {
            let result = try AnnotationRenderer.render(image, annotations: [Annotation(kind: kind, color: red, lineWidth: 3)])
            let before = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            let after = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
            #expect(before != after, "\(kind) changed nothing")
        }
    }

    @Test func scalingMovesEverything() {
        let annotation = Annotation(kind: .arrow(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4)), color: red, lineWidth: 2)
        let scaled = annotation.scaled(by: 2)
        #expect(scaled.kind == .arrow(from: CGPoint(x: 2, y: 4), to: CGPoint(x: 6, y: 8)))
        #expect(scaled.lineWidth == 4)
        #expect(scaled.id == annotation.id)
    }

    @Test func writesAnnotatedFile() async throws {
        let dir = try TestFiles.temporaryDirectory()
        let source = try TestFiles.makeImage(in: dir)
        let options = AnnotateOptions(annotations: [Annotation(kind: .ellipse(CGRect(x: 10, y: 10, width: 40, height: 40)),
                                                               color: red, lineWidth: 3)],
                                      referenceSize: CGSize(width: 120, height: 80))
        let output = try #require(try await FileToolEngine.run(.annotateImage, sources: [source], options: .annotate(options)).outputs.first)
        #expect(output.lastPathComponent == "sample annotated.png")
        await #expect(throws: YuzuError.self) {
            try await FileToolEngine.run(.annotateImage, sources: [source],
                                         options: .annotate(AnnotateOptions(annotations: [], referenceSize: .zero)))
        }
    }
}
