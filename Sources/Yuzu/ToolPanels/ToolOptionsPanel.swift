import AppKit
import SwiftUI
import YuzuCore

/// Opent het optiepaneel van een tool na een drop op het ⌘-wiel. 'Toepassen' geeft de opties terug; het werk zelf
/// loopt daarna via JobCenter.
@MainActor
final class ToolOptionsPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

    func show(_ tool: FileTool, urls: [URL], onApply: @escaping (FileToolOptions) -> Void) {
        close()
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: ToolOptionsView.preferredSize(for: tool)),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = ToolOptionsView.title(for: tool, urls: urls)
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.contentMinSize = ToolOptionsView.minimumSize(for: tool)
        let view = ToolOptionsView(tool: tool, urls: urls,
                                   onApply: { [weak self] options in
                                       self?.close()
                                       onApply(options)
                                   },
                                   onCancel: { [weak self] in self?.close() })
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        self.panel = panel
        // Yuzu is een menubalk-app; zonder activeren krijgen de tekstvelden geen toetsenbord.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.close()
        // De SwiftUI-views stoppen hun AVPlayer in onDisappear; de hostingview loslaten zorgt daarvoor.
        panel.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSPanel) === panel else { return }
        panel?.contentView = nil
        panel = nil
    }
}

/// Kiest het juiste paneel per tool.
struct ToolOptionsView: View {
    let tool: FileTool
    let urls: [URL]
    let onApply: (FileToolOptions) -> Void
    let onCancel: () -> Void

    static func title(for tool: FileTool, urls: [URL]) -> String {
        let subject = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) bestanden"
        return "\(tool.displayName) — \(subject)"
    }

    static func preferredSize(for tool: FileTool) -> CGSize {
        switch tool {
        case .cropImage: return CGSize(width: 720, height: 600)
        case .trimVideo: return CGSize(width: 720, height: 620)
        case .trimAudio: return CGSize(width: 720, height: 400)
        default: return CGSize(width: 460, height: 330)
        }
    }

    static func minimumSize(for tool: FileTool) -> CGSize {
        switch tool {
        case .cropImage, .trimVideo: return CGSize(width: 560, height: 460)
        case .trimAudio: return CGSize(width: 560, height: 360)
        default: return CGSize(width: 420, height: 300)
        }
    }

    var body: some View {
        switch tool {
        case .cropImage:
            CropPanel(model: CropModel(urls: urls), onApply: onApply, onCancel: onCancel)
        case .trimVideo, .trimAudio:
            TrimPanel(model: TrimModel(url: urls[0], isVideo: tool == .trimVideo), onApply: onApply, onCancel: onCancel)
        case .compress:
            CompressPanel(model: CompressModel(urls: urls), onApply: onApply, onCancel: onCancel)
        default:
            Text("\(tool.displayName) heeft geen opties.").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Onderbalk die alle panelen delen: korte samenvatting links, Annuleren en Toepassen rechts.
struct OptionsFooter: View {
    var summary: String?
    var canApply = true
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let summary {
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("Annuleren", action: onCancel).keyboardShortcut(.cancelAction)
            Button("Toepassen", action: onApply).keyboardShortcut(.defaultAction).disabled(!canApply)
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Melding in een paneel, bijvoorbeeld als een bestand niet te lezen is.
struct PanelNotice: View {
    let text: String
    var systemImage = "exclamationmark.triangle"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Color {
    static let yuzuAccent = Color(nsColor: YuzuColors.accent)
}
