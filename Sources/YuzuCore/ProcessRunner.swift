import Foundation

public enum YuzuError: LocalizedError, Equatable {
    case unsupported(String)
    case missingTool(String)
    case processFailed(tool: String, message: String)
    case unreadable(String)
    case writeFailed(String)
    case nothingToDo(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail): return "Not supported: \(detail)"
        case .missingTool(let tool): return "\(tool) was not found. Install it with Homebrew (brew install \(tool)) or put it in Yuzu.app/Contents/Resources/Tools."
        case .processFailed(let tool, let message): return "\(tool) failed: \(message)"
        case .unreadable(let name): return "Couldn't read \(name)."
        case .writeFailed(let name): return "Couldn't write \(name)."
        case .nothingToDo(let detail): return detail
        }
    }
}

/// Finds external helper tools: first in the app bundle, then in the usual Homebrew paths.
public enum ToolLocator {
    public static func find(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Tools/\(name)"))
        }
        candidates += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map {
            URL(fileURLWithPath: $0).appendingPathComponent(name)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func require(_ name: String) throws -> URL {
        guard let url = find(name) else { throw YuzuError.missingTool(name) }
        return url
    }
}

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

/// Collects pipe output in a thread-safe way and optionally splits it into lines.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = Data()
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        var lines: [String] = []
        if onLine != nil {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                lines.append(String(decoding: line, as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum ProcessRunner {
    /// Starts a process and waits asynchronously for it to finish. Cancelling the Task terminates the process.
    @discardableResult
    public static func run(_ executable: URL,
                           _ arguments: [String],
                           currentDirectory: URL? = nil,
                           standardOutputFile: URL? = nil,
                           onStdoutLine: ((String) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let stdout = OutputCollector(onLine: onStdoutLine)
        let stderr = OutputCollector(onLine: nil)
        let errPipe = Pipe()
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

        let outFile: FileHandle? = try standardOutputFile.map { url in
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return try FileHandle(forWritingTo: url)
        }
        let outPipe: Pipe? = outFile == nil ? Pipe() : nil
        if let outFile {
            process.standardOutput = outFile
        } else if let outPipe {
            process.standardOutput = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { finished in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    stderr.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    if let outPipe {
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        stdout.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                    try? outFile?.close()
                    continuation.resume(returning: ProcessResult(status: finished.terminationStatus,
                                                                 stdout: stdout.string,
                                                                 stderr: stderr.string))
                }
                do {
                    try process.run()
                } catch {
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outPipe?.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Like `run`, but throws when the exit status is not 0.
    @discardableResult
    public static func runChecked(_ executable: URL,
                                  _ arguments: [String],
                                  currentDirectory: URL? = nil,
                                  standardOutputFile: URL? = nil,
                                  onStdoutLine: ((String) -> Void)? = nil) async throws -> ProcessResult {
        let result = try await run(executable, arguments, currentDirectory: currentDirectory,
                                   standardOutputFile: standardOutputFile, onStdoutLine: onStdoutLine)
        try Task.checkCancellation()
        guard result.status == 0 else {
            let lastLines = result.stderr.split(separator: "\n").suffix(3).joined(separator: " ")
            throw YuzuError.processFailed(tool: executable.lastPathComponent,
                                          message: lastLines.isEmpty ? "exit status \(result.status)" : lastLines)
        }
        return result
    }
}
