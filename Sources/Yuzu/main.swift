import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if PreviewRenderer.run(arguments: CommandLine.arguments) {
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar app without a Dock icon.
    app.setActivationPolicy(.accessory)
    app.run()
}
