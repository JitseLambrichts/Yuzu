import Foundation

public struct SubtitleCue: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// SRT ↔ VTT and export to plain text.
public enum SubtitleConverter {
    public static func parse(_ content: String) -> [SubtitleCue] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTime(parts[0]),
                  let end = parseTime(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") else { continue }
            let text = lines[(timingIndex + 1)...].joined(separator: "\n")
            cues.append(SubtitleCue(start: start, end: end, text: text))
        }
        return cues
    }

    /// Accepts `01:02:03,456`, `01:02:03.456` and `02:03.456`.
    static func parseTime(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let components = value.split(separator: ":").map(String.init)
        guard (2...3).contains(components.count) else { return nil }
        var seconds = 0.0
        for component in components {
            guard let number = Double(component) else { return nil }
            seconds = seconds * 60 + number
        }
        return seconds
    }

    static func format(_ time: TimeInterval, separator: String) -> String {
        let totalMilliseconds = Int((time * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = totalMilliseconds / 60_000 % 60
        let seconds = totalMilliseconds / 1000 % 60
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, separator, milliseconds)
    }

    public static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(format(cue.start, separator: ",")) --> \(format(cue.end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(format(cue.start, separator: ".")) --> \(format(cue.end, separator: "."))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    public static func plainText(_ cues: [SubtitleCue]) -> String {
        cues.map { $0.text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
            .joined(separator: "\n") + "\n"
    }

    public static func convert(_ source: URL, to format: ConversionFormat, output: URL) throws {
        let cues = parse(try DocumentConverter.readText(source))
        guard !cues.isEmpty else { throw YuzuError.unreadable(source.lastPathComponent) }
        let content: String
        switch format {
        case .srt: content = srt(cues)
        case .vtt: content = vtt(cues)
        case .txt: content = plainText(cues)
        default: throw YuzuError.unsupported("subtitles to \(format.displayName)")
        }
        try content.write(to: output, atomically: true, encoding: .utf8)
    }
}
