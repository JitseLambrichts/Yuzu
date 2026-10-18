import AppKit
import YuzuCore

/// Actions on the ⌃ wheel. They never change the contents of files.
@MainActor
enum FileActions {
    static func perform(_ action: FileAction, urls: [URL], floatShelf: FloatShelfController) {
        switch action {
        case .airDrop:
            NSApp.activate()
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                showAlert("AirDrop isn't available.")
                return
            }
            service.perform(withItems: urls)
        case .float:
            floatShelf.add(urls)
        case .copy:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
        case .copyPath:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .move:
            move(urls)
        case .openTerminal:
            openTerminal(at: urls)
        }
    }

    private static func move(_ urls: [URL]) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        panel.message = urls.count == 1 ? "Where should \(urls[0].lastPathComponent) go?" : "Where should \(urls.count) items go?"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        var failures: [String] = []
        for url in urls {
            let ext = url.pathExtension
            let target = OutputNaming.uniqueURL(in: destination, baseName: url.deletingPathExtension().lastPathComponent, fileExtension: ext)
            do {
                try FileManager.default.moveItem(at: url, to: target)
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        if !failures.isEmpty {
            showAlert("Couldn't move: \(failures.joined(separator: ", "))")
        }
    }

    private static func openTerminal(at urls: [URL]) {
        guard let first = urls.first else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory)
        let folder = isDirectory.boolValue ? first : first.deletingLastPathComponent()
        let workspace = NSWorkspace.shared
        guard let terminal = workspace.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            showAlert("No Terminal app found.")
            return
        }
        workspace.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func showAlert(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Yuzu"
        alert.informativeText = message
        alert.runModal()
    }
}
