import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import YuzuCore

enum TestFiles {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Een PNG met kleurvlakken en optioneel EXIF/GPS-metadata (in een JPEG).
    static func makeImage(in dir: URL, name: String = "sample.png", type: UTType = .png, alpha: Bool = false, metadata: Bool = false) throws -> URL {
        let width = 120, height = 80
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
        context.setFillColor(CGColor(red: 0.95, green: 0.8, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.2, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 60, y: 0, width: 60, height: 80))
        let image = context.makeImage()!
        let url = dir.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if metadata {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: "geheim"]
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 51.2, kCGImagePropertyGPSLatitudeRef: "N"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return url
    }

    static func write(_ text: String, to dir: URL, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func imageProperties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func imageType(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }
}
