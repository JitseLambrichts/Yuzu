import AppKit
import SwiftUI
import YuzuCore

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(settings: AppSettings) {
        if window == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Yuzu"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Drag a file, tap a key and drop it on the wheel.")
                        .font(.headline)
                    Text("Everything happens locally on your Mac. The output is saved next to the original.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Toggle("Yuzu is enabled", isOn: $settings.isEnabled)
            }

            Section("Shortcuts while dragging") {
                ForEach(WheelKind.allCases, id: \.self) { kind in
                    Picker(kind.displayName, selection: binding(for: kind)) {
                        ForEach(AppSettings.modifierChoices, id: \.rawValue) { modifiers in
                            Text(modifiers.label).tag(modifiers)
                        }
                    }
                }
                if !settings.conflictingKinds.isEmpty {
                    Label("Two wheels use the same key; only the first one opens.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Wheel") {
                Picker("Appearance", selection: $settings.wheelStyle) {
                    ForEach(WheelStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }

            Section("Conversion") {
                Picker("Quality", selection: $settings.quality) {
                    ForEach(Quality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Keep metadata (EXIF, location, tags)", isOn: $settings.preserveMetadata)
            }

            Section("General") {
                Toggle("Sounds", isOn: $settings.playsSounds)
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchesAtLogin },
                    set: { enabled in
                        do {
                            try settings.setLaunchesAtLogin(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("ffmpeg (audio/video)", value: ToolLocator.find("ffmpeg")?.path ?? "not found")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding(for kind: WheelKind) -> Binding<ModifierSet> {
        Binding(get: { settings.modifiers(for: kind) }, set: { settings.setModifiers($0, for: kind) })
    }
}
