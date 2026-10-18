import AppKit
import Combine
import OSLog
import YuzuCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let monitor = DragMonitor()
    private let wheel = WheelController()
    private let jobs = JobCenter()
    private let floatShelf = FloatShelfController()
    private let settingsWindow = SettingsWindowController()
    private let toolOptions = ToolOptionsPanelController()
    private var statusItem: NSStatusItem?
    private var enabledMenuItem: NSMenuItem?
    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "app.yuzu.Yuzu", category: "jobs")

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        monitor.onEvent = { [weak self] event in self?.handle(event) }
        wheel.onDrop = { [weak self] item, urls in self?.perform(item, urls: urls) }

        settings.$bindings.sink { [weak self] bindings in self?.monitor.bindings = bindings }.store(in: &cancellables)
        settings.$isEnabled.sink { [weak self] enabled in
            guard let self else { return }
            if enabled { monitor.start() } else { monitor.stop(); wheel.hide() }
            enabledMenuItem?.state = enabled ? .on : .off
        }.store(in: &cancellables)
        settings.$playsSounds.sink { [weak self] sounds in
            self?.wheel.playsSounds = sounds
            self?.jobs.playsSounds = sounds
        }.store(in: &cancellables)

        if !settings.hasCompletedWelcome {
            settings.hasCompletedWelcome = true
            settingsWindow.show(settings: settings)
        }
    }

    // MARK: - Slepen

    private func handle(_ event: DragEvent) {
        switch event {
        case .dragStarted:
            break
        case .wheelRequested(let kind):
            let urls = monitor.draggedFileURLs()
            // Alleen voor bestanden; tekst of andere sleepacties negeren we.
            guard !urls.isEmpty else { return }
            wheel.show(kind: kind, items: WheelItem.items(for: kind, urls: urls), fileCount: urls.count)
        case .dragEnded(let wheelWasOpen):
            if wheelWasOpen { wheel.scheduleHide() }
        case .cancelled:
            wheel.hide()
        }
    }

    private func perform(_ item: WheelItem, urls: [URL]) {
        logger.info("drop op \(item.title, privacy: .public) met \(urls.count) bestand(en)")
        switch item.payload {
        case .convert(let format):
            convert(urls, to: format)
        case .tool(let tool) where tool.hasOptionsPanel:
            toolOptions.show(tool, urls: urls) { [weak self] options in self?.run(tool, on: urls, options: options) }
        case .tool(let tool):
            run(tool, on: urls)
        case .action(let action):
            FileActions.perform(action, urls: urls, floatShelf: floatShelf)
        }
    }

    private func convert(_ urls: [URL], to format: ConversionFormat) {
        let conversionSettings = settings.conversionSettings
        let subject = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) bestanden"
        jobs.start(title: "\(subject) → \(format.displayName)") { progress in
            try await BatchConverter.convert(urls, to: format, settings: conversionSettings, progress: progress)
        }
    }

    private func run(_ tool: FileTool, on urls: [URL], options: FileToolOptions? = nil) {
        let conversionSettings = settings.conversionSettings
        let subject = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) bestanden"
        jobs.start(title: "\(tool.displayName): \(subject)") { progress in
            let result = try await FileToolEngine.run(tool, sources: urls, options: options, settings: conversionSettings,
                                                    progress: progress)
            if let message = result.message {
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
            }
            return result
        }
    }

    // MARK: - Menubalk

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.grid.cross", accessibilityDescription: "Yuzu")
        let menu = NSMenu()

        let header = NSMenuItem(title: "Sleep een bestand en tik ⇧, ⌘ of ⌃", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let enabled = NSMenuItem(title: "Actief", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = settings.isEnabled ? .on : .off
        menu.addItem(enabled)
        enabledMenuItem = enabled

        let float = NSMenuItem(title: "Open Float", action: #selector(openFloat), keyEquivalent: "")
        float.target = self
        menu.addItem(float)
        menu.addItem(.separator())

        let preferences = NSMenuItem(title: "Instellingen…", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Stop Yuzu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
    }

    @objc private func openFloat() {
        floatShelf.show()
    }

    @objc private func openSettings() {
        settingsWindow.show(settings: settings)
    }
}
