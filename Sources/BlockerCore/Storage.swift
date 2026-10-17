import Foundation

public struct StorageError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
    static func posix(_ what: String, _ path: String) -> StorageError {
        StorageError("\(what) \(path): \(String(cString: strerror(errno)))")
    }
}

/// Crash-safe writes: temp file → fsync → rename → fsync directory.
public enum DurableFile {
    public static func write(_ data: Data, to url: URL, mode: mode_t = 0o644) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = url.path + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw StorageError.posix("Could not create", tmp) }
        do {
            try writeAll(fd, data, path: tmp)
            guard fsync(fd) == 0 else { throw StorageError.posix("Could not flush", tmp) }
            close(fd)
            guard rename(tmp, url.path) == 0 else { throw StorageError.posix("Could not replace", url.path) }
        } catch {
            close(fd)
            unlink(tmp)
            throw error
        }
        let dirFD = open(directory.path, O_RDONLY)
        if dirFD >= 0 {
            fsync(dirFD)
            close(dirFD)
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw StorageError.posix("Could not write", path)
                }
                offset += written
            }
        }
    }
}

public protocol ConfigStoring: AnyObject {
    /// Returns defaults when no file exists; throws `ConfigLoadError` otherwise.
    func load() throws -> Config
    func save(_ config: Config) throws
    /// Moves a damaged file aside and writes defaults. Restores it on failure.
    func quarantineAndReset() throws -> (Config, URL)
}

public final class FileConfigStore: ConfigStoring {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return Config()
        } catch {
            throw ConfigLoadError("The configuration file could not be read and was left unchanged: \(error.localizedDescription)")
        }
        return try ConfigCodec.decode(data)
    }

    public func save(_ config: Config) throws {
        try DurableFile.write(ConfigCodec.encode(config), to: url)
    }

    public func quarantineAndReset() throws -> (Config, URL) {
        let backup = URL(fileURLWithPath: "\(url.path).corrupt-\(Timestamp.fileStamp())")
        try FileManager.default.moveItem(at: url, to: backup)
        let config = Config()
        do {
            try save(config)
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(at: backup, to: url)
            throw error
        }
        return (config, backup)
    }
}

enum Timestamp {
    static func fileStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSSSSS"
        return formatter.string(from: date)
    }

    static func iso(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

/// Byte-for-byte private copy of the hosts file before direct editing.
public enum HostsBackup {
    public static func create(from source: URL, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw StorageError("The hosts backup path is not a private directory.")
        }
        chmod(directory.path, 0o700)
        let destination = directory.appendingPathComponent("hosts-\(Timestamp.fileStamp()).backup")
        let contents = try Data(contentsOf: source)
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StorageError.posix("Could not create", destination.path) }
        defer { close(fd) }
        do {
            try DurableFile.writeAll(fd, contents, path: destination.path)
            fsync(fd)
        } catch {
            unlink(destination.path)
            throw error
        }
        return destination
    }
}

/// Holds an exclusive `flock` for the life of the process.
public final class InstanceLock {
    private let fd: Int32

    public init?(url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit { close(fd) }
}

/// Snapshot used by Status & Repair and support. Written only when it changes.
public struct RuntimeStatus: Equatable {
    public var version: String
    public var applyStatus: String
    public var desiredBlocking: Bool
    public var actualBlocking: Bool
    public var retryCount: Int
    public var lastError: String
    public var configRecoveryRequired: Bool

    func json(updatedAt: Date) throws -> Data {
        let dict: [String: Any] = [
            "version": version,
            "updated_at": Timestamp.iso(updatedAt),
            "apply_status": applyStatus,
            "desired_blocking": desiredBlocking,
            "actual_blocking": actualBlocking,
            "retry_count": retryCount,
            "last_error": lastError,
            "config_recovery_required": configRecoveryRequired,
        ]
        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }
}

public final class RuntimeStatusWriter {
    private let url: URL
    private var last: RuntimeStatus?

    public init(url: URL) { self.url = url }

    public func record(_ status: RuntimeStatus) throws {
        guard status != last else { return }
        try DurableFile.write(status.json(updatedAt: Date()), to: url)
        last = status
    }
}
