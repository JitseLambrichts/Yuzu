import AppKit
import YuzuCore

struct WheelItem {
    enum Payload {
        case convert(ConversionFormat)
        case tool(FileTool)
        case action(FileAction)
    }

    let title: String
    let symbolName: String?
    let payload: Payload

    static func items(for kind: WheelKind, urls: [URL]) -> [WheelItem] {
        switch kind {
        case .convert:
            return ConversionCatalog.targets(for: urls).map { WheelItem(title: $0.displayName, symbolName: nil, payload: .convert($0)) }
        case .tools:
            return ConversionCatalog.tools(for: urls).map { WheelItem(title: $0.displayName, symbolName: $0.symbolName, payload: .tool($0)) }
        case .actions:
            return FileAction.allCases.map { WheelItem(title: $0.displayName, symbolName: $0.symbolName, payload: .action($0)) }
        }
    }
}

enum YuzuColors {
    /// Yuzu yellow for the highlighted item.
    static let accent = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.13, alpha: 1)
    /// Deeper, warmer end of the accent gradient.
    static let accentDeep = NSColor(srgbRed: 0.96, green: 0.62, blue: 0.10, alpha: 1)
    static let accentText = NSColor(srgbRed: 0.18, green: 0.15, blue: 0.02, alpha: 1)
}

