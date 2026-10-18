import AVFoundation
import Foundation

public struct MediaInfo: Sendable, Equatable {
    public var duration: Double?
    /// Display size of the first video stream (with rotation applied).
    public var videoSize: CGSize?
    public var hasAudio: Bool
    /// Whether AVFoundation can play the file (if not, there is no AVPlayer preview, for example for WebM or MKV).
    public var isPlayable: Bool

    public init(duration: Double?, videoSize: CGSize?, hasAudio: Bool, isPlayable: Bool) {
        self.duration = duration
        self.videoSize = videoSize
        self.hasAudio = hasAudio
        self.isPlayable = isPlayable
    }
}

/// Reads duration and streams: first through AVFoundation, falling back to ffprobe for containers AVFoundation doesn't know.
public enum MediaProbe {
    public static func info(of url: URL) async -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        if playable, let duration = await MediaConverter.duration(of: url) {
            var size: CGSize?
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let rect = CGRect(origin: .zero, size: natural).applying(transform)
                size = CGSize(width: abs(rect.width), height: abs(rect.height))
            }
            let audio = (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false
            return MediaInfo(duration: duration, videoSize: size, hasAudio: audio, isPlayable: true)
        }
        if let probed = await ffprobe(url) { return probed }
        return MediaInfo(duration: nil, videoSize: nil, hasAudio: true, isPlayable: playable)
    }

    static func ffprobe(_ url: URL) async -> MediaInfo? {
        guard let ffprobe = ToolLocator.find("ffprobe"),
              let result = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-show_entries",
                                                                  "format=duration:stream=codec_type,width,height",
                                                                  "-of", "json", url.path]),
              let data = result.stdout.data(using: .utf8) else { return nil }
        return parseFFprobe(data)
    }

    static func parseFFprobe(_ data: Data) -> MediaInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let format = json["format"] as? [String: Any]
        let duration = (format?["duration"] as? String).flatMap(Double.init)
        let streams = json["streams"] as? [[String: Any]] ?? []
        let video = streams.first { $0["codec_type"] as? String == "video" }
        let size = video.flatMap { stream -> CGSize? in
            guard let width = stream["width"] as? Int, let height = stream["height"] as? Int else { return nil }
            return CGSize(width: width, height: height)
        }
        let audio = streams.contains { $0["codec_type"] as? String == "audio" }
        return MediaInfo(duration: duration, videoSize: size, hasAudio: audio, isPlayable: false)
    }
}

/// Waveform for the timeline of the trim panel.
public enum Waveform {
    /// `count` peak values (0...1) over the whole duration; empty when AVFoundation can't read the file.
    public static func peaks(of url: URL, count: Int) async throws -> [Float] {
        guard count > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let duration = try await asset.load(.duration).seconds
        let sampleRate = 8000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? YuzuError.unreadable(url.lastPathComponent) }

        // Track the peak per bucket while reading, so long files use little memory.
        let perBucket = max(1, Int(duration.isFinite ? duration * sampleRate : 0) / count)
        var peaks: [Int16] = []
        var current: Int16 = 0
        var filled = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            for sample in chunk {
                current = max(current, Int16(clamping: sample.magnitude))
                filled += 1
                if filled == perBucket {
                    peaks.append(current)
                    current = 0
                    filled = 0
                }
            }
        }
        if filled > 0 { peaks.append(current) }
        return bucket(peaks, count: count)
    }

    static func bucket(_ samples: [Int16], count: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var peaks = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let lower = index * samples.count / count
            let upper = max((index + 1) * samples.count / count, lower + 1)
            let slice = samples[lower..<min(upper, samples.count)]
            peaks[index] = Float(slice.map { $0.magnitude }.max() ?? 0) / Float(Int16.max)
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { min($0 / loudest, 1) } : peaks
    }
}
