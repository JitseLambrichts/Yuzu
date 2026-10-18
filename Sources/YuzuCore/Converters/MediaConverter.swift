import AVFoundation
import Foundation

/// Bouwt ffmpeg-argumenten. Los van het uitvoeren, zodat het testbaar is.
public enum FFmpegArguments {
    public static func base(input: URL) -> [String] {
        ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats", "-i", input.path]
    }

    public static func audioCodec(for format: ConversionFormat, quality: Quality, encoders: Set<String>) -> [String] {
        let bitrate: String
        switch quality {
        case .compact: bitrate = "128k"
        case .balanced: bitrate = "192k"
        case .high: bitrate = "320k"
        }
        switch format {
        case .mp3: return ["-c:a", "libmp3lame", "-b:a", bitrate]
        case .m4a, .mp4, .mov, .mkv: return ["-c:a", "aac", "-b:a", bitrate]
        case .wav: return ["-c:a", "pcm_s16le"]
        case .aiff: return ["-c:a", "pcm_s16be"]
        case .flac: return ["-c:a", "flac"]
        case .ogg:
            if encoders.contains("libvorbis") { return ["-c:a", "libvorbis", "-q:a", "5"] }
            return ["-c:a", "libopus", "-b:a", quality == .high ? "192k" : "128k"]
        case .opus, .webm: return ["-c:a", "libopus", "-b:a", quality == .high ? "192k" : "128k"]
        case .wma, .wmv: return ["-c:a", "wmav2", "-b:a", bitrate]
        case .avi: return ["-c:a", "libmp3lame", "-b:a", bitrate]
        default: return []
        }
    }

    /// Volledige argumentenlijst voor een conversie naar `format`.
    public static func conversion(input: URL, output: URL, format: ConversionFormat, quality: Quality,
                                  preserveMetadata: Bool, encoders: Set<String> = []) -> [String] {
        var args = base(input: input)
        args += ["-map_metadata", preserveMetadata ? "0" : "-1"]
        args += codecArguments(for: format, quality: quality, encoders: encoders)
        args.append(output.path)
        return args
    }

    /// Codec-argumenten (video en audio) voor een doelcontainer.
    public static func codecArguments(for format: ConversionFormat, quality: Quality, encoders: Set<String> = []) -> [String] {
        var args: [String] = []
        let videoQuality: String
        switch quality {
        case .compact: videoQuality = "45"
        case .balanced: videoQuality = "60"
        case .high: videoQuality = "75"
        }
        switch format {
        case .mp4, .mov, .mkv:
            args += ["-c:v", "h264_videotoolbox", "-q:v", videoQuality, "-pix_fmt", "yuv420p"]
            args += audioCodec(for: format, quality: quality, encoders: encoders)
            if format == .mp4 || format == .mov { args += ["-movflags", "+faststart"] }
        case .webm:
            let crf = quality == .compact ? "38" : (quality == .balanced ? "32" : "26")
            args += ["-c:v", "libvpx-vp9", "-crf", crf, "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
            args += audioCodec(for: format, quality: quality, encoders: encoders)
        case .avi:
            args += ["-c:v", "mpeg4", "-q:v", quality == .high ? "2" : "4", "-tag:v", "XVID"]
            args += audioCodec(for: format, quality: quality, encoders: encoders)
        case .wmv:
            args += ["-c:v", "wmv2", "-q:v", quality == .high ? "2" : "4"]
            args += audioCodec(for: format, quality: quality, encoders: encoders)
        case .gif:
            let width = quality == .high ? 720 : (quality == .balanced ? 480 : 360)
            let fps = quality == .compact ? 10 : 15
            args += ["-an", "-vf", "fps=\(fps),scale='min(\(width),iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                     "-loop", "0"]
        default:
            args += ["-vn"]
            args += audioCodec(for: format, quality: quality, encoders: encoders)
        }
        return args
    }

    /// Een stuk uit audio of video. `-ss` vóór `-i` zoekt snel; bij hercoderen blijft de start toch frame-exact.
    public static func trim(input: URL, output: URL, options: TrimOptions, format: ConversionFormat?, isVideo: Bool,
                            encoders: Set<String> = []) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats",
                    "-ss", Timecode.ffmpeg(options.start), "-t", Timecode.ffmpeg(options.duration), "-i", input.path,
                    "-map_metadata", "0"]
        if !options.reencode {
            args += ["-map", "0:v?", "-map", "0:a?", "-c", "copy", "-avoid_negative_ts", "make_zero"]
        } else if isVideo {
            args += codecArguments(for: format ?? .mp4, quality: .high, encoders: encoders)
        } else {
            args += ["-vn"] + audioCodec(for: format ?? .m4a, quality: .high, encoders: encoders)
        }
        args.append(output.path)
        return args
    }

    /// Video naar MP4 (HEVC) met een vaste bitrate uit `CompressionPlanner`.
    public static func compressVideo(input: URL, output: URL, plan: CompressionPlanner.VideoPlan) -> [String] {
        let kbps = max(plan.videoBitrate / 1000, 1)
        var args = base(input: input) + ["-map_metadata", "0"]
        if let maxHeight = plan.maxHeight {
            args += ["-vf", "scale=-2:'min(ih,\(maxHeight))'"]
        }
        args += ["-c:v", "hevc_videotoolbox", "-b:v", "\(kbps)k", "-maxrate", "\(kbps * 11 / 10)k", "-bufsize", "\(kbps * 2)k",
                 "-tag:v", "hvc1"]
        if plan.audioBitrate > 0 {
            args += ["-c:a", "aac", "-b:a", "\(plan.audioBitrate / 1000)k"]
        } else {
            args += ["-an"]
        }
        args += ["-movflags", "+faststart", output.path]
        return args
    }
}

public enum MediaConverter {
    /// Encoders van de gevonden ffmpeg, eenmalig opgevraagd.
    nonisolated(unsafe) private static var cachedEncoders: Set<String>?

    static func encoders(ffmpeg: URL) async -> Set<String> {
        if let cachedEncoders { return cachedEncoders }
        let result = try? await ProcessRunner.run(ffmpeg, ["-hide_banner", "-encoders"])
        let names = (result?.stdout ?? "").split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count >= 2 ? String(parts[1]) : nil
        }
        cachedEncoders = Set(names)
        return Set(names)
    }

    public static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        let seconds = duration.seconds
        return seconds > 0 ? seconds : nil
    }

    /// Voert ffmpeg uit en meldt voortgang (0...1) op basis van `out_time_us`.
    public static func runFFmpeg(_ arguments: [String], duration: Double?, progress: @escaping @Sendable (Double) -> Void) async throws {
        let ffmpeg = try ToolLocator.require("ffmpeg")
        try await ProcessRunner.runChecked(ffmpeg, arguments) { line in
            guard let duration, duration > 0 else { return }
            if line.hasPrefix("out_time_us="), let micro = Double(line.dropFirst("out_time_us=".count)) {
                progress(min(max(micro / 1_000_000 / duration, 0), 1))
            } else if line == "progress=end" {
                progress(1)
            }
        }
    }

    public static func convert(_ source: URL, to format: ConversionFormat, settings: ConversionSettings, output: URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let ffmpeg = try ToolLocator.require("ffmpeg")
        let encoders = await encoders(ffmpeg: ffmpeg)
        let arguments = FFmpegArguments.conversion(input: source, output: output, format: format, quality: settings.quality,
                                                   preserveMetadata: settings.preserveMetadata, encoders: encoders)
        try await runFFmpeg(arguments, duration: await duration(of: source), progress: progress)
    }
}
