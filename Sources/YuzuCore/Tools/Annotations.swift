import CoreGraphics
import CoreText
import Foundation

/// One mark on an image. All coordinates are image pixels with the origin at the top left.
public struct Annotation: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case pen([CGPoint])
        case highlighter([CGPoint])
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case text(String, at: CGPoint)
        /// A numbered callout: a filled circle with a number in it.
        case step(Int, at: CGPoint)
        /// A circular loupe that shows the image underneath at twice the size.
        case magnifier(center: CGPoint, radius: CGFloat)
    }

    public let id: UUID
    public var kind: Kind
    public var color: RGBAColor
    /// Stroke width in image pixels; text and callouts scale with it too.
    public var lineWidth: CGFloat

    public init(id: UUID = UUID(), kind: Kind, color: RGBAColor, lineWidth: CGFloat) {
        self.id = id
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
    }

    public var fontSize: CGFloat { max(lineWidth * 6, 10) }

    /// The same annotation for an image that is `factor` times as large.
    public func scaled(by factor: CGFloat) -> Annotation {
        func p(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * factor, y: point.y * factor) }
        func r(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX * factor, y: rect.minY * factor, width: rect.width * factor, height: rect.height * factor) }
        var copy = self
        copy.lineWidth = lineWidth * factor
        switch kind {
        case .pen(let points): copy.kind = .pen(points.map(p))
        case .highlighter(let points): copy.kind = .highlighter(points.map(p))
        case .arrow(let from, let to): copy.kind = .arrow(from: p(from), to: p(to))
        case .rectangle(let rect): copy.kind = .rectangle(r(rect))
        case .ellipse(let rect): copy.kind = .ellipse(r(rect))
        case .text(let string, let point): copy.kind = .text(string, at: p(point))
        case .step(let number, let point): copy.kind = .step(number, at: p(point))
        case .magnifier(let center, let radius): copy.kind = .magnifier(center: p(center), radius: radius * factor)
        }
        return copy
    }
    public var stepRadius: CGFloat { max(lineWidth * 3.5, 8) }
}

public struct AnnotateOptions: Sendable, Equatable {
    public var annotations: [Annotation]
    /// Pixel size of the image the annotations were made on.
    public var referenceSize: CGSize

    public init(annotations: [Annotation], referenceSize: CGSize) {
        self.annotations = annotations
        self.referenceSize = referenceSize
    }
}

/// Draws annotations with CoreGraphics. The same code draws the live preview in the panel and the final file.
public enum AnnotationRenderer {
    /// Draws into a context whose coordinate system has its origin at the top left and uses image pixels as units.
    /// `image` is only needed for the magnifier; it is drawn over `imageSize`, so a scaled-down preview image works too.
    public static func draw(_ annotations: [Annotation], in context: CGContext, image: CGImage?, imageSize: CGSize) {
        for annotation in annotations {
            context.saveGState()
            draw(annotation, in: context, image: image, imageSize: imageSize)
            context.restoreGState()
        }
    }

