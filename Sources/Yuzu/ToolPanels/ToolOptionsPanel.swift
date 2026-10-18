import AppKit
import SwiftUI
import YuzuCore

/// Opens a tool's options panel after a drop on the ⌘ wheel. 'Apply' hands back the options; the work itself
/// then runs through JobCenter.
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
        // Yuzu is a menu bar app; without activating, the text fields don't get keyboard input.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.close()
        // The SwiftUI views stop their AVPlayer in onDisappear; releasing the hosting view triggers that.
        panel.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSPanel) === panel else { return }
        panel?.contentView = nil
        panel = nil
    }
}

/// Picks the right panel for each tool.
struct ToolOptionsView: View {
    let tool: FileTool
    let urls: [URL]
    let onApply: (FileToolOptions) -> Void
    let onCancel: () -> Void

    static func title(for tool: FileTool, urls: [URL]) -> String {
        let subject = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        return "\(tool.displayName) — \(subject)"
    }

    static func preferredSize(for tool: FileTool) -> CGSize {
        switch tool {
        case .cropImage: return CGSize(width: 720, height: 600)
        case .frameImage: return CGSize(width: 680, height: 720)
        case .annotateImage: return CGSize(width: 820, height: 640)
        case .trimVideo: return CGSize(width: 720, height: 620)
        case .trimAudio: return CGSize(width: 720, height: 400)
        default: return CGSize(width: 460, height: 330)
        }
    }

    static func minimumSize(for tool: FileTool) -> CGSize {
        switch tool {
        case .cropImage, .trimVideo: return CGSize(width: 560, height: 460)
        case .frameImage: return CGSize(width: 600, height: 640)
        case .annotateImage: return CGSize(width: 680, height: 500)
        case .trimAudio: return CGSize(width: 560, height: 360)
        default: return CGSize(width: 420, height: 300)
        }
    }

    var body: some View {
        switch tool {
        case .cropImage:
            CropPanel(model: CropModel(urls: urls), onApply: onApply, onCancel: onCancel)
        case .frameImage:
            BackgroundPanel(model: BackgroundModel(urls: urls), onApply: onApply, onCancel: onCancel)
        case .annotateImage:
            AnnotatePanel(model: AnnotateModel(url: urls[0]), onApply: onApply, onCancel: onCancel)
        case .trimVideo, .trimAudio:
            TrimPanel(model: TrimModel(url: urls[0], isVideo: tool == .trimVideo), onApply: onApply, onCancel: onCancel)
        case .compress:
            CompressPanel(model: CompressModel(urls: urls), onApply: onApply, onCancel: onCancel)
        default:
            Text("\(tool.displayName) has no options.").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Bottom bar shared by all panels: a short summary on the left, Cancel and Apply on the right.
struct OptionsFooter: View {
    var summary: String?
    var canApply = true
    var applyTitle = "Apply"
    /// Optional button on the far left, for example "Reset".
    var secondaryTitle: String?
    var onSecondary: () -> Void = {}
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let secondaryTitle {
                Button(secondaryTitle, action: onSecondary)
            }
            if let summary {
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button(applyTitle, action: onApply).keyboardShortcut(.defaultAction).disabled(!canApply)
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// A notice inside a panel, for example when a file can't be read.
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
