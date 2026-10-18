import Combine
import Foundation
import ServiceManagement
import YuzuCore

/// Instellingen in UserDefaults, observeerbaar voor SwiftUI.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "isEnabled") } }
    @Published var quality: Quality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    @Published var preserveMetadata: Bool { didSet { defaults.set(preserveMetadata, forKey: "preserveMetadata") } }
    @Published var playsSounds: Bool { didSet { defaults.set(playsSounds, forKey: "playsSounds") } }
    @Published var hasCompletedWelcome: Bool { didSet { defaults.set(hasCompletedWelcome, forKey: "hasCompletedWelcome") } }
    @Published private(set) var bindings: [WheelKind: ModifierSet]

    /// Modifier-combinaties die je per wiel kunt kiezen.
    static let modifierChoices: [ModifierSet] = [
        .shift, .command, .control, .option,
        [.shift, .command], [.control, .shift], [.option, .shift], [.control, .option],
    ]

    private init() {
        defaults.register(defaults: ["isEnabled": true, "preserveMetadata": true, "playsSounds": true])
        isEnabled = defaults.bool(forKey: "isEnabled")
        quality = Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .balanced
        preserveMetadata = defaults.bool(forKey: "preserveMetadata")
        playsSounds = defaults.bool(forKey: "playsSounds")
        hasCompletedWelcome = defaults.bool(forKey: "hasCompletedWelcome")
        var bindings: [WheelKind: ModifierSet] = [:]
        for kind in WheelKind.allCases {
            let stored = defaults.integer(forKey: "modifiers.\(kind.rawValue)")
            bindings[kind] = stored == 0 ? kind.defaultModifiers : ModifierSet(rawValue: stored)
        }
        self.bindings = bindings
    }

    var conversionSettings: ConversionSettings {
        ConversionSettings(quality: quality, preserveMetadata: preserveMetadata)
    }

    func modifiers(for kind: WheelKind) -> ModifierSet {
        bindings[kind] ?? kind.defaultModifiers
    }

    func setModifiers(_ modifiers: ModifierSet, for kind: WheelKind) {
        bindings[kind] = modifiers
        defaults.set(modifiers.rawValue, forKey: "modifiers.\(kind.rawValue)")
    }

    /// Wielen die dezelfde combinatie delen; dan opent alleen het eerste.
    var conflictingKinds: Set<WheelKind> {
        var seen: [ModifierSet: WheelKind] = [:]
        var conflicts: Set<WheelKind> = []
        for kind in WheelKind.allCases {
            let modifiers = modifiers(for: kind)
            if let other = seen[modifiers] {
                conflicts.insert(kind)
                conflicts.insert(other)
            } else {
                seen[modifiers] = kind
            }
        }
        return conflicts
    }

    // MARK: - Starten bij inloggen

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
    }
}

extension ModifierSet {
    var label: String {
        var names: [String] = []
        if contains(.control) { names.append("Control") }
        if contains(.option) { names.append("Option") }
        if contains(.shift) { names.append("Shift") }
        if contains(.command) { names.append("Command") }
        return "\(symbols)  \(names.joined(separator: " + "))"
    }
}
