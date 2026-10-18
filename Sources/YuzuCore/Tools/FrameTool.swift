import CoreGraphics
import Foundation
import ImageIO

/// A color in sRGB, independent of AppKit so the core stays testable.
public struct RGBAColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From a hex value such as `0xFF8A3D`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
    }

    public func withAlpha(_ alpha: Double) -> RGBAColor { RGBAColor(red, green, blue, alpha) }

    public static let white = RGBAColor(1, 1, 1)
    public static let black = RGBAColor(0, 0, 0)
}

// MARK: - Add background

/// What fills the area around the image.
public enum FrameBackground: Sendable, Hashable {
    case solid(RGBAColor)
    /// Soft blobs of color that blend into each other, like a mesh gradient.
    case mesh([RGBAColor])
    /// An image file, scaled to fill the canvas.
    case image(URL)

    /// Ready-made mesh gradients for the swatch row.
    public static let meshPresets: [FrameBackground] = [
        .mesh([RGBAColor(hex: 0xFF5E3A), RGBAColor(hex: 0xFFB347), RGBAColor(hex: 0xFF8FB1), RGBAColor(hex: 0x9B6BFF)]),
        .mesh([RGBAColor(hex: 0xFFFFFF), RGBAColor(hex: 0x7FB2FF), RGBAColor(hex: 0xFFD3A5), RGBAColor(hex: 0xFF9EC7)]),
        .mesh([RGBAColor(hex: 0xFFF27A), RGBAColor(hex: 0x7CF2C2), RGBAColor(hex: 0xFF8DC7), RGBAColor(hex: 0xA58BFF)]),
        .mesh([RGBAColor(hex: 0xFDF6F0), RGBAColor(hex: 0xF7C8D8), RGBAColor(hex: 0xFFFFFF), RGBAColor(hex: 0xE3D5FF)]),
        .mesh([RGBAColor(hex: 0xE9B8E8), RGBAColor(hex: 0xFFD1C1), RGBAColor(hex: 0xB9A5FF), RGBAColor(hex: 0xFFE9F3)]),
        .mesh([RGBAColor(hex: 0x1E2A44), RGBAColor(hex: 0xFF4F6D), RGBAColor(hex: 0x2BD3A6), RGBAColor(hex: 0xFFC145)]),
        .mesh([RGBAColor(hex: 0x6FB7FF), RGBAColor(hex: 0xC9F0FF), RGBAColor(hex: 0x4D6BFF), RGBAColor(hex: 0x9EE6FF)]),
        .mesh([RGBAColor(hex: 0x00C2D1), RGBAColor(hex: 0x9CF6E5), RGBAColor(hex: 0x1F8EF1), RGBAColor(hex: 0x7EE8FA)]),
        .mesh([RGBAColor(hex: 0xF8E8FF), RGBAColor(hex: 0xFFD6EC), RGBAColor(hex: 0xE0E7FF), RGBAColor(hex: 0xFFFFFF)]),
    ]

    /// Plain colors for the second swatch row.
    public static let solidPresets: [FrameBackground] = [
        0xF7F7F5, 0xF4C542, 0x9BCB3C, 0x3FA66B, 0x219E8E, 0x4FC8DD, 0x3E63DD, 0x22324D, 0x7B4FD0,
    ].map { .solid(RGBAColor(hex: $0)) }
}

/// Aspect ratio of the canvas around the image.
public enum FrameRatio: String, CaseIterable, Sendable {
    case auto, square, widescreen, portrait, story

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .square: return "1:1"
        case .widescreen: return "16:9"
        case .portrait: return "4:5"
        case .story: return "9:16"
        }
    }

    /// Width divided by height, or `nil` when the canvas just follows the image plus padding.
    public var value: Double? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .widescreen: return 16.0 / 9.0
        case .portrait: return 4.0 / 5.0
        case .story: return 9.0 / 16.0
        }
    }
}

public struct FrameOptions: Sendable, Hashable {
    public var background: FrameBackground
    /// Padding, corner radius and shadow are fractions of the image's shorter side, so a batch of images
    /// of different sizes all get the same look.
    public var padding: Double
    public var cornerRadius: Double
    public var shadow: Double
    public var ratio: FrameRatio

