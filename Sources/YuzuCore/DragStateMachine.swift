import Foundation

/// Modifier-toetsen, los van AppKit/CoreGraphics zodat de state machine testbaar blijft.
public struct ModifierSet: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = ModifierSet(rawValue: 1 << 0)
    public static let control = ModifierSet(rawValue: 1 << 1)
    public static let option = ModifierSet(rawValue: 1 << 2)
    public static let command = ModifierSet(rawValue: 1 << 3)

    /// Weergave in de gebruikelijke macOS-volgorde: ⌃⌥⇧⌘.
    public var symbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

public enum WheelKind: String, CaseIterable, Codable, Sendable {
    case convert, tools, actions

    public var displayName: String {
        switch self {
        case .convert: return "Converteren"
        case .tools: return "Tools"
        case .actions: return "Acties"
        }
    }

    public var defaultModifiers: ModifierSet {
        switch self {
        case .convert: return .shift
        case .tools: return .command
        case .actions: return .control
        }
    }
}

/// Eén meting van de invoerstatus, door de app periodiek opgehaald.
public struct InputSnapshot: Sendable {
    public var time: TimeInterval
    public var primaryButtonDown: Bool
    public var modifiers: ModifierSet
    public var escapeDown: Bool
    public var dragChangeCount: Int

    public init(time: TimeInterval, primaryButtonDown: Bool, modifiers: ModifierSet, escapeDown: Bool, dragChangeCount: Int) {
        self.time = time
        self.primaryButtonDown = primaryButtonDown
        self.modifiers = modifiers
        self.escapeDown = escapeDown
        self.dragChangeCount = dragChangeCount
    }
}

public enum DragEvent: Equatable, Sendable {
    case dragStarted
    case wheelRequested(WheelKind)
    case dragEnded(wheelWasOpen: Bool)
    case cancelled
}

/// Herkent "tijdens het slepen een modifier tikken" zonder event taps of Accessibility-rechten.
///
/// Een drag wordt herkend doordat de `changeCount` van het drag-pasteboard verandert terwijl de
/// muisknop ingedrukt is. Het wiel opent vanuit "geen modifiers" op twee manieren:
/// - tik: exact de ingestelde combinatie indrukken en binnen `tapMaxDuration` weer loslaten;
/// - vasthouden: exact de combinatie minstens `holdTriggerDelay` ingedrukt houden.
public struct DragStateMachine: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case mouseDown(baseline: Int)
        case dragging
        case wheelOpen(WheelKind)
        case waitingForRelease
    }

    public private(set) var phase: Phase = .idle
    public var bindings: [WheelKind: ModifierSet]
    public var tapMaxDuration: TimeInterval
    public var holdTriggerDelay: TimeInterval

    private var lastIdleChangeCount: Int?
    private var tapStart: TimeInterval?
    private var tapPeak: ModifierSet = []
    private var ignoreUntilModifiersReleased = false

    public init(bindings: [WheelKind: ModifierSet] = Dictionary(uniqueKeysWithValues: WheelKind.allCases.map { ($0, $0.defaultModifiers) }),
                tapMaxDuration: TimeInterval = 0.6,
                holdTriggerDelay: TimeInterval = 0.25) {
        self.bindings = bindings
        self.tapMaxDuration = tapMaxDuration
        self.holdTriggerDelay = holdTriggerDelay
    }

    /// Of er een muis-/sleepactie bezig is; de app pollt dan sneller.
    public var isActive: Bool { phase != .idle }

    public mutating func step(_ snapshot: InputSnapshot) -> [DragEvent] {
        switch phase {
        case .idle:
            guard snapshot.primaryButtonDown else {
                lastIdleChangeCount = snapshot.dragChangeCount
                return []
            }
            // De drag kan al tussen twee metingen begonnen zijn; vergelijk met de laatste waarde vóór mouse-down.
            let baseline = lastIdleChangeCount ?? snapshot.dragChangeCount
            phase = .mouseDown(baseline: baseline)
            if snapshot.dragChangeCount != baseline {
                return beginDrag(snapshot)
            }
            return []

        case .mouseDown(let baseline):
            if !snapshot.primaryButtonDown {
                returnToIdle(snapshot)
                return []
            }
            if snapshot.dragChangeCount != baseline {
                return beginDrag(snapshot)
            }
            return []

        case .dragging, .wheelOpen:
            let wheelWasOpen: Bool
            if case .wheelOpen = phase { wheelWasOpen = true } else { wheelWasOpen = false }
            if !snapshot.primaryButtonDown {
                returnToIdle(snapshot)
                return [.dragEnded(wheelWasOpen: wheelWasOpen)]
            }
            if snapshot.escapeDown {
                phase = .waitingForRelease
                resetTap()
                return [.cancelled]
            }
            if let kind = detectTap(snapshot) {
                phase = .wheelOpen(kind)
                return [.wheelRequested(kind)]
            }
            return []

        case .waitingForRelease:
            if !snapshot.primaryButtonDown {
                returnToIdle(snapshot)
            }
            return []
        }
    }

    private mutating func beginDrag(_ snapshot: InputSnapshot) -> [DragEvent] {
        phase = .dragging
        resetTap()
        // Modifiers die al vastzaten bij de start tellen niet als tik.
        ignoreUntilModifiersReleased = !snapshot.modifiers.isEmpty
        return [.dragStarted]
    }

    private mutating func returnToIdle(_ snapshot: InputSnapshot) {
        phase = .idle
        lastIdleChangeCount = snapshot.dragChangeCount
        resetTap()
    }

    private mutating func resetTap() {
        tapStart = nil
        tapPeak = []
    }

    private mutating func detectTap(_ snapshot: InputSnapshot) -> WheelKind? {
        let modifiers = snapshot.modifiers
        if ignoreUntilModifiersReleased {
            if modifiers.isEmpty { ignoreUntilModifiersReleased = false }
            return nil
        }
        guard let start = tapStart else {
            if !modifiers.isEmpty {
                tapStart = snapshot.time
                tapPeak = modifiers
            }
            return nil
        }
        if !modifiers.isEmpty {
            tapPeak.formUnion(modifiers)
            // Vastgehouden combinatie: open zodra die stabiel is, en wacht daarna tot alles los is.
            if modifiers == tapPeak, snapshot.time - start >= holdTriggerDelay, let kind = wheel(for: modifiers) {
                resetTap()
                ignoreUntilModifiersReleased = true
                return kind
            }
            if snapshot.time - start > tapMaxDuration {
                // Te lang vastgehouden zonder geldige combinatie: wacht tot alles los is.
                resetTap()
                ignoreUntilModifiersReleased = true
            }
            return nil
        }
        let peak = tapPeak
        let duration = snapshot.time - start
        resetTap()
        guard duration <= tapMaxDuration else { return nil }
        return wheel(for: peak)
    }

    private func wheel(for modifiers: ModifierSet) -> WheelKind? {
        WheelKind.allCases.first { bindings[$0] == modifiers }
    }
}
