import Foundation

/// Converteert een selectie met beperkte parallelliteit en één gecombineerde voortgang.
public enum BatchConverter {
    public static func convert(_ urls: [URL], to format: ConversionFormat, settings: ConversionSettings,
                               maxConcurrent: Int = 3,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ToolResult {
        let tracker = ProgressTracker(count: urls.count, report: progress)
        var outputs: [URL] = []
        var failures: [(URL, Error)] = []

        try await withThrowingTaskGroup(of: (Int, Result<[URL], Error>).self) { group in
            var next = 0
            func addNext() {
                guard next < urls.count else { return }
                let index = next
                let url = urls[index]
                next += 1
                group.addTask {
                    do {
                        let result = try await ConversionEngine.convert(url, to: format, settings: settings) { value in
                            tracker.update(index, value)
                        }
                        tracker.update(index, 1)
                        return (index, .success(result))
                    } catch {
                        tracker.update(index, 1)
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<min(maxConcurrent, urls.count) { addNext() }
            while let (index, result) = try await group.next() {
                switch result {
                case .success(let urls): outputs += urls
                case .failure(let error): failures.append((urls[index], error))
                }
                addNext()
            }
        }
        try Task.checkCancellation()

        if failures.count == urls.count, let first = failures.first {
            throw first.1
        }
        if !failures.isEmpty {
            let names = failures.map { $0.0.lastPathComponent }.joined(separator: ", ")
            throw YuzuError.nothingToDo("\(outputs.count) gelukt, mislukt: \(names) (\(failures[0].1.localizedDescription))")
        }
        return ToolResult(outputs: outputs)
    }
}

final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double]
    private let report: @Sendable (Double) -> Void

    init(count: Int, report: @escaping @Sendable (Double) -> Void) {
        values = Array(repeating: 0, count: max(count, 1))
        self.report = report
    }

    func update(_ index: Int, _ value: Double) {
        lock.lock()
        values[index] = max(values[index], value)
        let total = values.reduce(0, +) / Double(values.count)
        lock.unlock()
        report(total)
    }
}