    public init(background: FrameBackground = FrameBackground.meshPresets[0], padding: Double = 0.12,
                cornerRadius: Double = 0.03, shadow: Double = 0.03, ratio: FrameRatio = .auto) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.ratio = ratio
    }
}

public enum FrameGeometry {
    /// Canvas size and where the image goes on it (origin at the top left), all in whole pixels.
    public static func layout(imageSize: CGSize, options: FrameOptions) -> (canvas: CGSize, imageRect: CGRect) {
        let padding = (min(imageSize.width, imageSize.height) * options.padding).rounded()
        var canvas = CGSize(width: imageSize.width + padding * 2, height: imageSize.height + padding * 2)
        if let ratio = options.ratio.value {
            if canvas.width / canvas.height < ratio {
                canvas.width = (canvas.height * ratio).rounded()
            } else {
                canvas.height = (canvas.width / ratio).rounded()
            }
        }
        let origin = CGPoint(x: ((canvas.width - imageSize.width) / 2).rounded(), y: ((canvas.height - imageSize.height) / 2).rounded())
        return (canvas, CGRect(origin: origin, size: imageSize))
    }
}

/// Draws an image on a background with padding, rounded corners and a soft shadow.
public enum FrameRenderer {
    public static func render(_ image: CGImage, options: FrameOptions, backgroundImage: CGImage? = nil) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let (canvas, rect) = FrameGeometry.layout(imageSize: size, options: options)
        let width = Int(canvas.width), height = Int(canvas.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw YuzuError.writeFailed("image")
        }
        context.interpolationQuality = .high
        let bounds = CGRect(origin: .zero, size: canvas)
        drawBackground(options.background, backgroundImage: backgroundImage, in: context, bounds: bounds)

        // CoreGraphics has its origin at the bottom left.
        let target = CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
        let shortSide = min(size.width, size.height)
        let radius = min(shortSide * options.cornerRadius, shortSide / 2)
        let shape = CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let shadow = shortSide * options.shadow
        if shadow > 0.5 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -shadow * 0.35), blur: shadow,
                              color: CGColor(gray: 0, alpha: 0.38))
            context.addPath(shape)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.draw(image, in: target)
        context.restoreGState()

        guard let result = context.makeImage() else { throw YuzuError.writeFailed("image") }
        return result
    }

    public static func drawBackground(_ background: FrameBackground, backgroundImage: CGImage?, in context: CGContext, bounds: CGRect) {
        switch background {
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(bounds)
        case .mesh(let colors):
            drawMesh(colors, in: context, bounds: bounds)
        case .image:
            guard let backgroundImage else {
                context.setFillColor(CGColor(gray: 0.9, alpha: 1))
                context.fill(bounds)
                return
            }
            // Aspect fill: cover the whole canvas and crop what sticks out.
            let scale = max(bounds.width / CGFloat(backgroundImage.width), bounds.height / CGFloat(backgroundImage.height))
            let size = CGSize(width: CGFloat(backgroundImage.width) * scale, height: CGFloat(backgroundImage.height) * scale)
            context.draw(backgroundImage, in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                                     width: size.width, height: size.height))
        }
    }

    /// A base color with large, soft radial blobs of the other colors in the corners.
    static func drawMesh(_ colors: [RGBAColor], in context: CGContext, bounds: CGRect) {
        guard let first = colors.first else { return }
        context.setFillColor(first.cgColor)
        context.fill(bounds)
        let anchors = [CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
        let radius = hypot(bounds.width, bounds.height) * 0.75
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for (index, color) in colors.dropFirst().enumerated() {
            let anchor = anchors[index % anchors.count]
            let center = CGPoint(x: bounds.minX + bounds.width * anchor.x, y: bounds.minY + bounds.height * anchor.y)
            guard let gradient = CGGradient(colorsSpace: space, colors: [color.cgColor, color.withAlpha(0).cgColor] as CFArray,
                                            locations: [0, 1]) else { continue }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
    }
}
