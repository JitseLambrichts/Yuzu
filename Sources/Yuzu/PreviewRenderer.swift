import AppKit
import SwiftUI
import YuzuCore

/// Development aid: `Yuzu --render-previews <folder>` writes PNGs of the wheel, the settings and the
/// option panels, so the design can be checked without screen recording permissions.
@MainActor
enum PreviewRenderer {
    static func run(arguments: [String]) -> Bool {
        guard let flag = arguments.firstIndex(of: "--render-previews"), arguments.indices.contains(flag + 1) else { return false }
        let directory = URL(fileURLWithPath: arguments[flag + 1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let samples: [(String, WheelKind, [URL], Int?)] = [
            ("wheel-convert-image", .convert, [URL(fileURLWithPath: "/tmp/photo.heic")], 2),
            ("wheel-convert-video", .convert, [URL(fileURLWithPath: "/tmp/clip.mov")], nil),
            ("wheel-tools-image", .tools, [URL(fileURLWithPath: "/tmp/photo.png")], 1),
            ("wheel-tools-pdf", .tools, [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf")], nil),
            ("wheel-actions", .actions, [URL(fileURLWithPath: "/tmp/folder")], 0),
        ]
        // Both wheel palettes, on a colorful backdrop like a desktop wallpaper.
        // Liquid Glass itself doesn't render offscreen, so these show the see-through tint without the blur.
        for (palette, suffix) in [(WheelPalette.light.onLiquidGlass, "light"), (WheelPalette.dark.onLiquidGlass, "dark")] {
            for (name, kind, urls, highlight) in samples {
                let size = WheelView.preferredSize
                let backdrop = BackdropView(frame: CGRect(x: 0, y: 0, width: size + 160, height: size + 80))
                let view = WheelView(frame: CGRect(x: 80, y: 40, width: size, height: size))
                view.palette = palette
                view.isOnLiquidGlass = true
                view.items = WheelItem.items(for: kind, urls: urls)
                view.title = kind.displayName
                view.subtitle = urls.count == 1 ? "1 file" : "\(urls.count) files"
                view.playsSounds = false
                view.highlightedIndex = highlight
                view.settleImmediately()
                backdrop.addSubview(view)
                write(backdrop, background: .black, to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearanceName == .aqua ? "light" : "dark"
            let settings = NSHostingView(rootView: SettingsView(settings: AppSettings.shared))
            settings.appearance = NSAppearance(named: appearanceName)
            settings.frame = CGRect(origin: .zero, size: settings.fittingSize)
            write(settings, background: .windowBackgroundColor, to: directory.appendingPathComponent("settings-\(suffix).png"))

            for (name, tool, view) in toolPanels() {
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearanceName)
                host.frame = CGRect(origin: .zero, size: ToolOptionsView.preferredSize(for: tool))
                // SwiftUI needs one run loop pass to set up the StateObjects and layout.
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                write(host, background: .windowBackgroundColor, to: directory.appendingPathComponent("panel-\(name)-\(suffix).png"))
            }
        }
        return true
    }

    /// Option panels with built-in sample content, so they render without real files.
    private static func toolPanels() -> [(String, FileTool, AnyView)] {
        let photo = sampleImage(width: 1600, height: 1000)
        let crop = CropModel(previewImage: photo, urls: [URL(fileURLWithPath: "/tmp/photo.jpg")])
        crop.ratio = .ratio(4, 3)
        let still = sampleImage(width: 640, height: 360)
        let peaks = (0..<240).map { index -> Float in
            let x = Float(index)
            return min(1, abs(sin(x / 7) * 0.6 + sin(x / 2.3) * 0.25) + 0.08)
        }
        let video = TrimModel(previewDuration: 83.4, isVideo: true, still: still, peaks: [])
        let audio = TrimModel(previewDuration: 214.0, isVideo: false, still: nil, peaks: peaks)
        let compress = CompressModel(urls: [URL(fileURLWithPath: "/tmp/holiday.mov")], sizes: [482_000_000],
                                     videoInfo: MediaInfo(duration: 245, videoSize: CGSize(width: 3840, height: 2160), hasAudio: true, isPlayable: true))
        compress.mode = .size
        compress.sizeValue = 50
        compress.unit = .mb
        let background = BackgroundModel(previewImage: sampleImage(width: 900, height: 1200), urls: [URL(fileURLWithPath: "/tmp/photo.jpg")])
        let w: CGFloat = 1600, h: CGFloat = 1000
        let red = RGBAColor(hex: 0xFF3B30)
        let annotate = AnnotateModel(previewImage: sampleImage(width: Int(w), height: Int(h)), annotations: [
            Annotation(kind: .ellipse(CGRect(x: w * 0.6, y: h * 0.12, width: h * 0.32, height: h * 0.32)), color: red, lineWidth: 10),
            Annotation(kind: .arrow(from: CGPoint(x: w * 0.3, y: h * 0.25), to: CGPoint(x: w * 0.57, y: h * 0.27)), color: red, lineWidth: 10),
            Annotation(kind: .text("The sun!", at: CGPoint(x: w * 0.08, y: h * 0.17)), color: .white, lineWidth: 10),
            Annotation(kind: .highlighter([CGPoint(x: w * 0.1, y: h * 0.62), CGPoint(x: w * 0.45, y: h * 0.56)]),
                       color: RGBAColor(hex: 0xFFCC00), lineWidth: 10),
            Annotation(kind: .step(1, at: CGPoint(x: w * 0.2, y: h * 0.8)), color: RGBAColor(hex: 0x0A84FF), lineWidth: 10),
            Annotation(kind: .step(2, at: CGPoint(x: w * 0.5, y: h * 0.75)), color: RGBAColor(hex: 0x0A84FF), lineWidth: 10),
            Annotation(kind: .magnifier(center: CGPoint(x: w * 0.82, y: h * 0.72), radius: h * 0.13), color: .white, lineWidth: 10),
        ])
        let ignore: (FileToolOptions) -> Void = { _ in }
        return [
            ("background", .frameImage, AnyView(BackgroundPanel(model: background, onApply: ignore, onCancel: {}))),
            ("annotate", .annotateImage, AnyView(AnnotatePanel(model: annotate, onApply: ignore, onCancel: {}))),
            ("crop", .cropImage, AnyView(CropPanel(model: crop, onApply: ignore, onCancel: {}))),
            ("trim-video", .trimVideo, AnyView(TrimPanel(model: video, onApply: ignore, onCancel: {}))),
            ("trim-audio", .trimAudio, AnyView(TrimPanel(model: audio, onApply: ignore, onCancel: {}))),
            ("compress", .compress, AnyView(CompressPanel(model: compress, onApply: ignore, onCancel: {}))),
        ]
    }

    /// A "landscape" with a gradient, sun and hills standing in for a photo or video frame.
    private static func sampleImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let sky = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.98, green: 0.72, blue: 0.35, alpha: 1),
                                                          CGColor(red: 0.36, green: 0.56, blue: 0.86, alpha: 1)] as CFArray,
                             locations: [0, 1])!
        context.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(CGColor(red: 1, green: 0.86, blue: 0.3, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.5, width: h * 0.22, height: h * 0.22))
        for (index, color) in [CGColor(red: 0.3, green: 0.55, blue: 0.3, alpha: 1), CGColor(red: 0.18, green: 0.4, blue: 0.22, alpha: 1)].enumerated() {
            let base = h * (0.42 - CGFloat(index) * 0.14)
            context.setFillColor(color)
            context.move(to: CGPoint(x: 0, y: 0))
            context.addLine(to: CGPoint(x: 0, y: base))
            context.addCurve(to: CGPoint(x: w, y: base * 0.8), control1: CGPoint(x: w * 0.3, y: base * 1.5),
                             control2: CGPoint(x: w * 0.6, y: base * 0.3))
            context.addLine(to: CGPoint(x: w, y: 0))
            context.closePath()
            context.fillPath()
        }
        return context.makeImage()!
    }

    private static func write(_ view: NSView, background: NSColor, to url: URL) {
        let container = NSView(frame: view.bounds)
        container.wantsLayer = true
        container.appearance = view.appearance
        // Resolve system colors under the view's appearance; otherwise the system's dark mode wins.
        var color = background.cgColor
        (view.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance { color = background.cgColor }
        container.layer?.backgroundColor = color
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Blurry "wallpaper" behind the wheel previews.
private final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(srgbRed: 0.93, green: 0.62, blue: 0.62, alpha: 1),
                            NSColor(srgbRed: 0.62, green: 0.58, blue: 0.80, alpha: 1),
                            NSColor(srgbRed: 0.42, green: 0.62, blue: 0.82, alpha: 1)])?.draw(in: bounds, angle: -20)
        let hill = NSBezierPath()
        hill.move(to: CGPoint(x: 0, y: 0))
        hill.line(to: CGPoint(x: 0, y: bounds.height * 0.62))
        hill.curve(to: CGPoint(x: bounds.width, y: bounds.height * 0.4),
                   controlPoint1: CGPoint(x: bounds.width * 0.25, y: bounds.height * 0.9),
                   controlPoint2: CGPoint(x: bounds.width * 0.6, y: bounds.height * 0.1))
        hill.line(to: CGPoint(x: bounds.width, y: 0))
        hill.close()
        NSGradient(colors: [NSColor(srgbRed: 0.90, green: 0.25, blue: 0.22, alpha: 1),
                            NSColor(srgbRed: 0.20, green: 0.25, blue: 0.62, alpha: 1)])?.draw(in: hill, angle: -90)
    }
}
