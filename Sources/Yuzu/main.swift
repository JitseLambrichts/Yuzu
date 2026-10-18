import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if PreviewRenderer.run(arguments: CommandLine.arguments) {
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menubalk-app zonder Dock-icoon.
    app.setActivationPolicy(.accessory)
    app.run()
}
