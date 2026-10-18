import AppKit
import SwiftUI
import YuzuCore

/// Ontwikkelhulp: `Yuzu --render-previews <map>` schrijft PNG's van het wiel en de instellingen,
/// zodat de vormgeving zonder schermopname-rechten te controleren is.
@MainActor
enum PreviewRenderer {
    static func run(arguments: [String]) -> Bool {
        guard let flag = arguments.firstIndex(of: "--render-previews"), arguments.indices.contains(flag + 1) else { return false }
        let directory = URL(fileURLWithPath: arguments[flag + 1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let samples: [(String, WheelKind, [URL], Int?)] = [
            ("wheel-convert-image", .convert, [URL(fileURLWithPath: "/tmp/foto.heic")], 2),
            ("wheel-convert-video", .convert, [URL(fileURLWithPath: "/tmp/clip.mov")], nil),
            ("wheel-tools-pdf", .tools, [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf")], 1),
            ("wheel-actions", .actions, [URL(fileURLWithPath: "/tmp/map")], 0),
        ]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearanceName == .aqua ? "light" : "dark"
            for (name, kind, urls, highlight) in samples {
                let view = WheelView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
                view.appearance = NSAppearance(named: appearanceName)
                view.items = WheelItem.items(for: kind, urls: urls)
                view.title = kind.displayName
                view.subtitle = urls.count == 1 ? "1 bestand" : "\(urls.count) bestanden"
                view.playsSounds = false
                view.highlightedIndex = highlight
                write(view, background: appearanceName == .aqua ? .white : NSColor(white: 0.12, alpha: 1),
                      to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            }
            let settings = NSHostingView(rootView: SettingsView(settings: AppSettings.shared))
            settings.appearance = NSAppearance(named: appearanceName)
            settings.frame = CGRect(origin: .zero, size: settings.fittingSize)
            write(settings, background: .windowBackgroundColor, to: directory.appendingPathComponent("settings-\(suffix).png"))

            for (name, tool, view) in toolPanels() {
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearanceName)
                host.frame = CGRect(origin: .zero, size: ToolOptionsView.preferredSize(for: tool))
                // SwiftUI heeft één runloop-ronde nodig om de StateObjects en layout op te bouwen.
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                write(host, background: .windowBackgroundColor, to: directory.appendingPathComponent("panel-\(name)-\(suffix).png"))
            }
        }
        return true
    }

    /// Optiepanelen met ingebakken voorbeeldinhoud, zodat ze zonder echte bestanden te tonen zijn.
    private static func toolPanels() -> [(String, FileTool, AnyView)] {
        let photo = sampleImage(width: 1600, height: 1000)
        let crop = CropModel(previewImage: photo, urls: [URL(fileURLWithPath: "/tmp/foto.jpg")])
        crop.ratio = .ratio(4, 3)
        let still = sampleImage(width: 640, height: 360)
        let peaks = (0..<240).map { index -> Float in
            let x = Float(index)
            return min(1, abs(sin(x / 7) * 0.6 + sin(x / 2.3) * 0.25) + 0.08)
        }
        let video = TrimModel(previewDuration: 83.4, isVideo: true, still: still, peaks: [])
        let audio = TrimModel(previewDuration: 214.0, isVideo: false, still: nil, peaks: peaks)
        let compress = CompressModel(urls: [URL(fileURLWithPath: "/tmp/vakantie.mov")], sizes: [482_000_000],
                                     videoInfo: MediaInfo(duration: 245, videoSize: CGSize(width: 3840, height: 2160), hasAudio: true, isPlayable: true))
        compress.mode = .size
        compress.sizeValue = 50
        compress.unit = .mb
        let ignore: (FileToolOptions) -> Void = { _ in }
        return [
            ("crop", .cropImage, AnyView(CropPanel(model: crop, onApply: ignore, onCancel: {}))),
            ("trim-video", .trimVideo, AnyView(TrimPanel(model: video, onApply: ignore, onCancel: {}))),
            ("trim-audio", .trimAudio, AnyView(TrimPanel(model: audio, onApply: ignore, onCancel: {}))),
            ("compress", .compress, AnyView(CompressPanel(model: compress, onApply: ignore, onCancel: {}))),
        ]
    }

    /// Een "landschap" met verloop, zon en heuvels als stand-in voor een foto of videoframe.
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
        // Systeemkleuren pas omzetten onder het uiterlijk van de view, anders wint de donkere modus van het systeem.
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
