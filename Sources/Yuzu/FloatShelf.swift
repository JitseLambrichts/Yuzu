import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Floating shelf where you "park" files for a moment and drag them out again later.
@MainActor
final class FloatShelfController: ObservableObject {
    @Published private(set) var urls: [URL] = []
    private var panel: NSPanel?

    func add(_ newURLs: [URL]) {
        for url in newURLs where !urls.contains(url) {
            urls.append(url)
        }
        show()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url }
    }

    func clear() {
        urls.removeAll()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        if !panel.isVisible, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: visible.maxX - panel.frame.width - 16, y: visible.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 260, height: 340),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Float"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: FloatShelfView(shelf: self))
        self.panel = panel
        return panel
    }
}

private struct FloatShelfView: View {
    @ObservedObject var shelf: FloatShelfController
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if shelf.urls.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Drop files here").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(shelf.urls, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 28, height: 28)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                shelf.remove(url)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    }
                }
                .listStyle(.plain)
                HStack {
                    Text(shelf.urls.count == 1 ? "1 item" : "\(shelf.urls.count) items")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { shelf.clear() }.controlSize(.small)
                }
                .padding(8)
            }
        }
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in shelf.add([url]) }
                }
            }
            return true
        }
    }
}
