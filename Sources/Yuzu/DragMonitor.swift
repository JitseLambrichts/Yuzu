import AppKit
import CoreGraphics
import OSLog
import YuzuCore

/// Pollt muisknop, modifiers, Escape en het drag-pasteboard en voert die aan de `DragStateMachine`.
///
/// Geen event tap en geen global key monitor: daarvoor zijn geen Accessibility- of
/// Input Monitoring-rechten nodig. In rust wordt traag gepold, tijdens een muisactie snel.
@MainActor
final class DragMonitor {
    var onEvent: ((DragEvent) -> Void)?

    private var machine = DragStateMachine()
    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private let dragPasteboard = NSPasteboard(name: .drag)
    private let idleInterval: TimeInterval = 0.05
    private let activeInterval: TimeInterval = 1.0 / 90

    private static let escapeKeyCode: CGKeyCode = 53
    private let logger = Logger(subsystem: "app.yuzu.Yuzu", category: "drag")

    var bindings: [WheelKind: ModifierSet] {
        get { machine.bindings }
        set { machine.bindings = newValue }
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        schedule(idleInterval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        machine = DragStateMachine(bindings: machine.bindings)
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        currentInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.2
        // `.common`, zodat er ook tijdens tracking-loops gepold wordt.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let state = CGEventSourceStateID.combinedSessionState
        let snapshot = InputSnapshot(
            time: ProcessInfo.processInfo.systemUptime,
            primaryButtonDown: CGEventSource.buttonState(state, button: .left),
            modifiers: ModifierSet(CGEventSource.flagsState(state)),
            escapeDown: CGEventSource.keyState(state, key: Self.escapeKeyCode),
            dragChangeCount: dragPasteboard.changeCount
        )
        for event in machine.step(snapshot) {
            logger.info("\(String(describing: event), privacy: .public) modifiers=\(snapshot.modifiers.symbols, privacy: .public)")
            onEvent?(event)
        }
        let desired = machine.isActive ? activeInterval : idleInterval
        if desired != currentInterval { schedule(desired) }
    }

    /// Bestands-URL's die nu gesleept worden.
    func draggedFileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return dragPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

extension ModifierSet {
    init(_ flags: CGEventFlags) {
        var set: ModifierSet = []
        if flags.contains(.maskShift) { set.insert(.shift) }
        if flags.contains(.maskControl) { set.insert(.control) }
        if flags.contains(.maskAlternate) { set.insert(.option) }
        if flags.contains(.maskCommand) { set.insert(.command) }
        self = set
    }
}
