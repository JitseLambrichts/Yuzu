import AVFoundation
import AVKit
import SwiftUI
import YuzuCore

@MainActor
final class TrimModel: ObservableObject {
    let url: URL?
    let isVideo: Bool
    @Published private(set) var duration: Double = 0
    @Published private(set) var isLoaded = false
    @Published private(set) var videoSize: CGSize?
    @Published private(set) var thumbnails: [CGImage] = []
    @Published private(set) var peaks: [Float] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var player: AVPlayer?
    /// Of er afgespeeld kan worden; in de previews zonder echte speler toch `true`.
    @Published private(set) var canPlay = false
    /// Stilstaand beeld als er geen speler is (previews of formaten die AVFoundation niet afspeelt).
    @Published private(set) var stillImage: CGImage?
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var currentTime: Double = 0
    @Published var reencode = UserDefaults.standard.object(forKey: "trim.reencode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reencode, forKey: "trim.reencode") }
    }

    private var timeObserver: Any?

    init(url: URL, isVideo: Bool) {
        self.url = url
        self.isVideo = isVideo
        Task { await load(url) }
    }

    /// Voor de previews: vaste duur, golfvorm en beeld.
    init(previewDuration: Double, isVideo: Bool, still: CGImage?, peaks: [Float]) {
        url = nil
        self.isVideo = isVideo
        duration = previewDuration
        start = previewDuration * 0.18
        end = previewDuration * 0.72
        currentTime = previewDuration * 0.4
        stillImage = still
        videoSize = still.map { CGSize(width: $0.width, height: $0.height) }
        self.peaks = peaks
        if let still { thumbnails = Array(repeating: still, count: 10) }
        canPlay = true
        isLoaded = true
    }

    private func load(_ url: URL) async {
        let info = await MediaProbe.info(of: url)
        duration = info.duration ?? 0
        end = duration
        videoSize = info.videoSize
        isLoaded = true
        if info.isPlayable {
            let player = AVPlayer(url: url)
            player.actionAtItemEnd = .pause
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.playerAdvanced(to: time.seconds) }
            }
            self.player = player
            canPlay = true
        }
        if isVideo, info.isPlayable {
            await loadThumbnails(url)
        } else if !isVideo {
            peaks = (try? await Waveform.peaks(of: url, count: 240)) ?? []
        }
    }

    private func loadThumbnails(_ url: URL) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let count = 10
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { images.append(image) }
        }
        thumbnails = images
    }

    private func playerAdvanced(to seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        // Afspelen stopt aan het eind van de selectie en begint daarna opnieuw bij het begin.
        if isPlaying, seconds >= end {
            player?.pause()
            isPlaying = false
            seek(to: start)
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        if currentTime < start || currentTime >= end - 0.05 { seek(to: start) }
        player.play()
        isPlaying = true
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setStart(_ value: Double) {
        start = min(max(value, 0), max(end - 0.1, 0))
    }

    func setEnd(_ value: Double) {
        end = max(min(value, duration), min(start + 0.1, duration))
    }

    func stop() {
        player?.pause()
        isPlaying = false
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
    }

    var canApply: Bool {
        isLoaded && duration > 0 && end - start >= 0.05 && (start > 0.0005 || end < duration - 0.0005)
    }

    var options: TrimOptions { TrimOptions(start: start, end: end, reencode: reencode) }
}

struct TrimPanel: View {
    @StateObject private var model: TrimModel
    let onApply: (FileToolOptions) -> Void
    let onCancel: () -> Void

    init(model: @autoclosure @escaping () -> TrimModel, onApply: @escaping (FileToolOptions) -> Void, onCancel: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model())
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 36)
                .padding(.horizontal, 20)

            VStack(spacing: 12) {
                TrimTimeline(model: model).frame(height: model.isVideo ? 56 : 64)
                transport
                Toggle("Nauwkeurig knippen (opnieuw coderen)", isOn: $model.reencode)
                    .help("Uit: sneller en zonder kwaliteitsverlies, maar het begin valt op het dichtstbijzijnde keyframe.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)

            OptionsFooter(summary: "Lengte \(Timecode.string(from: model.end - model.start)) van \(Timecode.string(from: model.duration))",
                          canApply: model.canApply, onCancel: onCancel) {
                model.stop()
                onApply(.trim(model.options))
            }
        }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var preview: some View {
        if !model.isLoaded {
            ProgressView()
        } else if model.duration <= 0 {
            PanelNotice(text: "Kon de duur van dit bestand niet bepalen.")
        } else if model.isVideo {
            ZStack {
                Color.black
                if let player = model.player {
                    PlayerView(player: player)
                } else if let still = model.stillImage {
                    Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    PanelNotice(text: "Geen voorbeeld voor dit formaat; inkorten werkt wel.", systemImage: "eye.slash")
                        .foregroundStyle(.white).padding()
                }
            }
            .aspectRatio(model.videoSize.map { $0.width / max($0.height, 1) } ?? 16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(Color.yuzuAccent)
                Text(Timecode.string(from: model.currentTime, fractionDigits: 2))
                    .font(.system(size: 28, weight: .medium, design: .rounded).monospacedDigit())
                if !model.canPlay {
                    Text("Afspelen kan niet voor dit formaat; inkorten werkt wel.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            TimeField(label: "Begin", seconds: model.start) { model.setStart($0) }
            Button { model.setStart(model.currentTime) } label: { Image(systemName: "arrow.right.to.line") }
                .help("Begin op de afspeelpositie")
            Spacer()
            Button { model.seek(to: model.start) } label: { Image(systemName: "backward.end.fill") }
                .help("Naar het begin van de selectie")
            Button(action: model.togglePlayback) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .disabled(!model.canPlay)
            .help("Selectie afspelen")
            Text(Timecode.string(from: model.currentTime, fractionDigits: 2))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64)
            Spacer()
            Button { model.setEnd(model.currentTime) } label: { Image(systemName: "arrow.left.to.line") }
                .help("Eind op de afspeelpositie")
            TimeField(label: "Eind", seconds: model.end) { model.setEnd($0) }
        }
        .disabled(!model.isLoaded || model.duration <= 0)
    }
}

/// Invoerveld voor een tijd als m:ss.f; ongeldige invoer zet de oude waarde terug.
private struct TimeField: View {
    let label: String
    let seconds: Double
    let onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 78)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        }
        .onAppear { text = Timecode.string(from: seconds, fractionDigits: 2) }
        .onChange(of: seconds) { _, value in if !focused { text = Timecode.string(from: value, fractionDigits: 2) } }
    }

    private func commit() {
        if let value = Timecode.parse(text) { onCommit(value) }
        text = Timecode.string(from: seconds, fractionDigits: 2)
    }
}

