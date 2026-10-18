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
                    Text("Sleep een bestand, tik een toets en laat los op het wiel.")
                        .font(.headline)
                    Text("Alles gebeurt lokaal op je Mac. De uitvoer komt naast het origineel te staan.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Toggle("Yuzu is actief", isOn: $settings.isEnabled)
            }

            Section("Sneltoetsen tijdens het slepen") {
                ForEach(WheelKind.allCases, id: \.self) { kind in
                    Picker(kind.displayName, selection: binding(for: kind)) {
                        ForEach(AppSettings.modifierChoices, id: \.rawValue) { modifiers in
                            Text(modifiers.label).tag(modifiers)
                        }
                    }
                }
                if !settings.conflictingKinds.isEmpty {
                    Label("Twee wielen gebruiken dezelfde toets; alleen het eerste opent.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Conversie") {
                Picker("Kwaliteit", selection: $settings.quality) {
                    ForEach(Quality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Metadata behouden (EXIF, locatie, tags)", isOn: $settings.preserveMetadata)
            }

            Section("Algemeen") {
                Toggle("Geluiden", isOn: $settings.playsSounds)
                Toggle("Start bij inloggen", isOn: Binding(
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
                LabeledContent("ffmpeg (audio/video)", value: ToolLocator.find("ffmpeg")?.path ?? "niet gevonden")
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
