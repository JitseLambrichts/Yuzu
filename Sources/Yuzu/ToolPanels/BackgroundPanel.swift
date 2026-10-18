import AppKit
import SwiftUI
import UniformTypeIdentifiers
import YuzuCore

@MainActor
final class BackgroundModel: ObservableObject {
    let urls: [URL]
    @Published private(set) var preview: CGImage?
    /// Real pixel size of the first image, for showing padding and radius in pixels.
    @Published private(set) var pixelSize: CGSize = .zero
    @Published private(set) var rendered: CGImage?
    @Published private(set) var loadError: String?
    @Published var options = FrameOptions() { didSet { render() } }
    /// The last custom color, so the custom swatch keeps showing it.
    @Published var customColor = RGBAColor(hex: 0x3E7BFA)

    private var backgroundImages: [URL: CGImage] = [:]

    init(urls: [URL]) {
        self.urls = urls
        let url = urls[0]
        Task {
            do {
                let (image, size) = try await Task.detached(priority: .userInitiated) { try ImageConverter.preview(url, maxPixelSize: 1000) }.value
                self.setPreview(image, size: size)
            } catch {
                self.loadError = error.localizedDescription
            }
        }
    }

    /// For the previews: a fixed image, loaded right away.
    init(previewImage: CGImage, urls: [URL]) {
        self.urls = urls
        setPreview(previewImage, size: CGSize(width: previewImage.width, height: previewImage.height))
    }

    private func setPreview(_ image: CGImage, size: CGSize) {
        preview = image
        pixelSize = size
        render()
    }

    private func render() {
        guard let preview else { return }
        var backgroundImage: CGImage?
        if case .image(let url) = options.background {
            if backgroundImages[url] == nil { backgroundImages[url] = try? ImageConverter.preview(url, maxPixelSize: 1400).image }
            backgroundImage = backgroundImages[url]
        }
        rendered = try? FrameRenderer.render(preview, options: options, backgroundImage: backgroundImage)
    }

    func reset() {
        options = FrameOptions()
    }

    func pixels(_ fraction: Double) -> Int {
        Int((min(pixelSize.width, pixelSize.height) * fraction).rounded())
    }

    private lazy var colorBridge = ColorPanelBridge { [weak self] color in
        guard let srgb = color.usingColorSpace(.sRGB) else { return }
        let custom = RGBAColor(srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
        self?.customColor = custom
        self?.options.background = .solid(custom)
    }

    /// Opens the system color panel; every change updates the background right away.
    func chooseColor() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(cgColor: customColor.cgColor) ?? .systemBlue
        panel.setTarget(colorBridge)
        panel.setAction(#selector(ColorPanelBridge.colorChanged(_:)))
        panel.level = .floating + 1
        panel.orderFront(nil)
        options.background = .solid(customColor)
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a background image"
        panel.prompt = "Use as Background"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.options.background = .image(url) }
        }
    }
}

struct BackgroundPanel: View {
    @StateObject private var model: BackgroundModel
    let onApply: (FileToolOptions) -> Void
    let onCancel: () -> Void

    init(model: @autoclosure @escaping () -> BackgroundModel, onApply: @escaping (FileToolOptions) -> Void, onCancel: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model())
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
                .padding(.top, 36)
                .padding(.horizontal, 20)

            controls
                .padding(.horizontal, 28)
                .padding(.vertical, 18)

            OptionsFooter(summary: model.urls.count > 1 ? "Applied to \(model.urls.count) images" : nil,
                          canApply: model.preview != nil, applyTitle: "Save with Background",
                          secondaryTitle: "Reset", onSecondary: model.reset, onCancel: onCancel) {
                onApply(.frame(model.options))
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let rendered = model.rendered {
            Image(decorative: rendered, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        } else if let error = model.loadError {
            PanelNotice(text: error)
        } else {
            ProgressView()
        }
    }

    private var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
            GridRow(alignment: .top) {
                label("Background").padding(.top, 8)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(Array(FrameBackground.meshPresets.enumerated()), id: \.offset) { _, background in
                            swatch(background)
                        }
                        Button(action: model.chooseImage) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 15))
                                .frame(width: Self.swatchSize, height: Self.swatchSize)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
                                .overlay(selectionRing(isImageBackground))
                        }
                        .buttonStyle(.plain)
                        .help("Choose an image as background")
                    }
                    HStack(spacing: 8) {
                        ForEach(Array(FrameBackground.solidPresets.enumerated()), id: \.offset) { _, background in
                            swatch(background)
                        }
                        Button(action: model.chooseColor) {
                            Circle()
                                .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                                .overlay(Circle().fill(Color(cgColor: model.customColor.cgColor)).padding(7))
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                                .frame(width: Self.swatchSize, height: Self.swatchSize)
                                .overlay(selectionRing(model.options.background == .solid(model.customColor)))
                        }
                        .buttonStyle(.plain)
                        .help("Pick any color")
                    }
                }
            }
            GridRow {
                label("Padding")
                slider(value: $model.options.padding, range: 0...0.5, pixels: model.pixels(model.options.padding))
            }
            GridRow {
                label("Corners")
                slider(value: $model.options.cornerRadius, range: 0...0.25, pixels: model.pixels(model.options.cornerRadius))
            }
            GridRow {
                label("Shadow")
                slider(value: $model.options.shadow, range: 0...0.15, pixels: model.pixels(model.options.shadow))
            }
            GridRow {
                label("Ratio")
                Picker("Ratio", selection: $model.options.ratio) {
                    ForEach(FrameRatio.allCases, id: \.self) { ratio in Text(ratio.displayName).tag(ratio) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }

    private static let swatchSize: CGFloat = 34

    private var isImageBackground: Bool {
        if case .image = model.options.background { return true }
        return false
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
    }

    private func slider(value: Binding<Double>, range: ClosedRange<Double>, pixels: Int) -> some View {
        HStack(spacing: 12) {
            Slider(value: value, in: range).tint(Color.yuzuAccent)
            Text("\(pixels) px").monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
    }

    private func swatch(_ background: FrameBackground) -> some View {
        Button {
            model.options.background = background
        } label: {
            SwatchView(background: background)
                .frame(width: Self.swatchSize, height: Self.swatchSize)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .overlay(selectionRing(model.options.background == background))
        }
        .buttonStyle(.plain)
    }

    private func selectionRing(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Color.yuzuAccent, lineWidth: 2.5)
            .padding(-3)
            .opacity(selected ? 1 : 0)
    }
}

/// A small sample of a background, drawn with the same renderer as the result.
private struct SwatchView: View {
    let background: FrameBackground

    var body: some View {
        switch background {
        case .solid(let color):
            Color(cgColor: color.cgColor)
        default:
            if let image = Self.image(for: background) {
                Image(decorative: image, scale: 1).resizable()
            } else {
                Color.gray
            }
        }
    }

    @MainActor private static var cache: [FrameBackground: CGImage] = [:]

    @MainActor static func image(for background: FrameBackground) -> CGImage? {
        if let cached = cache[background] { return cached }
        let size = 68
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        FrameRenderer.drawBackground(background, backgroundImage: nil, in: context, bounds: CGRect(x: 0, y: 0, width: size, height: size))
        let image = context.makeImage()
        cache[background] = image
        return image
    }
}

/// Target for NSColorPanel, which still uses target/action.
final class ColorPanelBridge: NSObject {
    private let onChange: @MainActor (NSColor) -> Void

    init(onChange: @escaping @MainActor (NSColor) -> Void) {
        self.onChange = onChange
    }

    @MainActor @objc func colorChanged(_ sender: NSColorPanel) {
        onChange(sender.color)
    }
}
