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
        }
        return true
    }

    private static func write(_ view: NSView, background: NSColor, to url: URL) {
        let container = NSView(frame: view.bounds)
        container.wantsLayer = true
        container.appearance = view.appearance
        container.layer?.backgroundColor = background.cgColor
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
