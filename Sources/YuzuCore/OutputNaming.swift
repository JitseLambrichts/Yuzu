import Foundation

/// Kiest een vrije bestandsnaam naast het origineel, zodat er nooit iets overschreven wordt.
public enum OutputNaming {
    /// Basisnaam zonder extensie; `.tar.gz` telt als één extensie.
    public static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") {
            return String(name.dropLast(".tar.gz".count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    public static func uniqueURL(in directory: URL, baseName: String, fileExtension: String, fileManager: FileManager = .default) -> URL {
        func candidate(_ index: Int) -> URL {
            let name = index == 1 ? baseName : "\(baseName) \(index)"
            let file = fileExtension.isEmpty ? name : "\(name).\(fileExtension)"
            return directory.appendingPathComponent(file)
        }
        var index = 1
        while fileManager.fileExists(atPath: candidate(index).path) {
            index += 1
        }
        return candidate(index)
    }

    /// Uitvoer-URL naast `source`, optioneel met een achtervoegsel zoals "gecomprimeerd".
    public static func output(for source: URL, fileExtension: String, suffix: String? = nil, fileManager: FileManager = .default) -> URL {
        var base = baseName(of: source)
        if let suffix, !suffix.isEmpty { base += " \(suffix)" }
        return uniqueURL(in: source.deletingLastPathComponent(), baseName: base, fileExtension: fileExtension, fileManager: fileManager)
    }

    /// Een nieuwe, vrije map naast `source`.
    public static func folder(for source: URL, name: String, fileManager: FileManager = .default) throws -> URL {
        let url = uniqueURL(in: source.deletingLastPathComponent(), baseName: name, fileExtension: "", fileManager: fileManager)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
