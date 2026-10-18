import CoreGraphics
import Foundation

/// Settings from a tool's options panel (see `FileTool.hasOptionsPanel`).
public enum FileToolOptions: Sendable, Equatable {
    case crop(CropOptions)
    case trim(TrimOptions)
    case compress(CompressionOptions)
}

// MARK: - Crop

/// Aspect ratio for the crop area.
public enum AspectRatio: Hashable, Sendable, Identifiable {
    case free
    case original
    case ratio(Int, Int)

    public static let presets: [AspectRatio] = [
        .free, .original, .ratio(1, 1), .ratio(4, 3), .ratio(3, 2), .ratio(16, 9), .ratio(4, 5), .ratio(3, 4), .ratio(9, 16),
    ]

    public var id: String { displayName }

    public var displayName: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .ratio(let width, let height): return "\(width):\(height)"
        }
    }

    /// Width divided by height, or `nil` when the ratio is free.
    public func value(for imageSize: CGSize) -> Double? {
        switch self {
        case .free: return nil
        case .original: return imageSize.height > 0 ? Double(imageSize.width / imageSize.height) : nil
        case .ratio(let width, let height): return height > 0 ? Double(width) / Double(height) : nil
        }
    }
}

public struct CropOptions: Sendable, Equatable {
    /// Crop area in pixels, origin at the top left, relative to `referenceSize` (the first image).
    public var rect: CGRect
    public var referenceSize: CGSize
    /// Width/height ratio enforced per image; `nil` is free.
    public var aspectRatio: Double?

    public init(rect: CGRect, referenceSize: CGSize, aspectRatio: Double? = nil) {
        self.rect = rect
        self.referenceSize = referenceSize
        self.aspectRatio = aspectRatio
    }

    /// The crop area for an image of `imageSize`: scaled from the reference and brought to the ratio if needed.
    public func pixelRect(for imageSize: CGSize) -> CGRect {
        guard referenceSize.width > 0, referenceSize.height > 0 else { return CGRect(origin: .zero, size: imageSize) }
        let sx = imageSize.width / referenceSize.width
        let sy = imageSize.height / referenceSize.height
        var scaled = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
        if let aspectRatio, sx != sy {
            scaled = CropGeometry.fit(scaled, ratio: aspectRatio, in: imageSize)
        }
        return CropGeometry.clamp(scaled, to: imageSize)
    }
}

/// Geometry for the crop area. All rectangles are in pixels with the origin at the top left.
public enum CropGeometry {
    public enum Handle: CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// The largest centered rectangle with ratio `ratio` inside `size`.
    public static func largestRect(ratio: Double?, in size: CGSize) -> CGRect {
        guard let ratio, ratio > 0 else { return CGRect(origin: .zero, size: size) }
        var width = size.width
        var height = width / ratio
        if height > size.height {
            height = size.height
            width = height * ratio
        }
        return clamp(CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height), to: size)
    }

    /// Brings `rect` to the ratio with (roughly) the same area and the same center, inside `size`.
    public static func fit(_ rect: CGRect, ratio: Double, in size: CGSize) -> CGRect {
        guard ratio > 0 else { return rect }
        let area = max(rect.width * rect.height, 1)
        var width = (area * ratio).squareRoot()
        var height = width / ratio
        let shrink = min(1, size.width / width, size.height / height)
        width *= shrink
        height *= shrink
        let fitted = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        return shiftedInside(fitted, size: size)
    }

    /// Rounds to whole pixels and keeps the rectangle inside the image (at least 1×1).
    public static func clamp(_ rect: CGRect, to size: CGSize) -> CGRect {
        let maxWidth = max(size.width.rounded(.down), 1)
        let maxHeight = max(size.height.rounded(.down), 1)
        let width = min(max(rect.width.rounded(), 1), maxWidth)
        let height = min(max(rect.height.rounded(), 1), maxHeight)
        let x = min(max(rect.minX.rounded(), 0), maxWidth - width)
        let y = min(max(rect.minY.rounded(), 0), maxHeight - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Moves the rectangle without changing its size.
    public static func moved(_ rect: CGRect, by delta: CGSize, in size: CGSize) -> CGRect {
        shiftedInside(rect.offsetBy(dx: delta.width, dy: delta.height), size: size)
    }

    /// Drags a corner to `point`; the opposite corner stays put.
    public static func resized(_ rect: CGRect, handle: Handle, to point: CGPoint, ratio: Double?,
                               in size: CGSize, minSide: CGFloat = 8) -> CGRect {
        let anchor: CGPoint
        switch handle {
        case .topLeft: anchor = CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: anchor = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: anchor = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: anchor = CGPoint(x: rect.minX, y: rect.minY)
        }
        let growsRight = handle == .topRight || handle == .bottomRight
        let growsDown = handle == .bottomLeft || handle == .bottomRight
        let maxWidth = growsRight ? size.width - anchor.x : anchor.x
        let maxHeight = growsDown ? size.height - anchor.y : anchor.y
        let minSide = min(minSide, maxWidth, maxHeight)

        var width = min(max(growsRight ? point.x - anchor.x : anchor.x - point.x, minSide), maxWidth)
        var height = min(max(growsDown ? point.y - anchor.y : anchor.y - point.y, minSide), maxHeight)
        if let ratio, ratio > 0 {
            if width / height > ratio { width = height * ratio } else { height = width / ratio }
            if width > maxWidth { width = maxWidth; height = width / ratio }
            if height > maxHeight { height = maxHeight; width = height * ratio }
        }
        return CGRect(x: growsRight ? anchor.x : anchor.x - width, y: growsDown ? anchor.y : anchor.y - height,
                      width: width, height: height)
    }

    static func shiftedInside(_ rect: CGRect, size: CGSize) -> CGRect {
        var result = rect
        result.size.width = min(result.width, size.width)
        result.size.height = min(result.height, size.height)
        result.origin.x = min(max(result.minX, 0), size.width - result.width)
        result.origin.y = min(max(result.minY, 0), size.height - result.height)
        return result
    }
}

// MARK: - Trim

public struct TrimOptions: Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// Re-encoding cuts on the exact frame; without re-encoding it is fast, but the start snaps to a keyframe.
    public var reencode: Bool

    public init(start: Double, end: Double, reencode: Bool = true) {
        self.start = start
        self.end = end
        self.reencode = reencode
    }

    public var duration: Double { max(end - start, 0) }

    /// Checks the range against the total duration (when known).
    public func validated(totalDuration: Double?) throws -> TrimOptions {
        var result = self
        result.start = max(start, 0)
        if let totalDuration { result.end = min(end, totalDuration) }
        guard result.duration >= 0.05 else { throw YuzuError.nothingToDo("The selected section is too short.") }
        if let totalDuration, result.start <= 0.0005, result.end >= totalDuration - 0.0005 {
            throw YuzuError.nothingToDo("The whole file is selected; there is nothing to trim.")
        }
        return result
    }
}

