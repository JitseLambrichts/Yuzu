import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageConverter {
    /// Leest een afbeelding met de juiste oriëntatie toegepast, plus de originele eigenschappen.
    public static func loadOriented(_ url: URL) throws -> (image: CGImage, properties: [CFString: Any]) {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return (image, properties)
            }
        }
        // Terugval voor formaten die ImageIO niet leest, zoals SVG.
        if let image = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: image.size)
            if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return (cgImage, [:])
            }
        }
        throw YuzuError.unreadable(url.lastPathComponent)
    }

    /// Een kleinere versie om te tonen, plus de echte pixelgrootte na oriëntatie (voor het bijsnijkader).
    public static func preview(_ url: URL, maxPixelSize: Int = 1600) throws -> (image: CGImage, pixelSize: CGSize) {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            let size = (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPixelSize),
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return (image, size)
            }
        }
        let (image, _) = try loadOriented(url)
        return (image, CGSize(width: image.width, height: image.height))
    }

    public static func convert(_ source: URL, to format: ConversionFormat, settings: ConversionSettings, output: URL) async throws {
        if format == .pdf {
            try writePDF(images: [source], to: output)
            return
        }
        if format == .webp, !ImageCapabilities.canWriteNatively(.webp) {
            try await writeWebP(source, quality: settings.quality, preserveMetadata: settings.preserveMetadata, output: output)
            return
        }
        let (image, properties) = try loadOriented(source)
        try write(image, properties: settings.preserveMetadata ? properties : [:],
                  format: format, quality: settings.quality.imageQuality, to: output)
    }

    /// Schrijft een CGImage via ImageIO. Oriëntatie is al toegepast, dus die tag wordt op 1 gezet.
    public static func write(_ image: CGImage, properties: [CFString: Any], format: ConversionFormat, quality: Double, to output: URL) throws {
        guard let type = ImageCapabilities.utType(for: format), ImageCapabilities.canWriteNatively(format) else {
            throw YuzuError.unsupported("\(format.displayName) schrijven op deze Mac")
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw YuzuError.writeFailed(output.lastPathComponent)
        }
        try add(image, properties: properties, format: format, quality: quality, to: destination, name: output.lastPathComponent)
    }

    /// Zoals `write`, maar in het geheugen; handig om de grootte bij een bepaalde kwaliteit te meten.
    public static func encode(_ image: CGImage, properties: [CFString: Any], format: ConversionFormat, quality: Double) throws -> Data {
        guard let type = ImageCapabilities.utType(for: format), ImageCapabilities.canWriteNatively(format) else {
            throw YuzuError.unsupported("\(format.displayName) schrijven op deze Mac")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw YuzuError.writeFailed(format.displayName)
        }
        try add(image, properties: properties, format: format, quality: quality, to: destination, name: format.displayName)
        return data as Data
    }

    private static func add(_ image: CGImage, properties: [CFString: Any], format: ConversionFormat, quality: Double,
                            to destination: CGImageDestination, name: String) throws {
        var finalImage = image
        if [.jpg, .bmp].contains(format), image.hasAlpha {
            finalImage = try flattenOnWhite(image)
        }
        var options: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = properties[key] { options[key] = value }
        }
        if var tiff = options[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            options[kCGImagePropertyTIFFDictionary] = tiff
        }
        options[kCGImagePropertyOrientation] = 1
        options[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, finalImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw YuzuError.writeFailed(name)
        }
    }

    /// Verkleint (of vergroot) met hoge interpolatie; alfa blijft behouden.
    public static func scaled(_ image: CGImage, by factor: Double) throws -> CGImage {
        let width = max(Int((Double(image.width) * factor).rounded()), 1)
        let height = max(Int((Double(image.height) * factor).rounded()), 1)
        let alpha = image.hasAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: alpha.rawValue)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue) else {
            throw YuzuError.writeFailed("afbeelding")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw YuzuError.writeFailed("afbeelding") }
        return result
    }

    static func flattenOnWhite(_ image: CGImage) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw YuzuError.writeFailed("afbeelding")
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw YuzuError.writeFailed("afbeelding") }
        return result
    }

    /// WebP via cwebp, voor systemen waar ImageIO geen WebP kan schrijven.
    static func writeWebP(_ source: URL, quality: Quality, preserveMetadata: Bool, output: URL) async throws {
        let cwebp = try ToolLocator.require("cwebp")
        var input = source
        var temporary: URL?
        let directlyReadable: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff"]
        if !directlyReadable.contains(source.pathExtension.lowercased()) {
            let (image, _) = try loadOriented(source)
            let png = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try write(image, properties: [:], format: .png, quality: 1, to: png)
            input = png
            temporary = png
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        let q = String(Int(quality.imageQuality * 100))
        try await ProcessRunner.runChecked(cwebp, ["-quiet", "-q", q, "-metadata", preserveMetadata ? "all" : "none",
                                                   input.path, "-o", output.path])
    }

    /// Eén PDF met een pagina per afbeelding.
    public static func writePDF(images: [URL], to output: URL) throws {
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw YuzuError.writeFailed(output.lastPathComponent)
        }
        for url in images {
            let (image, properties) = try loadOriented(url)
            let dpi = max(properties[kCGImagePropertyDPIWidth] as? Double ?? 72, 72)
            let size = CGSize(width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}
