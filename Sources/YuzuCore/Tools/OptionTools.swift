import CoreGraphics
import Foundation
import ImageIO

/// Tools with an options panel: crop, trim and compress to a target size.
extension FileToolEngine {
    static func cropImage(_ source: URL, options: CropOptions, settings: ConversionSettings) throws -> URL {
        let (image, properties) = try ImageConverter.loadOriented(source)
        let rect = options.pixelRect(for: CGSize(width: image.width, height: image.height))
        guard let cropped = image.cropping(to: rect) else { throw YuzuError.writeFailed(source.lastPathComponent) }

        return try writeEdited(cropped, from: source, properties: properties, suffix: "cropped", settings: settings)
    }

    static func frameImage(_ source: URL, options: FrameOptions, settings: ConversionSettings) throws -> URL {
        let (image, properties) = try ImageConverter.loadOriented(source)
        var backgroundImage: CGImage?
        if case .image(let url) = options.background {
            backgroundImage = try ImageConverter.loadOriented(url).image
        }
        let framed = try FrameRenderer.render(image, options: options, backgroundImage: backgroundImage)
        return try writeEdited(framed, from: source, properties: properties, suffix: "with background", settings: settings)
    }

    static func annotateImage(_ source: URL, options: AnnotateOptions, settings: ConversionSettings) throws -> URL {
        let (image, properties) = try ImageConverter.loadOriented(source)
        var annotations = options.annotations
        let size = CGSize(width: image.width, height: image.height)
        if options.referenceSize.width > 0, abs(options.referenceSize.width - size.width) > 0.5 {
            annotations = annotations.map { $0.scaled(by: size.width / options.referenceSize.width) }
        }
        let annotated = try AnnotationRenderer.render(image, annotations: annotations)
        return try writeEdited(annotated, from: source, properties: properties, suffix: "annotated", settings: settings)
    }

    /// Writes an edited image next to the original, in the original format when this Mac can write it (PNG otherwise).
    static func writeEdited(_ image: CGImage, from source: URL, properties: [CFString: Any], suffix: String,
                            settings: ConversionSettings) throws -> URL {
        var format = ConversionFormat.matching(source) ?? .png
        if format == .gif || ImageCapabilities.utType(for: format) == nil || !ImageCapabilities.canWriteNatively(format) {
            format = .png
        }
        var kept: [CFString: Any] = [:]
        if settings.preserveMetadata {
            kept = properties
            // The old dimensions are no longer correct after editing.
            if var exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = nil
                exif[kCGImagePropertyExifPixelYDimension] = nil
                kept[kCGImagePropertyExifDictionary] = exif
            }
        }
        let output = OutputNaming.output(for: source, fileExtension: format.fileExtension, suffix: suffix)
        try ImageConverter.write(image, properties: kept, format: format, quality: max(settings.quality.imageQuality, 0.9), to: output)
        return output
    }

    static func trim(_ source: URL, options: TrimOptions, isVideo: Bool,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let ffmpeg = try ToolLocator.require("ffmpeg")
        let info = await MediaProbe.info(of: source)
        let range = try options.validated(totalDuration: info.duration)

        let sourceFormat = ConversionFormat.matching(source)
        let format: ConversionFormat?
        let fileExtension: String
        if !range.reencode {
            // Copying streams is only safe within the same container.
            format = sourceFormat
            fileExtension = source.pathExtension
        } else if isVideo {
            let chosen = sourceFormat.flatMap { $0.isVideoFormat ? $0 : nil } ?? .mp4
            format = chosen
            fileExtension = chosen.fileExtension
        } else {
            let chosen = sourceFormat.flatMap { $0.isAudioFormat ? $0 : nil } ?? .m4a
            format = chosen
            fileExtension = chosen.fileExtension
        }
        let output = OutputNaming.output(for: source, fileExtension: fileExtension, suffix: "trimmed")
        let arguments = FFmpegArguments.trim(input: source, output: output, options: range, format: format, isVideo: isVideo,
                                             encoders: await MediaConverter.encoders(ffmpeg: ffmpeg))
        try await runMedia(arguments, duration: range.duration, output: output, progress: progress)
        return output
    }

    /// Video to a target size. VideoToolbox sometimes overshoots the bitrate; if so, it tries once more.
    static func compressVideo(_ source: URL, targetBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let info = await MediaProbe.info(of: source)
        guard let duration = info.duration else {
            throw YuzuError.nothingToDo("Couldn't determine the duration of \(source.lastPathComponent).")
        }
        var plan = try CompressionPlanner.videoPlan(targetBytes: targetBytes, duration: duration,
                                                    sourceHeight: info.videoSize.map { Int($0.height) }, hasAudio: info.hasAudio)
        let output = OutputNaming.output(for: source, fileExtension: "mp4", suffix: "compressed")
        try await runMedia(FFmpegArguments.compressVideo(input: source, output: output, plan: plan),
                           duration: duration, output: output) { progress($0 * 0.85) }

        let actual = fileSize(output)
        if Double(actual) > Double(targetBytes) * 1.08 {
            let corrected = Int(Double(plan.videoBitrate) * Double(targetBytes) / Double(actual) * 0.95)
            if corrected >= CompressionPlanner.minimumVideoBitrate {
                plan.videoBitrate = corrected
                try FileManager.default.removeItem(at: output)
                try await runMedia(FFmpegArguments.compressVideo(input: source, output: output, plan: plan),
                                   duration: duration, output: output) { progress(0.85 + $0 * 0.15) }
            }
        }
        progress(1)
        return try keepIfSmaller(output, than: source)
    }
}

/// Finds the quality (and smaller dimensions if needed) that keeps an image below a target size.
enum ImageSizeFitter {
    static func encode(_ image: CGImage, properties: [CFString: Any], format: ConversionFormat, targetBytes: Int64,
                       name: String) throws -> Data {
        var current = image
        for _ in 0..<8 {
            let best = try ImageConverter.encode(current, properties: properties, format: format, quality: 0.95)
            if best.count <= targetBytes { return best }
            let floor = try ImageConverter.encode(current, properties: properties, format: format, quality: 0.05)
            if floor.count <= targetBytes {
                var low = 0.05, high = 0.95, fitting = floor
                for _ in 0..<7 {
                    let middle = (low + high) / 2
                    let data = try ImageConverter.encode(current, properties: properties, format: format, quality: middle)
                    if data.count <= targetBytes {
                        fitting = data
                        low = middle
                    } else {
                        high = middle
                    }
                }
                return fitting
            }
            // Even the lowest quality is too large: scale down and search again.
            let factor = min(max((Double(targetBytes) / Double(floor.count)).squareRoot() * 0.9, 0.1), 0.9)
            guard current.width > 16, current.height > 16 else { break }
            current = try ImageConverter.scaled(current, by: factor)
        }
        throw YuzuError.nothingToDo("Couldn't make \(name) small enough for the chosen size.")
    }
}