/// Light or dark glass for the wheel, chosen in the settings.
enum WheelStyle: String, CaseIterable, Sendable {
    case light, dark, system

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "Match System"
        }
    }

    /// Whether the wheel should be dark right now.
    @MainActor var isDark: Bool {
        switch self {
        case .light: return false
        case .dark: return true
        case .system: return NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
}

/// Shows the radial wheel in a non-activating panel around the cursor.
@MainActor
final class WheelController {
    var onDrop: ((WheelItem, [URL]) -> Void)?
    var playsSounds = true
    var style: WheelStyle = .light

    private var panel: NSPanel?
    private var wheelView: WheelView?
    /// Liquid Glass on macOS 26 and later, frosted glass before that.
    private var glass: NSView?
    private var pendingHide: DispatchWorkItem?
    private static let size = CGSize(width: WheelView.preferredSize, height: WheelView.preferredSize)

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(kind: WheelKind, items: [WheelItem], fileCount: Int) {
        pendingHide?.cancel()
        let panel = self.panel ?? makePanel()
        guard let view = wheelView else { return }
        view.items = items
        view.title = kind.displayName
        view.subtitle = fileCount == 1 ? "1 file" : "\(fileCount) files"
        view.highlightedIndex = nil
        view.playsSounds = playsSounds

        if !panel.isVisible {
            applyStyle()
            panel.setFrame(frameAroundCursor(), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            view.animateIn()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
        view.needsDisplay = true
    }

    /// Development aid for `--demo-wheel`: highlight an item without dragging.
    func highlight(_ index: Int?) {
        wheelView?.highlightedIndex = index
    }

    /// Hides with a delay: the drop often arrives just after the mouse button is released.
    func scheduleHide(after delay: TimeInterval = 0.4) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        pendingHide?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func applyStyle() {
        let dark = style.isDark
        glass?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if #available(macOS 26.0, *), let liquid = glass as? NSGlassEffectView {
            liquid.tintColor = dark ? NSColor(white: 0.05, alpha: 0.35) : NSColor(white: 1, alpha: 0.22)
            wheelView?.palette = dark ? WheelPalette.dark.onLiquidGlass : WheelPalette.light.onLiquidGlass
            wheelView?.isOnLiquidGlass = true
        } else if let frosted = glass as? NSVisualEffectView {
            frosted.material = dark ? .hudWindow : .popover
            wheelView?.palette = dark ? .dark : .light
        }
    }

    /// The glass behind the disc: Liquid Glass when available, otherwise a circular frosted view.
    private static func makeGlass(frame: CGRect) -> NSView {
        if #available(macOS 26.0, *) {
            let radius = WheelView.discRadius
            let glass = NSGlassEffectView(frame: CGRect(x: frame.midX - radius, y: frame.midY - radius,
                                                        width: radius * 2, height: radius * 2))
            glass.style = .clear
            glass.cornerRadius = radius
            return glass
        }
        let glass = NSVisualEffectView(frame: frame)
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = WheelView.discMask(size: frame.size)
        return glass
    }

    private func makePanel() -> NSPanel {
        let frame = CGRect(origin: .zero, size: Self.size)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        // Glass behind the disc; the wheel view draws its tint, rim and segments on top.
        let container = NSView(frame: frame)
        let glass = Self.makeGlass(frame: frame)
        container.addSubview(glass)

        let view = WheelView(frame: frame)
        view.onDrop = { [weak self] item, urls in
            self?.hide()
            // Let the drag session finish before we open any panels.
            DispatchQueue.main.async { self?.onDrop?(item, urls) }
        }
        container.addSubview(view)
        panel.contentView = container
        self.panel = panel
        self.wheelView = view
        self.glass = glass
        return panel
    }

    private func frameAroundCursor() -> CGRect {
        let mouse = NSEvent.mouseLocation
        var frame = CGRect(x: mouse.x - Self.size.width / 2, y: mouse.y - Self.size.height / 2,
                           width: Self.size.width, height: Self.size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        return frame
    }
}

/// Colors for the light and dark glass wheel.
struct WheelPalette {
    var discTop: NSColor
    var discBottom: NSColor
    var discShadow: NSColor
    var discEdge: NSColor
    var rimHighlight: NSColor
    var segmentTop: NSColor
    var segmentBottom: NSColor
    var segmentEdge: NSColor
    var segmentSheen: NSColor
    var symbol: NSColor
    var label: NSColor
    var knobLight: NSColor
    var knobMid: NSColor
    var knobDark: NSColor
    var knobEdge: NSColor
    var knobRing: NSColor
    var knobShadow: NSColor
    var knobTitle: NSColor
    var knobSubtitle: NSColor

    static let light = WheelPalette(
        discTop: NSColor(white: 1, alpha: 0.80),
        discBottom: NSColor(srgbRed: 0.93, green: 0.92, blue: 0.93, alpha: 0.80),
        discShadow: NSColor.black.withAlphaComponent(0.22),
        discEdge: NSColor.black.withAlphaComponent(0.08),
        rimHighlight: NSColor(white: 1, alpha: 0.95),
        segmentTop: NSColor(white: 1, alpha: 0.72),
        segmentBottom: NSColor(white: 1, alpha: 0.42),
        segmentEdge: NSColor.black.withAlphaComponent(0.07),
        segmentSheen: NSColor(white: 1, alpha: 0.9),
        symbol: NSColor(white: 0.12, alpha: 0.68),
        label: NSColor(white: 0.1, alpha: 0.82),
        knobLight: NSColor(white: 1, alpha: 1),
        knobMid: NSColor(srgbRed: 0.96, green: 0.95, blue: 0.95, alpha: 1),
        knobDark: NSColor(srgbRed: 0.86, green: 0.85, blue: 0.86, alpha: 1),
        knobEdge: NSColor.black.withAlphaComponent(0.08),
        knobRing: NSColor.black.withAlphaComponent(0.07),
        knobShadow: NSColor.black.withAlphaComponent(0.18),
        knobTitle: NSColor(white: 0.08, alpha: 0.92),
        knobSubtitle: NSColor(white: 0.1, alpha: 0.5)
    )

    static let dark = WheelPalette(
        discTop: NSColor(srgbRed: 0.24, green: 0.21, blue: 0.21, alpha: 0.86),
        discBottom: NSColor(srgbRed: 0.15, green: 0.13, blue: 0.14, alpha: 0.9),
        discShadow: NSColor.black.withAlphaComponent(0.45),
        discEdge: NSColor.black.withAlphaComponent(0.3),
        rimHighlight: NSColor(white: 1, alpha: 0.3),
        segmentTop: NSColor(white: 1, alpha: 0.085),
        segmentBottom: NSColor(white: 1, alpha: 0.035),
        segmentEdge: NSColor(white: 1, alpha: 0.1),
        segmentSheen: NSColor(white: 1, alpha: 0.12),
        symbol: NSColor(white: 1, alpha: 0.72),
        label: NSColor(white: 1, alpha: 0.86),
        knobLight: NSColor(srgbRed: 0.33, green: 0.29, blue: 0.29, alpha: 1),
        knobMid: NSColor(srgbRed: 0.16, green: 0.13, blue: 0.14, alpha: 1),
        knobDark: NSColor(srgbRed: 0.10, green: 0.08, blue: 0.09, alpha: 1),
        knobEdge: NSColor(white: 1, alpha: 0.22),
        knobRing: NSColor(white: 1, alpha: 0.16),
        knobShadow: NSColor.black.withAlphaComponent(0.4),
        knobTitle: NSColor(white: 1, alpha: 0.94),
        knobSubtitle: NSColor(white: 1, alpha: 0.5)
    )
}

extension WheelPalette {
    /// Lighter, more see-through version for on top of Liquid Glass: the glass itself does the frosting.
    var onLiquidGlass: WheelPalette {
        var palette = self
        let dark = discTop.usingColorSpace(.sRGB).map { $0.brightnessComponent < 0.5 } ?? false
        if dark {
            palette.discTop = NSColor(srgbRed: 0.2, green: 0.18, blue: 0.18, alpha: 0.28)
            palette.discBottom = NSColor(srgbRed: 0.1, green: 0.09, blue: 0.1, alpha: 0.38)
            palette.segmentTop = NSColor(white: 1, alpha: 0.1)
            palette.segmentBottom = NSColor(white: 1, alpha: 0.04)
            palette.segmentEdge = NSColor(white: 1, alpha: 0.16)
            palette.segmentSheen = NSColor(white: 1, alpha: 0.18)
        } else {
            palette.discTop = NSColor(white: 1, alpha: 0.16)
            palette.discBottom = NSColor(white: 1, alpha: 0.06)
            palette.discEdge = NSColor(white: 1, alpha: 0.35)
            palette.segmentTop = NSColor(white: 1, alpha: 0.46)
            palette.segmentBottom = NSColor(white: 1, alpha: 0.24)
            palette.segmentEdge = NSColor(white: 1, alpha: 0.55)
            palette.segmentSheen = NSColor(white: 1, alpha: 0.75)
            palette.knobMid = NSColor(srgbRed: 0.97, green: 0.96, blue: 0.96, alpha: 0.92)
            palette.knobDark = NSColor(srgbRed: 0.88, green: 0.87, blue: 0.88, alpha: 0.92)
        }
        palette.discShadow = NSColor.black.withAlphaComponent(dark ? 0.35 : 0.16)
        return palette
    }
}

/// A glass disc split into rounded segments around a central knob. It is the drop destination itself;
/// the segment under the cursor follows from the angle to the center.
final class WheelView: NSView {
    static let preferredSize: CGFloat = 400
    static let discRadius: CGFloat = 166

    var items: [WheelItem] = [] {
        didSet {
            emphasis = Array(repeating: 0, count: items.count)
            needsDisplay = true
        }
    }
    var title = ""
    var subtitle = ""
    var playsSounds = true
    var palette = WheelPalette.light { didSet { needsDisplay = true } }
    /// When the disc sits on Liquid Glass, the shadow is drawn only outside the disc so the glass stays clear.
    var isOnLiquidGlass = false { didSet { needsDisplay = true } }
    var highlightedIndex: Int? {
        didSet {
            guard highlightedIndex != oldValue else { return }
            startAnimating()
            if highlightedIndex != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                if playsSounds { Self.tick?.stop(); Self.tick?.play() }
            }
        }
    }
    var onDrop: ((WheelItem, [URL]) -> Void)?

    private let knobRadius: CGFloat = 47
    private var innerRadius: CGFloat { knobRadius + 11 }
    private var outerRadius: CGFloat { Self.discRadius - 7 }
    /// Space between segments and the rounding of their corners, in points.
    private let gap: CGFloat = 5.5
    private let cornerRadius: CGFloat = 11
    /// Per item 0...1: how highlighted it currently is (animated towards the target).
    private var emphasis: [CGFloat] = []
    /// 0...1 while the wheel opens.
    private var openProgress: CGFloat = 1
    private var timer: Timer?

    private static let tick: NSSound? = {
        let sound = NSSound(named: "Tink")
        sound?.volume = 0.25
        return sound
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Circle mask for the glass behind the disc.
    static func discMask(size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.midX - discRadius, y: rect.midY - discRadius,
                                        width: discRadius * 2, height: discRadius * 2)).fill()
            return true
        }
    }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var stepDegrees: CGFloat { 360 / CGFloat(max(items.count, 1)) }

    func index(at point: CGPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= knobRadius, distance <= Self.discRadius + 24 else { return nil }
        let standard = atan2(dy, dx) * 180 / .pi
        var fromTop = (90 - standard).truncatingRemainder(dividingBy: 360)
        if fromTop < 0 { fromTop += 360 }
        return min(Int(fromTop / stepDegrees), items.count - 1)
    }

    // MARK: - Animation

    /// Opens with a short scale-up, like a popover.
    func animateIn() {
        openProgress = 0
        startAnimating()
    }

    private func startAnimating() {
        needsDisplay = true
        guard timer == nil else { return }
        // `.common`, so the animation keeps running inside the drag session's tracking loop.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        var settled = true
        for index in emphasis.indices {
            let target: CGFloat = index == highlightedIndex ? 1 : 0
            emphasis[index] += (target - emphasis[index]) * 0.3
            if abs(target - emphasis[index]) < 0.01 { emphasis[index] = target } else { settled = false }
        }
        openProgress += (1 - openProgress) * 0.25
        if 1 - openProgress < 0.005 { openProgress = 1 } else { settled = false }
        needsDisplay = true
        if settled {
            timer?.invalidate()
            timer = nil
        }
    }

    /// For the previews: jump straight to the end state.
    func settleImmediately() {
        timer?.invalidate()
        timer = nil
        openProgress = 1
        emphasis = items.indices.map { $0 == highlightedIndex ? 1 : 0 }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let eased = 1 - pow(1 - openProgress, 3)
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: 0.9 + 0.1 * eased, y: 0.9 + 0.1 * eased)
        context.translateBy(x: -center.x, y: -center.y)

        drawDisc(context)
        if items.isEmpty {
            drawKnob(primary: "Nothing available", secondary: "for this selection")
        } else {
            // The highlighted segment last, so its glow lies on top of its neighbours.
            let order = items.indices.sorted { emphasisOf($0) < emphasisOf($1) }
            for index in order { drawSegment(index, context) }
            if let highlightedIndex, items.indices.contains(highlightedIndex) {
                drawKnob(primary: items[highlightedIndex].title, secondary: "Release to start")
            } else {
                drawKnob(primary: title, secondary: subtitle)
            }
        }
        context.restoreGState()
    }

    private func emphasisOf(_ index: Int) -> CGFloat {
        emphasis.indices.contains(index) ? emphasis[index] : 0
    }

    private func circle(_ point: CGPoint, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    private func drawDisc(_ context: CGContext) {
        let disc = circle(center, Self.discRadius)

        // Soft, deep shadow so the disc floats above whatever is underneath.
        NSGraphicsContext.saveGraphicsState()
        if isOnLiquidGlass {
            // Only outside the disc: a shadow underneath would darken the see-through glass.
            let outside = NSBezierPath(rect: bounds)
            outside.append(disc)
            outside.windingRule = .evenOdd
            outside.setClip()
        }
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 27
        shadow.shadowOffset = CGSize(width: 0, height: -11)
        shadow.shadowColor = palette.discShadow
        shadow.set()
        palette.discBottom.setFill()
        disc.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colors: [palette.discTop, palette.discBottom])?.draw(in: disc, angle: -90)

        palette.discEdge.setStroke()
        disc.lineWidth = 0.5
        disc.stroke()

        // Glass rim: a bright hairline at the top that fades out towards the bottom.
        context.saveGState()
        let rim = circle(center, Self.discRadius - 1).cgPath
            .copy(strokingWithWidth: 1.5, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        context.addPath(rim)
        context.clip()
        NSGradient(colors: [palette.rimHighlight, palette.rimHighlight.withAlphaComponent(0),
                            palette.rimHighlight.withAlphaComponent(0.25)],
                   atLocations: [0, 0.6, 1], colorSpace: .sRGB)?
            .draw(in: disc.bounds, angle: -90)
        context.restoreGState()
    }

    /// An annular sector with an even gap to its neighbours and rounded corners.
    ///
    /// Each corner is a fillet circle of `cornerRadius` that touches both the arc and the edge; the edges are the
    /// sector's radial lines shifted `gap / 2` inwards, so the gap between neighbours is equally wide everywhere.
    private func segmentPath(_ index: Int) -> CGPath {
        if items.count == 1 {
            return circle(center, (outerRadius + innerRadius) / 2).cgPath
                .copy(strokingWithWidth: outerRadius - innerRadius, lineCap: .butt, lineJoin: .round, miterLimit: 10)
        }
        let r = cornerRadius
        let d = gap / 2 + r
        let start = (90 - CGFloat(index) * stepDegrees) * .pi / 180
        let end = (90 - CGFloat(index + 1) * stepDegrees) * .pi / 180
        // Normals pointing into the segment for the start edge (clockwise side) and the end edge.
        let startNormal = CGPoint(x: sin(start), y: -cos(start))
        let endNormal = CGPoint(x: -sin(end), y: cos(end))
        let outerSpread = asin(min(d / (outerRadius - r), 1))
        let innerSpread = asin(min(d / (innerRadius + r), 1))

        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        func degrees(_ from: CGPoint, _ to: CGPoint) -> CGFloat { atan2(to.y - from.y, to.x - from.x) * 180 / .pi }
        func toward(_ center: CGPoint, _ normal: CGPoint) -> CGPoint { CGPoint(x: center.x - normal.x * r, y: center.y - normal.y * r) }

        let filletA = point(outerRadius - r, start - outerSpread)
        let filletB = point(outerRadius - r, end + outerSpread)
        let filletC = point(innerRadius + r, end + innerSpread)
        let filletD = point(innerRadius + r, start - innerSpread)
        let angleA = start - outerSpread, angleB = end + outerSpread
        let angleC = end + innerSpread, angleD = start - innerSpread

        let path = NSBezierPath()
        path.move(to: toward(filletA, startNormal))
        path.appendArc(withCenter: filletA, radius: r, startAngle: degrees(filletA, toward(filletA, startNormal)),
                       endAngle: angleA * 180 / .pi, clockwise: true)
        path.appendArc(withCenter: center, radius: outerRadius, startAngle: angleA * 180 / .pi, endAngle: angleB * 180 / .pi,
                       clockwise: true)
        path.appendArc(withCenter: filletB, radius: r, startAngle: angleB * 180 / .pi,
                       endAngle: degrees(filletB, toward(filletB, endNormal)), clockwise: true)
        path.appendArc(withCenter: filletC, radius: r, startAngle: degrees(filletC, toward(filletC, endNormal)),
                       endAngle: angleC * 180 / .pi + 180, clockwise: true)
        path.appendArc(withCenter: center, radius: innerRadius, startAngle: angleC * 180 / .pi, endAngle: angleD * 180 / .pi,
                       clockwise: false)
        path.appendArc(withCenter: filletD, radius: r, startAngle: angleD * 180 / .pi + 180,
                       endAngle: degrees(filletD, toward(filletD, startNormal)), clockwise: true)
        path.close()
        return path.cgPath
    }

    private func drawSegment(_ index: Int, _ context: CGContext) {
        let item = items[index]
        let amount = emphasisOf(index)
        let middle = (90 - (CGFloat(index) + 0.5) * stepDegrees) * .pi / 180

        context.saveGState()
        // The highlighted segment pops out a little.
        context.translateBy(x: cos(middle) * 4 * amount, y: sin(middle) * 4 * amount)
        let shape = segmentPath(index)
        let box = shape.boundingBox

        if amount > 0.01 {
            context.saveGState()
            context.setShadow(offset: .zero, blur: 20, color: YuzuColors.accent.withAlphaComponent(0.6 * amount).cgColor)
            context.addPath(shape)
            context.setFillColor(YuzuColors.accent.withAlphaComponent(amount).cgColor)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(shape)
        context.clip()
        NSGradient(colors: [palette.segmentTop, palette.segmentBottom])?.draw(in: box, angle: -90)
        if amount > 0.01 {
            NSGradient(colors: [YuzuColors.accent.withAlphaComponent(amount), YuzuColors.accentDeep.withAlphaComponent(amount)])?
                .draw(in: box, angle: -90)
        }
        // A bright sheen just inside the edge, for the glass look.
        let sheen = amount > 0.5 ? NSColor(white: 1, alpha: 0.45) : palette.segmentSheen
        context.addPath(shape)
        context.setStrokeColor(sheen.withAlphaComponent(sheen.alphaComponent * 0.6).cgColor)
        context.setLineWidth(2)
        context.strokePath()
        context.restoreGState()

        context.addPath(shape)
        context.setStrokeColor(palette.segmentEdge.withAlphaComponent(palette.segmentEdge.alphaComponent * (1 - amount)).cgColor)
        context.setLineWidth(1)
        context.strokePath()

        let anchorRadius = (innerRadius + outerRadius) / 2
        let anchor = CGPoint(x: center.x + cos(middle) * anchorRadius, y: center.y + sin(middle) * anchorRadius)
        let chord = 2 * anchorRadius * sin(min(stepDegrees, 180) * .pi / 360) - gap - 12
        drawContents(of: item, at: anchor, width: min(max(chord, 52), 88), amount: amount)
        context.restoreGState()
    }

    private func drawContents(of item: WheelItem, at point: CGPoint, width: CGFloat, amount: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let labelColor = blend(palette.label, YuzuColors.accentText, amount)

        guard let symbolName = item.symbolName,
              let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: item.title)?
                .withSymbolConfiguration(.init(pointSize: 16.5, weight: .medium)
                    .applying(.init(paletteColors: [blend(palette.symbol, YuzuColors.accentText, amount)]))) else {
            // Formats: just the name, a little larger.
            let text = NSAttributedString(string: item.title, attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold).rounded,
                .foregroundColor: labelColor, .paragraphStyle: paragraph, .kern: 0.4,
            ])
            let height = text.boundingRect(with: CGSize(width: width, height: 60), options: .usesLineFragmentOrigin).height
            text.draw(with: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
                      options: .usesLineFragmentOrigin)
            return
        }

        let label = NSAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: labelColor, .paragraphStyle: paragraph,
        ])
        let labelHeight = label.boundingRect(with: CGSize(width: width, height: 40), options: .usesLineFragmentOrigin).height
        let size = symbol.size
        let total = size.height + 4 + labelHeight
        symbol.draw(in: CGRect(x: point.x - size.width / 2, y: point.y + total / 2 - size.height, width: size.width, height: size.height))
        label.draw(with: CGRect(x: point.x - width / 2, y: point.y - total / 2, width: width, height: labelHeight),
                   options: .usesLineFragmentOrigin)
    }

    /// The central knob: a soft sphere with a fine ring around it, like a dial you can press.
    private func drawKnob(primary: String, secondary: String) {
        let ring = circle(center, knobRadius + 6)
        palette.knobRing.setStroke()
        ring.lineWidth = 1.25
        ring.stroke()

        let knob = circle(center, knobRadius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = CGSize(width: 0, height: -6)
        shadow.shadowColor = palette.knobShadow
        shadow.set()
        palette.knobMid.setFill()
        knob.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Sphere shading: light from the top left.
        NSGradient(colors: [palette.knobLight, palette.knobMid, palette.knobDark], atLocations: [0, 0.55, 1], colorSpace: .sRGB)?
            .draw(in: knob, relativeCenterPosition: NSPoint(x: -0.35, y: 0.45))
        palette.knobEdge.setStroke()
        let edge = circle(center, knobRadius - 0.5)
        edge.lineWidth = 1
        edge.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let width = knobRadius * 1.6
        let primaryText = NSAttributedString(string: primary, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: palette.knobTitle, .paragraphStyle: paragraph,
        ])
        let secondaryText = NSAttributedString(string: secondary, attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium), .foregroundColor: palette.knobSubtitle, .paragraphStyle: paragraph,
        ])
        let primaryHeight = primaryText.boundingRect(with: CGSize(width: width, height: 40), options: .usesLineFragmentOrigin).height
        let secondaryHeight = secondaryText.boundingRect(with: CGSize(width: width, height: 30), options: .usesLineFragmentOrigin).height
        let top = center.y + (primaryHeight + 2 + secondaryHeight) / 2
        primaryText.draw(with: CGRect(x: center.x - width / 2, y: top - primaryHeight, width: width, height: primaryHeight),
                         options: .usesLineFragmentOrigin)
        secondaryText.draw(with: CGRect(x: center.x - width / 2, y: top - primaryHeight - 2 - secondaryHeight,
                                        width: width, height: secondaryHeight), options: .usesLineFragmentOrigin)
    }

    private func blend(_ from: NSColor, _ to: NSColor, _ amount: CGFloat) -> NSColor {
        from.usingColorSpace(.sRGB)?.blended(withFraction: amount, of: to.usingColorSpace(.sRGB) ?? to) ?? from
    }

    // MARK: - Drop destination

    private func updateHighlight(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlightedIndex = index(at: convert(sender.draggingLocation, from: nil))
        return highlightedIndex == nil ? [] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateHighlight(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateHighlight(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlightedIndex = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { highlightedIndex != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = highlightedIndex, items.indices.contains(index) else { return false }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let item = items[index]
        highlightedIndex = nil
        onDrop?(item, urls)
        return true
    }
}

private extension NSFont {
    /// The SF Pro Rounded variant of this font, when available.
    var rounded: NSFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