    /// The whole image with its annotations burnt in.
    public static func render(_ image: CGImage, annotations: [Annotation]) throws -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: (image.hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else {
            throw YuzuError.writeFailed("image")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(annotations, in: context, image: image, imageSize: CGSize(width: width, height: height))
        guard let result = context.makeImage() else { throw YuzuError.writeFailed("image") }
        return result
    }

    private static func draw(_ annotation: Annotation, in context: CGContext, image: CGImage?, imageSize: CGSize) {
        let color = annotation.color.cgColor
        let width = annotation.lineWidth
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(width)

        switch annotation.kind {
        case .pen(let points):
            context.addPath(smoothPath(points))
            context.strokePath()
        case .highlighter(let points):
            context.setBlendMode(.multiply)
            context.setStrokeColor(annotation.color.withAlpha(0.4).cgColor)
            context.setLineWidth(width * 4)
            context.setLineCap(.square)
            context.addPath(smoothPath(points))
            context.strokePath()
        case .arrow(let from, let to):
            drawArrow(from: from, to: to, width: width, in: context)
        case .rectangle(let rect):
            let radius = min(width * 1.5, min(rect.width, rect.height) / 2)
            context.addPath(CGPath(roundedRect: rect.standardized, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        case .ellipse(let rect):
            context.strokeEllipse(in: rect.standardized)
        case .text(let string, let point):
            drawText(string, at: point, size: annotation.fontSize, color: annotation.color, in: context)
        case .step(let number, let point):
            let radius = annotation.stepRadius
            context.setShadow(offset: CGSize(width: 0, height: radius * 0.12), blur: radius * 0.4, color: CGColor(gray: 0, alpha: 0.35))
            context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(max(radius * 0.12, 1))
            context.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            let label = contrastingTextColor(for: annotation.color)
            drawText("\(number)", centeredAt: point, size: radius * 1.15, color: label, in: context)
        case .magnifier(let center, let radius):
            drawMagnifier(center: center, radius: max(radius, 4), border: width, color: annotation.color, image: image,
                          imageSize: imageSize, in: context)
        }
    }

    /// Catmull–Rom smoothing so freehand lines don't look jagged.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
            return path
        }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)], p1 = points[index], p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    static func drawArrow(from: CGPoint, to: CGPoint, width: CGFloat, in context: CGContext) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let length = hypot(to.x - from.x, to.y - from.y)
        let head = min(width * 4.5, length * 0.6)
        // Stop the shaft inside the head so the round cap doesn't poke through the tip.
        let shaftEnd = CGPoint(x: to.x - cos(angle) * head * 0.6, y: to.y - sin(angle) * head * 0.6)
        context.move(to: from)
        context.addLine(to: shaftEnd)
        context.strokePath()
        let spread: CGFloat = .pi / 7
        let left = CGPoint(x: to.x - cos(angle - spread) * head, y: to.y - sin(angle - spread) * head)
        let right = CGPoint(x: to.x - cos(angle + spread) * head, y: to.y - sin(angle + spread) * head)
        context.move(to: to)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.setLineWidth(width * 0.6)
        context.drawPath(using: .fillStroke)
    }

    static func font(size: CGFloat) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let bold = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
        return bold
    }

    static func line(_ string: String, size: CGFloat, color: RGBAColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// Text with its top-left corner at `point`; several lines are stacked.
    static func drawText(_ string: String, at point: CGPoint, size: CGFloat, color: RGBAColor, in context: CGContext) {
        var baseline = point.y + size
        // A soft dark halo keeps light text readable on light photos and vice versa.
        context.setShadow(offset: .zero, blur: size * 0.18, color: CGColor(gray: 0, alpha: 0.45))
        for text in string.components(separatedBy: "\n") {
            let ctLine = line(text, size: size, color: color)
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: point.x, y: baseline)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
            baseline += size * 1.2
        }
    }

    static func drawText(_ string: String, centeredAt point: CGPoint, size: CGFloat, color: RGBAColor, in context: CGContext) {
        let ctLine = line(string, size: size, color: color)
        let bounds = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: point.x - bounds.midX, y: point.y + bounds.midY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }

    static func drawMagnifier(center: CGPoint, radius: CGFloat, border: CGFloat, color: RGBAColor, image: CGImage?,
                              imageSize: CGSize, in context: CGContext) {
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: radius * 0.06), blur: radius * 0.25, color: CGColor(gray: 0, alpha: 0.4))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: circle)
        context.restoreGState()
        if let image {
            context.saveGState()
            context.addEllipse(in: circle)
            context.clip()
            // Zoom 2× around the center; the image is drawn upright in this top-left coordinate system.
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: 2, y: 2)
            context.translateBy(x: -center.x, y: -center.y)
            context.translateBy(x: 0, y: imageSize.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: imageSize))
            context.restoreGState()
        }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(border, 2))
        context.strokeEllipse(in: circle)
    }

    /// White on dark colors, near-black on light ones.
    static func contrastingTextColor(for color: RGBAColor) -> RGBAColor {
        let luminance = 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
        return luminance > 0.65 ? RGBAColor(0.1, 0.1, 0.1) : .white
    }
}
