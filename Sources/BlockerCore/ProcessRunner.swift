import Foundation

public struct ProcessResult {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut = false

    public var succeeded: Bool { status == 0 && !timedOut }
    /// stderr, else stdout, trimmed.
    public var message: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : err
    }
    /// osascript reports a dismissed authorization dialog as error -128.
    public var wasCancelled: Bool {
        let text = message.lowercased()
        return text.contains("-128") || text.contains("cancel")
    }
}

public enum ProcessRunner {
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Runs a program synchronously. Call off the main thread.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        stdin: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input

        // Drain both pipes concurrently so a chatty child cannot block on a full pipe.
        let output = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            output.set(stdout: out.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            output.set(stderr: err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        // terminationHandler does not depend on a run loop, unlike
        // waitUntilExit(), which can miss the exit on a GCD worker thread.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            group.wait()
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        if let stdin, let data = stdin.data(using: .utf8) {
            // A child that exits without reading must not kill us with SIGPIPE.
            _ = ignoreSigpipe
            try? input.fileHandleForWriting.write(contentsOf: data)
        }
        try? input.fileHandleForWriting.close()

        var timedOut = false
        if let timeout {
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                if finished.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    finished.wait()
                }
            }
        } else {
            finished.wait()
        }
        // A grandchild that inherited the pipes could keep them open; don't hang on it.
        _ = group.wait(timeout: .now() + 5)
        let (stdoutData, stderrData) = output.get()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            timedOut: timedOut
        )
    }

    private final class OutputBox {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()

        func set(stdout data: Data) { lock.lock(); stdout = data; lock.unlock() }
        func set(stderr data: Data) { lock.lock(); stderr = data; lock.unlock() }
        func get() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (stdout, stderr) }
    }

    /// POSIX shell single-quoting.
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript string literal.
    public static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
