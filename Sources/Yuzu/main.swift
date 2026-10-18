import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if PreviewRenderer.run(arguments: CommandLine.arguments) {
        exit(0)
    }
    if let flag = CommandLine.arguments.firstIndex(of: "--demo-wheel") {
        // Development aid: shows the real wheel (with Liquid Glass) around the cursor for a few seconds.
        let seconds = CommandLine.arguments.dropFirst(flag + 1).first.flatMap(Double.init) ?? 6
        let wheel = WheelController()
        wheel.style = AppSettings.shared.wheelStyle
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            wheel.show(kind: .tools, items: WheelItem.items(for: .tools, urls: [URL(fileURLWithPath: "/tmp/photo.png")]), fileCount: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { wheel.highlight(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        app.run()
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar app without a Dock icon.
    app.setActivationPolicy(.accessory)
    app.run()
}
