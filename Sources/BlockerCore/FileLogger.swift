import Foundation

public protocol AppLogger: AnyObject {
    func log(_ level: LogLevel, _ message: String)
}

public enum LogLevel: String {
    case info = "INFO", warning = "WARNING", error = "ERROR"
}

public extension AppLogger {
    func info(_ message: String) { log(.info, message) }
    func warning(_ message: String) { log(.warning, message) }
    func error(_ message: String) { log(.error, message) }
}

/// Size-rotated log file (`app.log`, `app.log.1`, `app.log.2`).
public final class FileLogger: AppLogger {
    private let url: URL
    private let maxBytes: Int
    private let backups: Int
    private let lock = NSLock()
    private let formatter: DateFormatter

    public init(url: URL, maxBytes: Int = 512_000, backups: Int = 2) {
        self.url = url
        self.maxBytes = maxBytes
        self.backups = backups
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    public func log(_ level: LogLevel, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level.rawValue) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        rotateIfNeeded(adding: line.utf8.count)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func rotateIfNeeded(adding count: Int) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size + count > maxBytes, size > 0 else { return }
        let fm = FileManager.default
        try? fm.removeItem(atPath: "\(url.path).\(backups)")
        if backups > 1 {
            for index in stride(from: backups - 1, through: 1, by: -1) {
                try? fm.moveItem(atPath: "\(url.path).\(index)", toPath: "\(url.path).\(index + 1)")
            }
        }
        try? fm.moveItem(atPath: url.path, toPath: "\(url.path).1")
    }
}

public final class NullLogger: AppLogger {
    public init() {}
    public func log(_ level: LogLevel, _ message: String) {}
}
