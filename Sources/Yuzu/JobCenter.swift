import AppKit
import Combine
import OSLog
import SwiftUI
import YuzuCore

/// Tracks running conversions and shows them in a small floating panel at the top right.
@MainActor
final class JobCenter: ObservableObject {
    struct Job: Identifiable {
        enum State {
            case running
            case done
            case failed(String)
        }

        let id = UUID()
        var title: String
        var progress: Double?
        var state: State = .running
        var outputs: [URL] = []
        var message: String?
    }

    @Published private(set) var jobs: [Job] = []
    var playsSounds = true

    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private let logger = Logger(subsystem: "app.yuzu.Yuzu", category: "jobs")

    init() {
        cancellable = $jobs.sink { [weak self] jobs in
            DispatchQueue.main.async { self?.layoutPanel(jobCount: jobs.count) }
        }
    }

    /// Starts work in the background. `work` receives a progress callback (0...1).
    func start(title: String, work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> ToolResult) {
        let job = Job(title: title)
        jobs.append(job)
        let id = job.id
        Task.detached(priority: .userInitiated) {
            let report: @Sendable (Double) -> Void = { value in
                Task { @MainActor in self.update(id) { $0.progress = value } }
            }
            do {
                let result = try await work(report)
                await MainActor.run { self.finish(id, result: result) }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { self.fail(id, message: message) }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func finish(_ id: UUID, result: ToolResult) {
        logger.info("done: \(result.outputs.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")
        update(id) { job in
            job.state = .done
            job.progress = 1
            job.outputs = result.outputs
            job.message = result.message
        }
        if playsSounds { NSSound(named: "Glass")?.play() }
        removeLater(id, after: result.message == nil ? 5 : 12)
    }

    private func fail(_ id: UUID, message: String) {
        logger.error("failed: \(message, privacy: .public)")
        update(id) { $0.state = .failed(message) }
        if playsSounds { NSSound(named: "Basso")?.play() }
        removeLater(id, after: 12)
    }

    func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    private func removeLater(_ id: UUID, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.remove(id) }
    }

    // MARK: - Panel

    private func layoutPanel(jobCount: Int) {
        guard jobCount > 0 else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        let height = CGFloat(jobCount) * 76 + 16
        let width: CGFloat = 340
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(CGRect(x: visible.maxX - width - 12, y: visible.maxY - height - 12, width: width, height: height), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 340, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: JobListView(center: self))
        self.panel = panel
        return panel
    }
}

private struct JobListView: View {
    @ObservedObject var center: JobCenter

    var body: some View {
        VStack(spacing: 8) {
            ForEach(center.jobs) { job in
                JobRow(job: job) { center.remove(job.id) }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct JobRow: View {
    let job: JobCenter.Job
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                detail
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(height: 68)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: YuzuColors.accent)).font(.system(size: 18))
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 16))
        }
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .running:
            if let progress = job.progress {
                ProgressView(value: progress).progressViewStyle(.linear).tint(Color(nsColor: YuzuColors.accent))
            } else {
                Text("Working…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .done:
            if let message = job.message {
                Text("Copied: \(message)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        case .failed(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
        }
    }
}
