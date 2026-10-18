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
    /// Yuzu-geel voor het gemarkeerde segment.
    static let accent = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.13, alpha: 1)
    static let accentText = NSColor(srgbRed: 0.18, green: 0.15, blue: 0.02, alpha: 1)
}

/// Toont het radiale wiel in een niet-activerend paneel rond de cursor.
@MainActor
final class WheelController {
    var onDrop: ((WheelItem, [URL]) -> Void)?
    var playsSounds = true

    private var panel: NSPanel?
    private var wheelView: WheelView?
    private var pendingHide: DispatchWorkItem?
    private static let size = CGSize(width: 400, height: 400)

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(kind: WheelKind, items: [WheelItem], fileCount: Int) {
        pendingHide?.cancel()
        let panel = self.panel ?? makePanel()
        guard let view = wheelView else { return }
        view.items = items
        view.title = kind.displayName
        view.subtitle = fileCount == 1 ? "1 bestand" : "\(fileCount) bestanden"
        view.highlightedIndex = nil
        view.playsSounds = playsSounds

        if !panel.isVisible {
            panel.setFrame(frameAroundCursor(), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        view.needsDisplay = true
    }

    /// Verbergen met vertraging: de drop komt vaak net ná het loslaten van de muisknop binnen.
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
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let view = WheelView(frame: CGRect(origin: .zero, size: Self.size))
        view.onDrop = { [weak self] item, urls in
            self?.hide()
            // Laat de drag-sessie eerst afronden voordat we eventueel panelen openen.
            DispatchQueue.main.async { self?.onDrop?(item, urls) }
        }
        panel.contentView = view
        self.panel = panel
        self.wheelView = view
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

/// Tekent de segmenten en is zelf de drop-bestemming; het segment volgt uit de hoek t.o.v. het midden.
final class WheelView: NSView {
    var items: [WheelItem] = [] { didSet { needsDisplay = true } }
    var title = ""
    var subtitle = ""
    var playsSounds = true
    var highlightedIndex: Int? {
        didSet {
            guard highlightedIndex != oldValue else { return }
            needsDisplay = true
            if highlightedIndex != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                if playsSounds { Self.tick?.stop(); Self.tick?.play() }
            }
        }
    }
    var onDrop: ((WheelItem, [URL]) -> Void)?

    private let outerRadius: CGFloat = 170
    private let innerRadius: CGFloat = 64
    private let gapDegrees: CGFloat = 1.6

    private static let tick: NSSound? = {
        let sound = NSSound(named: "Tink")
        sound?.volume = 0.25
        return sound
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is niet ondersteund") }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var segmentDegrees: CGFloat { 360 / CGFloat(max(items.count, 1)) }

    func index(at point: CGPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= innerRadius, distance <= outerRadius + 24 else { return nil }
        let standard = atan2(dy, dx) * 180 / .pi
        var fromTop = (90 - standard).truncatingRemainder(dividingBy: 360)
        if fromTop < 0 { fromTop += 360 }
        return min(Int(fromTop / segmentDegrees), items.count - 1)
    }

    // MARK: - Tekenen

    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: CGRect(x: center.x - outerRadius, y: center.y - outerRadius,
                                               width: outerRadius * 2, height: outerRadius * 2))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.set()
        NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill()
        ring.fill()
        NSGraphicsContext.restoreGraphicsState()

        if items.isEmpty {
            drawCenter(primary: "Niets beschikbaar", secondary: "voor deze selectie")
            return
        }

        for (index, item) in items.enumerated() {
            let highlighted = index == highlightedIndex
            let path = segmentPath(index)
            (highlighted ? YuzuColors.accent : NSColor.windowBackgroundColor.withAlphaComponent(0.94)).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            drawLabel(item, index: index, highlighted: highlighted)
        }

        if let highlightedIndex, items.indices.contains(highlightedIndex) {
            drawCenter(primary: items[highlightedIndex].title, secondary: "loslaten om te starten")
        } else {
            drawCenter(primary: title, secondary: subtitle)
        }
    }

    private func segmentPath(_ index: Int) -> NSBezierPath {
        let start = 90 - CGFloat(index) * segmentDegrees - gapDegrees / 2
        let end = 90 - CGFloat(index + 1) * segmentDegrees + gapDegrees / 2
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: true)
        path.appendArc(withCenter: center, radius: innerRadius + 6, startAngle: end, endAngle: start, clockwise: false)
        path.close()
        return path
    }

    private func drawLabel(_ item: WheelItem, index: Int, highlighted: Bool) {
        let angle = (90 - (CGFloat(index) + 0.5) * segmentDegrees) * .pi / 180
        let radius = (outerRadius + innerRadius + 6) / 2
        let anchor = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        let color = highlighted ? YuzuColors.accentText : NSColor.labelColor

        let font = NSFont.systemFont(ofSize: item.symbolName == nil ? 15 : 11, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let text = NSAttributedString(string: item.title, attributes: attributes)
        let maxWidth: CGFloat = 84
        let textSize = text.boundingRect(with: CGSize(width: maxWidth, height: 40), options: [.usesLineFragmentOrigin]).size

        var textOrigin = CGPoint(x: anchor.x - maxWidth / 2, y: anchor.y - textSize.height / 2)
        if let symbolName = item.symbolName,
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: item.title)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium).applying(.init(paletteColors: [color]))) {
            let symbolSize = symbol.size
            let totalHeight = symbolSize.height + 4 + textSize.height
            let symbolRect = CGRect(x: anchor.x - symbolSize.width / 2, y: anchor.y + totalHeight / 2 - symbolSize.height,
                                    width: symbolSize.width, height: symbolSize.height)
            symbol.draw(in: symbolRect)
            textOrigin.y = anchor.y - totalHeight / 2
        }
        text.draw(with: CGRect(origin: textOrigin, size: CGSize(width: maxWidth, height: textSize.height)),
                  options: [.usesLineFragmentOrigin])
    }

    private func drawCenter(primary: String, secondary: String) {
        let circle = NSBezierPath(ovalIn: CGRect(x: center.x - innerRadius, y: center.y - innerRadius,
                                                 width: innerRadius * 2, height: innerRadius * 2))
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        circle.fill()
        NSColor.separatorColor.setStroke()
        circle.lineWidth = 0.5
        circle.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let primaryText = NSAttributedString(string: primary, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        let secondaryText = NSAttributedString(string: secondary, attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ])
        let width = innerRadius * 1.7
        let primaryHeight = primaryText.boundingRect(with: CGSize(width: width, height: 60), options: .usesLineFragmentOrigin).height
        let secondaryHeight = secondaryText.boundingRect(with: CGSize(width: width, height: 40), options: .usesLineFragmentOrigin).height
        let top = center.y + (primaryHeight + secondaryHeight + 2) / 2
        primaryText.draw(with: CGRect(x: center.x - width / 2, y: top - primaryHeight, width: width, height: primaryHeight),
                         options: .usesLineFragmentOrigin)
        secondaryText.draw(with: CGRect(x: center.x - width / 2, y: top - primaryHeight - 2 - secondaryHeight,
                                        width: width, height: secondaryHeight), options: .usesLineFragmentOrigin)
    }

    // MARK: - Drop-bestemming

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