/// Times as `m:ss.f` or `h:mm:ss.f`; also reads plain seconds, decimal commas and omitted zeros.
public enum Timecode {
    public static func string(from seconds: Double, fractionDigits: Int = 1) -> String {
        let scale = pow(10, Double(fractionDigits))
        let total = (max(seconds, 0) * scale).rounded() / scale
        let hours = Int(total) / 3600
        let minutes = Int(total) / 60 % 60
        let secs = total - Double(hours * 3600 + minutes * 60)
        let width = fractionDigits > 0 ? 3 + fractionDigits : 2
        let secondsText = String(format: "%0\(width).\(fractionDigits)f", secs)
        return hours > 0 ? String(format: "%d:%02d:", hours, minutes) + secondsText : "\(minutes):" + secondsText
    }

    public static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            // Minutes and seconds after the first component must stay below 60.
            if index > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Seconds as ffmpeg expects them (`-ss`, `-t`).
    static func ffmpeg(_ seconds: Double) -> String {
        String(format: "%.3f", max(seconds, 0))
    }
}

// MARK: - Compress

public enum CompressionTarget: Sendable, Equatable {
    /// The existing fixed settings; the result is only kept when it is smaller.
    case automatic
    /// Percentage of the original size (1...99).
    case percentage(Int)
    /// Desired size in bytes.
    case size(Int64)

    public func targetBytes(forOriginal original: Int64) -> Int64? {
        switch self {
        case .automatic: return nil
        case .percentage(let percent): return max(original * Int64(min(max(percent, 1), 99)) / 100, 1)
        case .size(let bytes): return max(bytes, 1)
        }
    }
}

public struct CompressionOptions: Sendable, Equatable {
    public var target: CompressionTarget

    public init(target: CompressionTarget = .automatic) {
        self.target = target
    }
}

/// Chooses bitrates and resolution to get a video to a target size.
public enum CompressionPlanner {
    public struct VideoPlan: Sendable, Equatable {
        public var videoBitrate: Int
        public var audioBitrate: Int
        /// Maximum height in pixels when the video needs to shrink; `nil` keeps the resolution.
        public var maxHeight: Int?
    }

    /// Room for the container (moov atom, headers).
    static let containerOverhead = 0.97
    public static let minimumVideoBitrate = 100_000

    public static func videoPlan(targetBytes: Int64, duration: Double, sourceHeight: Int?, hasAudio: Bool) throws -> VideoPlan {
        guard duration > 0 else { throw YuzuError.nothingToDo("The duration of the video is unknown.") }
        let total = Int(Double(targetBytes) * 8 * containerOverhead / duration)
        let audio: Int
        if !hasAudio { audio = 0 } else if total >= 1_000_000 { audio = 128_000 } else if total >= 300_000 { audio = 96_000 } else { audio = 64_000 }
        let video = total - audio
        guard video >= minimumVideoBitrate else {
            let minimum = minimumBytes(duration: duration, hasAudio: hasAudio)
            throw YuzuError.nothingToDo("The target size is too small for this video; choose at least \(ByteCountFormatter.string(fromByteCount: minimum, countStyle: .file)).")
        }
        let limit: Int?
        switch video {
        case ..<600_000: limit = 480
        case ..<1_500_000: limit = 720
        case ..<4_000_000: limit = 1080
        default: limit = nil
        }
        let maxHeight = limit.flatMap { limit in (sourceHeight ?? Int.max) > limit ? limit : nil }
        return VideoPlan(videoBitrate: video, audioBitrate: audio, maxHeight: maxHeight)
    }

    public static func minimumBytes(duration: Double, hasAudio: Bool) -> Int64 {
        let bits = Double(minimumVideoBitrate + (hasAudio ? 64_000 : 0)) * duration
        return Int64((bits / 8 / containerOverhead).rounded(.up))
    }
}
