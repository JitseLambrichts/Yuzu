import AppKit
import SwiftUI
import YuzuCore

@MainActor
final class AnnotateModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case pen, highlighter, arrow, rectangle, ellipse, text, step, magnifier
        var id: String { rawValue }

        var title: String {
            switch self {
            case .pen: return "Pen"
            case .highlighter: return "Highlighter"
            case .arrow: return "Arrow"
            case .rectangle: return "Rectangle"
            case .ellipse: return "Ellipse"
            case .text: return "Text"
            case .step: return "Numbered Step"
            case .magnifier: return "Magnifier"
            }
        }

        var symbolName: String {
            switch self {
            case .pen: return "pencil.tip"
            case .highlighter: return "highlighter"
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .text: return "textformat"
            case .step: return "1.circle"
            case .magnifier: return "plus.magnifyingglass"
            }
        }
    }

    enum Width: CaseIterable, Identifiable {
        case thin, regular, thick
        var id: Self { self }
        /// Stroke width as a fraction of the image's shorter side.
        var fraction: CGFloat {
            switch self {
            case .thin: return 0.004
            case .regular: return 0.008
            case .thick: return 0.014
            }
        }
        var dotSize: CGFloat {
            switch self {
            case .thin: return 4
            case .regular: return 7
            case .thick: return 10
            }
        }
    }

    static let colors: [RGBAColor] = [
        RGBAColor(hex: 0xFF3B30), RGBAColor(hex: 0xFF9500), RGBAColor(hex: 0xFFCC00), RGBAColor(hex: 0x34C759),
        RGBAColor(hex: 0x0A84FF), RGBAColor(hex: 0xAF52DE), RGBAColor(hex: 0x1C1C1E), .white,
    ]

    let url: URL?
    @Published private(set) var preview: CGImage?
    /// Real pixel size; annotations are stored in these coordinates.
    @Published private(set) var pixelSize: CGSize = .zero
    @Published private(set) var loadError: String?
    @Published private(set) var annotations: [Annotation] = []
    @Published var draft: Annotation?
    @Published var tool: Tool = .arrow
    @Published var color = AnnotateModel.colors[0]
    @Published var width: Width = .regular
    /// Where a new text annotation is being typed, in image pixels.
    @Published var textAnchor: CGPoint?
    @Published var textDraft = ""

    init(url: URL) {
        self.url = url
        Task {
            do {
                let (image, size) = try await Task.detached(priority: .userInitiated) { try ImageConverter.preview(url, maxPixelSize: 1800) }.value
                self.preview = image
                self.pixelSize = size
            } catch {
                self.loadError = error.localizedDescription
            }
        }
    }

    /// For the previews: a fixed image with a few annotations already on it.
    init(previewImage: CGImage, annotations: [Annotation]) {
        url = nil
        preview = previewImage
        pixelSize = CGSize(width: previewImage.width, height: previewImage.height)
        self.annotations = annotations
    }

    var lineWidth: CGFloat { max(min(pixelSize.width, pixelSize.height) * width.fraction, 2) }

    private var nextStep: Int {
        annotations.reduce(0) { count, annotation in
            if case .step = annotation.kind { return count + 1 }
            return count
        } + 1
    }

    // MARK: - Drawing gestures (image pixel coordinates)

    func dragChanged(from start: CGPoint, to point: CGPoint) {
        guard tool != .text, tool != .step else { return }
        let point = clamp(point)
        if var draft {
            switch draft.kind {
            case .pen(let points): draft.kind = .pen(points + [point])
            case .highlighter(let points): draft.kind = .highlighter(points + [point])
            case .arrow(let from, _): draft.kind = .arrow(from: from, to: point)
            case .rectangle: draft.kind = .rectangle(rect(start, point))
            case .ellipse: draft.kind = .ellipse(rect(start, point))
            case .magnifier(let center, _): draft.kind = .magnifier(center: center, radius: hypot(point.x - center.x, point.y - center.y))
            default: break
            }
            self.draft = draft
        } else {
            let start = clamp(start)
            let kind: Annotation.Kind
            switch tool {
            case .pen: kind = .pen([start, point])
            case .highlighter: kind = .highlighter([start, point])
            case .arrow: kind = .arrow(from: start, to: point)
            case .rectangle: kind = .rectangle(rect(start, point))
            case .ellipse: kind = .ellipse(rect(start, point))
            case .magnifier: kind = .magnifier(center: start, radius: hypot(point.x - start.x, point.y - start.y))
            case .text, .step: return
            }
            draft = Annotation(kind: kind, color: color, lineWidth: lineWidth)
        }
    }

    func dragEnded(at point: CGPoint, wasTap: Bool) {
        let point = clamp(point)
        switch tool {
        case .step:
            annotations.append(Annotation(kind: .step(nextStep, at: point), color: color, lineWidth: lineWidth))
        case .text:
            commitText()
            textAnchor = point
            textDraft = ""
        case .magnifier where wasTap || isTiny(draft):
            // A click places a loupe of a sensible size.
            let radius = min(pixelSize.width, pixelSize.height) * 0.12
            annotations.append(Annotation(kind: .magnifier(center: point, radius: radius), color: .white, lineWidth: lineWidth))
        default:
            if let draft, !isTiny(draft) {
                var finished = draft
                if case .magnifier = finished.kind { finished.color = .white }
                annotations.append(finished)
            }
        }
        draft = nil
    }

    func commitText() {
        defer { textAnchor = nil; textDraft = "" }
        guard let anchor = textAnchor, !textDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        annotations.append(Annotation(kind: .text(textDraft, at: anchor), color: color, lineWidth: lineWidth))
    }

    func undo() {
        if textAnchor != nil { textAnchor = nil; return }
        _ = annotations.popLast()
    }

    func clear() {
        annotations.removeAll()
        textAnchor = nil
    }

    private func isTiny(_ annotation: Annotation?) -> Bool {
        guard let annotation else { return true }
        let minimum = max(lineWidth, 3)
        switch annotation.kind {
        case .pen(let points), .highlighter(let points): return points.count < 2
        case .arrow(let from, let to): return hypot(to.x - from.x, to.y - from.y) < minimum * 2
        case .rectangle(let rect), .ellipse(let rect): return rect.width < minimum && rect.height < minimum
        case .magnifier(_, let radius): return radius < minimum * 3
        default: return false
        }
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), pixelSize.width), y: min(max(point.y, 0), pixelSize.height))
    }

    var options: AnnotateOptions {
        AnnotateOptions(annotations: annotations, referenceSize: pixelSize)
    }
}

