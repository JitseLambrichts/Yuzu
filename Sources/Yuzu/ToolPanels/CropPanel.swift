import AppKit
import SwiftUI
import YuzuCore

@MainActor
final class CropModel: ObservableObject {
    enum Field { case x, y, width, height }

    let urls: [URL]
    @Published private(set) var image: CGImage?
    /// Echte pixelgrootte van de eerste afbeelding; `image` is mogelijk een verkleinde versie.
    @Published private(set) var imageSize: CGSize = .zero
    @Published private(set) var loadError: String?
    /// Kader in pixels van de eerste afbeelding, oorsprong linksboven.
    @Published var rect: CGRect = .zero
    @Published var ratio: AspectRatio = .free {
        didSet { if let value = ratioValue { rect = CropGeometry.clamp(CropGeometry.fit(rect, ratio: value, in: imageSize), to: imageSize) } }
    }

    var ratioValue: Double? { ratio.value(for: imageSize) }

    init(urls: [URL]) {
        self.urls = urls
        let url = urls[0]
        Task {
            do {
                let (image, size) = try await Task.detached(priority: .userInitiated) { try ImageConverter.preview(url) }.value
                self.setImage(image, size: size)
            } catch {
                self.loadError = error.localizedDescription
            }
        }
    }

    /// Voor de previews: een vaste afbeelding, direct geladen.
    init(previewImage: CGImage, urls: [URL]) {
        self.urls = urls
        setImage(previewImage, size: CGSize(width: previewImage.width, height: previewImage.height))
    }

    private func setImage(_ image: CGImage, size: CGSize) {
        self.image = image
        imageSize = size
        rect = CGRect(origin: .zero, size: size)
    }

    func reset() {
        rect = CropGeometry.largestRect(ratio: ratioValue, in: imageSize)
    }

    func value(_ field: Field) -> Int {
        switch field {
        case .x: return Int(rect.minX.rounded())
        case .y: return Int(rect.minY.rounded())
        case .width: return Int(rect.width.rounded())
        case .height: return Int(rect.height.rounded())
        }
    }

    /// Exacte pixels invoeren; met een vaste verhouding volgt de andere zijde.
    func set(_ field: Field, to value: Int) {
        var next = rect
        let value = CGFloat(max(value, field == .x || field == .y ? 0 : 1))
        switch field {
        case .x: next.origin.x = value
        case .y: next.origin.y = value
        case .width:
            next.size.width = value
            if let ratioValue { next.size.height = value / ratioValue }
        case .height:
            next.size.height = value
            if let ratioValue { next.size.width = value * ratioValue }
        }
        if let ratioValue {
            // Past de verhouding niet meer, dan krimpt het kader in beide richtingen.
            let shrink = min(1, imageSize.width / next.width, imageSize.height / next.height)
            next.size = CGSize(width: next.width * shrink, height: next.width * shrink / ratioValue)
        }
        rect = CropGeometry.clamp(next, to: imageSize)
    }

    var options: CropOptions {
        CropOptions(rect: CropGeometry.clamp(rect, to: imageSize), referenceSize: imageSize, aspectRatio: ratioValue)
    }
}

struct CropPanel: View {
    @StateObject private var model: CropModel
    let onApply: (FileToolOptions) -> Void
    let onCancel: () -> Void

    init(model: @autoclosure @escaping () -> CropModel, onApply: @escaping (FileToolOptions) -> Void, onCancel: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model())
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image = model.image {
                    CropCanvas(model: model, image: image)
                } else if let error = model.loadError {
                    PanelNotice(text: error).padding()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 36)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .background(Color.black.opacity(0.06))

            controls
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            OptionsFooter(summary: summary, canApply: model.image != nil, onCancel: onCancel) {
                onApply(.crop(model.options))
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Picker("Verhouding", selection: $model.ratio) {
                ForEach(AspectRatio.presets) { ratio in Text(ratio.displayName).tag(ratio) }
            }
            .frame(width: 190)

            HStack(spacing: 8) {
                pixelField("X", .x)
                pixelField("Y", .y)
                pixelField("B", .width)
                pixelField("H", .height)
                Text("px").foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            Button("Herstel", action: model.reset).disabled(model.image == nil)
        }
    }

    private func pixelField(_ label: String, _ field: CropModel.Field) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: Binding(get: { model.value(field) }, set: { model.set(field, to: $0) }), format: .number.grouping(.never))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
        }
    }

    private var summary: String {
        let size = "\(model.value(.width)) × \(model.value(.height)) px"
        if model.urls.count > 1 {
            return "\(size) · toegepast op \(model.urls.count) afbeeldingen, naar verhouding geschaald"
        }
        return size
    }
}

/// De afbeelding met een versleepbaar kader, gedimde randen, derdenraster en vier hoekgrepen.
private struct CropCanvas: View {
    @ObservedObject var model: CropModel
    let image: CGImage
    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let size = model.imageSize
            let scale = min(proxy.size.width / max(size.width, 1), proxy.size.height / max(size.height, 1))
            let shown = CGSize(width: size.width * scale, height: size.height * scale)
            let origin = CGPoint(x: (proxy.size.width - shown.width) / 2, y: (proxy.size.height - shown.height) / 2)
            let frame = CGRect(x: origin.x + model.rect.minX * scale, y: origin.y + model.rect.minY * scale,
                               width: model.rect.width * scale, height: model.rect.height * scale)

            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: origin.x, y: origin.y)

                // Buiten het kader dimmen.
                Path { path in
                    path.addRect(CGRect(origin: origin, size: shown))
                    path.addRect(frame)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                thirds(in: frame).stroke(Color.white.opacity(0.45), lineWidth: 0.5).allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .background(Color.white.opacity(0.001))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        let start = dragStart ?? model.rect
                        dragStart = start
                        model.rect = CropGeometry.moved(start, by: CGSize(width: value.translation.width / scale,
                                                                          height: value.translation.height / scale), in: size)
                    }.onEnded { _ in
                        dragStart = nil
                        model.rect = CropGeometry.clamp(model.rect, to: size)
                    })

                ForEach(CropGeometry.Handle.allCases, id: \.self) { handle in
                    let point = corner(handle, of: frame)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.yuzuAccent)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.4), lineWidth: 0.5))
                        .frame(width: 12, height: 12)
                        .offset(x: point.x - 6, y: point.y - 6)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("crop")).onChanged { value in
                            let start = dragStart ?? model.rect
                            dragStart = start
                            let target = CGPoint(x: (value.location.x - origin.x) / scale, y: (value.location.y - origin.y) / scale)
                            model.rect = CropGeometry.resized(start, handle: handle, to: target, ratio: model.ratioValue, in: size,
                                                              minSide: 16 / scale)
                        }.onEnded { _ in
                            dragStart = nil
                            model.rect = CropGeometry.clamp(model.rect, to: size)
                        })
                }
            }
            .coordinateSpace(name: "crop")
        }
    }

    private func corner(_ handle: CropGeometry.Handle, of frame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        }
    }

    private func thirds(in frame: CGRect) -> Path {
        Path { path in
            for step in 1...2 {
                let x = frame.minX + frame.width * CGFloat(step) / 3
                let y = frame.minY + frame.height * CGFloat(step) / 3
                path.move(to: CGPoint(x: x, y: frame.minY))
                path.addLine(to: CGPoint(x: x, y: frame.maxY))
                path.move(to: CGPoint(x: frame.minX, y: y))
                path.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
        }
    }
}