/// Tijdlijn met miniaturen (video) of golfvorm (audio), versleepbare begin- en eindgreep en een afspeelkop.
private struct TrimTimeline: View {
    @ObservedObject var model: TrimModel
    @State private var dragging: Grip?

    private enum Grip { case start, end, playhead }
    private let gripWidth: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let duration = max(model.duration, 0.001)
            let x = { (seconds: Double) in CGFloat(seconds / duration) * width }
            let startX = x(model.start)
            let endX = x(model.end)

            ZStack(alignment: .topLeading) {
                background(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                // Buiten de selectie dimmen.
                Path { path in
                    path.addRect(CGRect(x: 0, y: 0, width: startX, height: height))
                    path.addRect(CGRect(x: endX, y: 0, width: width - endX, height: height))
                }
                .fill(Color.black.opacity(0.45))

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.yuzuAccent, lineWidth: 3)
                    .frame(width: max(endX - startX, gripWidth * 2), height: height)
                    .offset(x: startX)

                grip(at: startX, edge: .leading, height: height)
                grip(at: endX - gripWidth, edge: .trailing, height: height)

                Rectangle()
                    .fill(Color.white)
                    .shadow(radius: 1)
                    .frame(width: 2, height: height + 8)
                    .offset(x: x(model.currentTime) - 1, y: -4)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let seconds = Double(min(max(value.location.x, 0), width) / width) * duration
                if dragging == nil {
                    // De dichtstbijzijnde greep pakken; elders klikken verplaatst de afspeelkop.
                    let tolerance = gripWidth * 1.5
                    if abs(value.startLocation.x - startX) < tolerance { dragging = .start }
                    else if abs(value.startLocation.x - endX) < tolerance { dragging = .end }
                    else { dragging = .playhead }
                }
                switch dragging {
                case .start: model.setStart(seconds); model.seek(to: model.start)
                case .end: model.setEnd(seconds); model.seek(to: model.end)
                default: model.seek(to: seconds)
                }
            }.onEnded { _ in dragging = nil })
        }
    }

    @ViewBuilder private func background(width: CGFloat, height: CGFloat) -> some View {
        if model.isVideo, !model.thumbnails.isEmpty {
            HStack(spacing: 0) {
                ForEach(model.thumbnails.indices, id: \.self) { index in
                    Image(decorative: model.thumbnails[index], scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(model.thumbnails.count), height: height)
                        .clipped()
                }
            }
        } else if !model.peaks.isEmpty {
            ZStack {
                Color.primary.opacity(0.06)
                Canvas { context, size in
                    let bar = size.width / CGFloat(model.peaks.count)
                    for (index, peak) in model.peaks.enumerated() {
                        let barHeight = max(CGFloat(peak) * size.height * 0.9, 1)
                        let rect = CGRect(x: CGFloat(index) * bar, y: (size.height - barHeight) / 2, width: max(bar - 1, 1), height: barHeight)
                        context.fill(Path(rect), with: .color(.primary.opacity(0.55)))
                    }
                }
            }
        } else {
            Color.primary.opacity(0.08)
        }
    }

    private func grip(at x: CGFloat, edge: HorizontalEdge, height: CGFloat) -> some View {
        UnevenRoundedRectangle(cornerRadii: edge == .leading
                               ? .init(topLeading: 6, bottomLeading: 6)
                               : .init(bottomTrailing: 6, topTrailing: 6), style: .continuous)
            .fill(Color.yuzuAccent)
            .overlay(Capsule().fill(Color(nsColor: YuzuColors.accentText).opacity(0.6)).frame(width: 2, height: height * 0.4))
            .frame(width: gripWidth, height: height)
            .offset(x: x)
            .allowsHitTesting(false)
    }
}

/// AVPlayerView zonder eigen bediening; de tijdlijn eronder is de bediening.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