struct AnnotatePanel: View {
    @StateObject private var model: AnnotateModel
    let onApply: (FileToolOptions) -> Void
    let onCancel: () -> Void

    init(model: @autoclosure @escaping () -> AnnotateModel, onApply: @escaping (FileToolOptions) -> Void, onCancel: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model())
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.top, 34)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            Group {
                if let preview = model.preview {
                    AnnotationCanvas(model: model, preview: preview)
                } else if let error = model.loadError {
                    PanelNotice(text: error).padding()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .background(Color.primary.opacity(0.05))

            OptionsFooter(summary: summary, canApply: !model.annotations.isEmpty || model.textAnchor != nil,
                          applyTitle: "Save Annotations", onCancel: onCancel) {
                model.commitText()
                onApply(.annotate(model.options))
            }
        }
    }

    private var summary: String {
        switch model.annotations.count {
        case 0: return "Drag on the image to draw"
        case 1: return "1 annotation"
        default: return "\(model.annotations.count) annotations"
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(AnnotateModel.Tool.allCases) { tool in
                    Button {
                        model.commitText()
                        model.tool = tool
                    } label: {
                        Image(systemName: tool.symbolName)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 26)
                            .foregroundStyle(model.tool == tool ? Color(nsColor: YuzuColors.accentText) : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(model.tool == tool ? Color.yuzuAccent : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tool.title)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))

            HStack(spacing: 6) {
                ForEach(AnnotateModel.colors, id: \.self) { color in
                    Button { model.color = color } label: {
                        Circle()
                            .fill(Color(cgColor: color.cgColor))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            .frame(width: 18, height: 18)
                            .padding(3)
                            .overlay(Circle().strokeBorder(Color.yuzuAccent, lineWidth: 2).opacity(model.color == color ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 2) {
                ForEach(AnnotateModel.Width.allCases) { width in
                    Button { model.width = width } label: {
                        Circle().fill(Color.primary.opacity(0.75))
                            .frame(width: width.dotSize, height: width.dotSize)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.width == width ? Color.primary.opacity(0.12) : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .help("Line width")

            Spacer(minLength: 0)

            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.annotations.isEmpty && model.textAnchor == nil)
                .help("Undo")
            Button("Clear", action: model.clear)
                .disabled(model.annotations.isEmpty)
        }
    }
}

/// The image with all annotations drawn by the same renderer as the saved file, plus the gesture to draw new ones.
private struct AnnotationCanvas: View {
    @ObservedObject var model: AnnotateModel
    let preview: CGImage
    @FocusState private var textFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = model.pixelSize
            let scale = min(proxy.size.width / max(size.width, 1), proxy.size.height / max(size.height, 1))
            let shown = CGSize(width: size.width * scale, height: size.height * scale)
            let origin = CGPoint(x: (proxy.size.width - shown.width) / 2, y: (proxy.size.height - shown.height) / 2)
            let marks = model.annotations + (model.draft.map { [$0] } ?? [])

            ZStack(alignment: .topLeading) {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: shown.width, height: shown.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)

                Canvas { context, _ in
                    context.withCGContext { cg in
                        cg.scaleBy(x: scale, y: scale)
                        AnnotationRenderer.draw(marks, in: cg, image: preview, imageSize: size)
                    }
                }
                .frame(width: shown.width, height: shown.height)
                .allowsHitTesting(false)

                Color.clear
                    .frame(width: shown.width, height: shown.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        model.dragChanged(from: imagePoint(value.startLocation, scale), to: imagePoint(value.location, scale))
                    }.onEnded { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        model.dragEnded(at: imagePoint(value.location, scale), wasTap: distance < 3)
                        if model.textAnchor != nil { textFocused = true }
                    })
                    .onHover { inside in
                        if inside { cursor.push() } else { NSCursor.pop() }
                    }

                if let anchor = model.textAnchor {
                    let fontSize = max(model.lineWidth * 6, 10) * scale
                    TextField("Type text", text: $model.textDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundStyle(Color(cgColor: model.color.cgColor))
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.yuzuAccent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .frame(width: max(shown.width - anchor.x * scale, 80), alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: anchor.x * scale - 4, y: anchor.y * scale - fontSize * 0.2)
                        .focused($textFocused)
                        .onSubmit { model.commitText() }
                        .onExitCommand { model.textAnchor = nil }
                }
            }
            .offset(x: origin.x, y: origin.y)
        }
    }

    private var cursor: NSCursor {
        model.tool == .text ? .iBeam : .crosshair
    }

    private func imagePoint(_ location: CGPoint, _ scale: CGFloat) -> CGPoint {
        CGPoint(x: location.x / scale, y: location.y / scale)
    }
}
