import Foundation

/// ZIP/TAR/TAR.GZ maken en ZIP/TAR/GZ/RAR/7z uitpakken met de systeemtools (ditto, bsdtar, gzip).
public enum ArchiveConverter {
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")

    /// Archiveert één bestand of map (met de map zelf als bovenste niveau).
    public static func create(_ source: URL, format: ConversionFormat, output: URL) async throws {
        let parent = source.deletingLastPathComponent()
        switch format {
        case .zip:
            try await ProcessRunner.runChecked(ditto, ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, output.path])
        case .tar:
            try await ProcessRunner.runChecked(tar, ["-cf", output.path, "-C", parent.path, source.lastPathComponent])
        case .tgz:
            try await ProcessRunner.runChecked(tar, ["-czf", output.path, "-C", parent.path, source.lastPathComponent])
        default:
            throw YuzuError.unsupported("archief naar \(format.displayName)")
        }
    }

    /// Pakt de inhoud van een map in (zonder de map zelf als bovenste niveau).
    static func createFromContents(of folder: URL, format: ConversionFormat, output: URL) async throws {
        switch format {
        case .zip:
            try await ProcessRunner.runChecked(ditto, ["-c", "-k", "--sequesterRsrc", folder.path, output.path])
        case .tar:
            try await ProcessRunner.runChecked(tar, ["-cf", output.path, "-C", folder.path, "."])
        case .tgz:
            try await ProcessRunner.runChecked(tar, ["-czf", output.path, "-C", folder.path, "."])
        default:
            throw YuzuError.unsupported("archief naar \(format.displayName)")
        }
    }

    public static func extract(_ archive: URL, into destination: URL) async throws {
        let ext = SourceExtension.normalized(archive)
        switch ext {
        case "zip":
            try await ProcessRunner.runChecked(ditto, ["-x", "-k", archive.path, destination.path])
        case "gz" where !archive.lastPathComponent.lowercased().hasSuffix(".tar.gz"):
            // Een losse .gz bevat één bestand, geen tar-archief.
            let output = destination.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
            try await ProcessRunner.runChecked(gzip, ["-dc", archive.path], standardOutputFile: output)
        default:
            // bsdtar herkent tar, tar.gz, bz2, xz, rar en 7z automatisch.
            try await ProcessRunner.runChecked(tar, ["-xf", archive.path, "-C", destination.path])
        }
    }

    /// Pakt uit naar een nieuwe map naast het archief.
    public static func extractNextToSource(_ archive: URL) async throws -> URL {
        let folder = try OutputNaming.folder(for: archive, name: OutputNaming.baseName(of: archive))
        do {
            try await extract(archive, into: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    public static func convert(_ source: URL, to format: ConversionFormat, output: URL) async throws {
        if FileCategory.of(source) == .folder {
            try await create(source, format: format, output: output)
            return
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await extract(source, into: temporary)
        try await createFromContents(of: temporary, format: format, output: output)
    }
}
