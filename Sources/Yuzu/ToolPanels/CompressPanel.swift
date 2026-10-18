import SwiftUI
import YuzuCore

@MainActor
final class CompressModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case automatic, percentage, size
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .automatic: return "Automatisch"
            case .percentage: return "Percentage"
            case .size: return "Doelgrootte"
            }
        }
    }

    enum Unit: String, CaseIterable, Identifiable {
        case kb = "KB", mb = "MB", gb = "GB"
        var id: String { rawValue }
        var bytes: Double {
            switch self {
            case .kb: return 1_000
            case .mb: return 1_000_000
            case .gb: return 1_000_000_000
            }
        }
    }

    let urls: [URL]
    let sizes: [Int64]
    let categories: [FileCategory]
    @Published private(set) var videoInfo: MediaInfo?

    private let defaults = UserDefaults.standard
    @Published var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "compress.mode") } }
    @Published var percentage: Double { didSet { defaults.set(percentage, forKey: "compress.percentage") } }
    @Published var sizeValue: Double { didSet { defaults.set(sizeValue, forKey: "compress.sizeValue") } }
    @Published var unit: Unit { didSet { defaults.set(unit.rawValue, forKey: "compress.unit") } }

    init(urls: [URL], sizes: [Int64]? = nil, videoInfo: MediaInfo? = nil) {
        self.urls = urls
        self.sizes = sizes ?? urls.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        categories = urls.map(FileCategory.of)
        mode = Mode(rawValue: defaults.string(forKey: "compress.mode") ?? "") ?? .automatic
        percentage = defaults.object(forKey: "compress.percentage") as? Double ?? 50
        sizeValue = defaults.object(forKey: "compress.sizeValue") as? Double ?? 10
        unit = Unit(rawValue: defaults.string(forKey: "compress.unit") ?? "") ?? .mb
        self.videoInfo = videoInfo
        if videoInfo == nil, urls.count == 1, categories.first == .video {
            Task { self.videoInfo = await MediaProbe.info(of: urls[0]) }
        }
        if onlyPDF { mode = .automatic }
    }

    var onlyPDF: Bool { categories.allSatisfy { $0 == .pdf } }
    var containsPDF: Bool { categories.contains(.pdf) }
    var totalBytes: Int64 { sizes.reduce(0, +) }

    var target: CompressionTarget {
        switch mode {
        case .automatic: return .automatic
        case .percentage: return .percentage(Int(percentage.rounded()))
        case .size: return .size(Int64(max(sizeValue, 0) * unit.bytes))
        }
    }

    var canApply: Bool {
        mode != .size || sizeValue > 0
    }

    /// Korte uitleg wat er met de bestanden gebeurt.
    var explanation: String {
        let each = urls.count > 1 ? " per bestand" : ""
        switch mode {
        case .automatic:
            return "Vaste, verstandige instellingen. Het resultaat blijft alleen staan als het kleiner is."
        case .percentage:
            let estimate = ByteCountFormatter.string(fromByteCount: totalBytes * Int64(percentage.rounded()) / 100, countStyle: .file)
            return "Doel: \(Int(percentage.rounded())) % van het origineel\(each) — samen ongeveer \(estimate)."
        case .size:
            let bytes = Int64(max(sizeValue, 0) * unit.bytes)
            let images = categories.contains(.image) ? " Afbeeldingen worden zo nodig ook kleiner gemaakt." : ""
            return "Doel: hoogstens \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))\(each).\(images)"
        }
    }

    /// Wat de doelgrootte betekent voor één video: bitrate en eventuele kleinere resolutie, of waarom het niet kan.
    var videoPlanText: String? {
        guard mode != .automatic, let info = videoInfo, let duration = info.duration, let original = sizes.first,
              let bytes = target.targetBytes(forOriginal: original) else { return nil }
        do {
            let plan = try CompressionPlanner.videoPlan(targetBytes: bytes, duration: duration,
                                                        sourceHeight: info.videoSize.map { Int($0.height) }, hasAudio: info.hasAudio)
            var parts = ["Video ≈ \(plan.videoBitrate / 1000) kbit/s"]
            if plan.audioBitrate > 0 { parts.append("audio \(plan.audioBitrate / 1000) kbit/s") }
            if let height = plan.maxHeight { parts.append("verkleind tot \(height)p") }
            return parts.joined(separator: " · ")
        } catch {
            return error.localizedDescription
        }
    }
}

struct CompressPanel: View {
    @StateObject private var model: CompressModel
    let onApply: (FileToolOptions) -> Void
    let onCancel: () -> Void

    init(model: @autoclosure @escaping () -> CompressModel, onApply: @escaping (FileToolOptions) -> Void, onCancel: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model())
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent(model.urls.count == 1 ? "Origineel" : "\(model.urls.count) bestanden",
                                   value: ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file))
                    Picker("Methode", selection: $model.mode) {
                        ForEach(CompressModel.Mode.allCases) { mode in Text(mode.displayName).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.onlyPDF)

                    switch model.mode {
                    case .automatic:
                        EmptyView()
                    case .percentage:
                        LabeledContent("Grootte") {
                            HStack {
                                Slider(value: $model.percentage, in: 10...90, step: 5)
                                Text("\(Int(model.percentage.rounded())) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                            }
                        }
                    case .size:
                        LabeledContent(model.urls.count == 1 ? "Hoogstens" : "Hoogstens per bestand") {
                            HStack(spacing: 6) {
                                TextField("Grootte", value: $model.sizeValue, format: .number.precision(.fractionLength(0...2)))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                Picker("Eenheid", selection: $model.unit) {
                                    ForEach(CompressModel.Unit.allCases) { unit in Text(unit.rawValue).tag(unit) }
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.explanation)
                        if let plan = model.videoPlanText { Text(plan) }
                        if model.containsPDF {
                            Text(model.onlyPDF ? "PDF's worden altijd automatisch gecomprimeerd."
                                               : "PDF's in de selectie worden automatisch gecomprimeerd.")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .padding(.top, 20)

            OptionsFooter(canApply: model.canApply, onCancel: onCancel) {
                onApply(.compress(CompressionOptions(target: model.target)))
            }
        }
    }
}
