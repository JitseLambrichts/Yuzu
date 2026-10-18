import Foundation
import ImageIO
import Vision

public struct ToolResult: Sendable {
    public var outputs: [URL]
    /// Text the app shows or copies to the clipboard (for example the contents of a QR code).
    public var message: String?

    public init(outputs: [URL], message: String? = nil) {
        self.outputs = outputs
        self.message = message
    }
}

/// Runs the tools on the ⌘ wheel. Tools with an options panel receive the choices through `options`;
/// without options they use sensible defaults (or refuse when that isn't possible).
public enum FileToolEngine {
    public static func run(_ tool: FileTool, sources: [URL], options: FileToolOptions? = nil, settings: ConversionSettings = .init(),
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ToolResult {
        guard tool.applies(to: sources.map(FileCategory.of)) else {
            throw YuzuError.unsupported("\(tool.displayName) for this selection")
        }
        switch tool {
        case .createPDF:
            let output = OutputNaming.output(for: sources[0], fileExtension: "pdf", suffix: sources.count > 1 ? "and more" : nil)
            try ImageConverter.writePDF(images: sources, to: output)
            return ToolResult(outputs: [output])
        case .mergePDF:
            let output = OutputNaming.uniqueURL(in: sources[0].deletingLastPathComponent(), baseName: "Merged", fileExtension: "pdf")
            try PDFConverter.merge(sources, into: output)
            return ToolResult(outputs: [output])
        case .readQRCode:
            let payloads = try sources.flatMap(readCodes)
            guard !payloads.isEmpty else { throw YuzuError.nothingToDo("No QR code or barcode found.") }
            return ToolResult(outputs: [], message: payloads.joined(separator: "\n"))
        default:
            var outputs: [URL] = []
            for (index, source) in sources.enumerated() {
                let step: @Sendable (Double) -> Void = { fraction in
                    progress((Double(index) + fraction) / Double(sources.count))
                }
                outputs += try await runSingle(tool, source: source, options: options, settings: settings, progress: step)
            }
            return ToolResult(outputs: outputs)
        }
    }

    static func runSingle(_ tool: FileTool, source: URL, options: FileToolOptions?, settings: ConversionSettings,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let category = FileCategory.of(source)
        let ext = source.pathExtension.lowercased()
        var compression = CompressionTarget.automatic
        if case .compress(let chosen) = options { compression = chosen.target }
        let targetBytes = compression.targetBytes(forOriginal: Int64(fileSize(source)))
        switch (tool, category) {
        case (.compress, .image):
            return [try compressImage(source, targetBytes: targetBytes)]
        case (.compress, .video) where targetBytes != nil:
            return [try await compressVideo(source, targetBytes: targetBytes!, progress: progress)]
        case (.compress, .video):
            let output = OutputNaming.output(for: source, fileExtension: "mp4", suffix: "compressed")
            let args = FFmpegArguments.base(input: source) + [
                "-map_metadata", "0", "-c:v", "hevc_videotoolbox", "-q:v", "45", "-tag:v", "hvc1",
                "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", output.path,
            ]
            try await runMedia(args, source: source, output: output, progress: progress)
            return [try keepIfSmaller(output, than: source)]
        case (.compress, .pdf):
            let output = OutputNaming.output(for: source, fileExtension: "pdf", suffix: "compressed")
            try PDFConverter.compress(source, into: output)
            return [try keepIfSmaller(output, than: source)]
        case (.cropImage, .image):
            guard case .crop(let crop) = options else { throw YuzuError.nothingToDo("Choose a crop area first.") }
            return [try cropImage(source, options: crop, settings: settings)]
        case (.trimVideo, .video), (.trimAudio, .audio):
            guard case .trim(let trim) = options else { throw YuzuError.nothingToDo("Choose a start and an end first.") }
            return [try await self.trim(source, options: trim, isVideo: category == .video, progress: progress)]
        case (.removeMetadata, .image):
            return [try stripImageMetadata(source)]
        case (.removeMetadata, .pdf):
            let output = OutputNaming.output(for: source, fileExtension: "pdf", suffix: "no metadata")
            try PDFConverter.removeMetadata(source, into: output)
            return [output]
        case (.removeMetadata, .audio), (.removeMetadata, .video):
            let output = OutputNaming.output(for: source, fileExtension: ext, suffix: "no metadata")
            let args = FFmpegArguments.base(input: source) + [
                "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy", output.path,
            ]
            try await runMedia(args, source: source, output: output, progress: progress)
            return [output]
        case (.splitPDF, .pdf):
            return [try PDFConverter.split(source)]
        case (.muteVideo, .video):
            let output = OutputNaming.output(for: source, fileExtension: ext, suffix: "muted")
            let args = FFmpegArguments.base(input: source) + ["-map_metadata", "0", "-c:v", "copy", "-an", output.path]
            try await runMedia(args, source: source, output: output, progress: progress)
            return [output]
        case (.normalizeAudio, _):
            let format = ConversionFormat.matching(source).flatMap { $0.isAudioFormat || $0.isVideoFormat ? $0 : nil } ?? .m4a
            let output = OutputNaming.output(for: source, fileExtension: format.fileExtension, suffix: "normalized")
            var args = FFmpegArguments.base(input: source) + ["-map_metadata", "0", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11"]
            if category == .video { args += ["-c:v", "copy"] }
            args += FFmpegArguments.audioCodec(for: format, quality: .high, encoders: [])
            args.append(output.path)
            try await runMedia(args, source: source, output: output, progress: progress)
            return [output]
        case (.extractArchive, .archive):
            return [try await ArchiveConverter.extractNextToSource(source)]
        default:
            throw YuzuError.unsupported("\(tool.displayName) for \(source.lastPathComponent)")
        }
    }

    static func runMedia(_ arguments: [String], source: URL, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await runMedia(arguments, duration: await MediaConverter.duration(of: source), output: output, progress: progress)
    }

    static func runMedia(_ arguments: [String], duration: Double?, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await MediaConverter.runFFmpeg(arguments, duration: duration, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func keepIfSmaller(_ output: URL, than source: URL) throws -> URL {
        if fileSize(output) >= fileSize(source) {
            try? FileManager.default.removeItem(at: output)
            throw YuzuError.nothingToDo("\(source.lastPathComponent) is already as small as it can get.")
        }
        return output
    }

    /// Re-encodes lossy formats; lossless formats become JPEG (without alpha) or HEIC (with alpha).
    /// With `targetBytes` it searches for the highest quality that fits and shrinks the dimensions if needed.
    static func compressImage(_ source: URL, targetBytes: Int64? = nil) throws -> URL {
        let (image, properties) = try ImageConverter.loadOriented(source)
        var format = ConversionFormat.matching(source) ?? .jpg
        if ![.jpg, .heic, .avif].contains(format) || !ImageCapabilities.canWriteNatively(format) {
            format = image.hasAlpha && ImageCapabilities.canWriteNatively(.heic) ? .heic : .jpg
        }
        let output = OutputNaming.output(for: source, fileExtension: format.fileExtension, suffix: "compressed")
        if let targetBytes {
            let data = try ImageSizeFitter.encode(image, properties: properties, format: format, targetBytes: targetBytes,
                                                  name: source.lastPathComponent)
            do { try data.write(to: output, options: .withoutOverwriting) } catch { throw YuzuError.writeFailed(output.lastPathComponent) }
        } else {
            try ImageConverter.write(image, properties: properties, format: format, quality: 0.55, to: output)
        }
        return try keepIfSmaller(output, than: source)
    }

    /// Removes EXIF/GPS/IPTC/XMP without re-encoding the image.
    static func stripImageMetadata(_ source: URL) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(imageSource) else {
            throw YuzuError.unreadable(source.lastPathComponent)
        }
        let output = OutputNaming.output(for: source, fileExtension: source.pathExtension, suffix: "no metadata")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw YuzuError.writeFailed(output.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageDestinationOrientation: orientation,
        ]
        var error: Unmanaged<CFError>?
        if !CGImageDestinationCopyImageSource(destination, imageSource, options as CFDictionary, &error) {
            // Not every format supports copying without re-encoding; in that case, rewrite it without properties.
            try? FileManager.default.removeItem(at: output)
            let (image, _) = try ImageConverter.loadOriented(source)
            let format = ConversionFormat.matching(source) ?? .png
            try ImageConverter.write(image, properties: [:], format: format, quality: 0.95, to: output)
        }
        return output
    }

    static func readCodes(_ source: URL) throws -> [String] {
        let (image, _) = try ImageConverter.loadOriented(source)
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}
