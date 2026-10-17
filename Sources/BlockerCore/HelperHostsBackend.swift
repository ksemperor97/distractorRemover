import Foundation

/// Side effects the controller needs. Calls block; the controller runs them off
/// the main thread.
public protocol HostsBackend: AnyObject {
    func readHosts() throws -> String
    /// Makes the managed section list exactly `domains` (removes it when empty).
    func write(domains: [String], allowPrompt: Bool) throws
    /// Replaces the whole hosts file after backing it up (manual editor).
    /// Returns the backup's location.
    func replaceHosts(with text: String) throws -> URL
}

/// Writes hosts only through `privileged_helper.sh`: silently via the installed
/// helper when password-free mode is on, otherwise by running the bundled copy
/// of the same script behind an administrator prompt.
public final class HelperHostsBackend: HostsBackend {
    public let hostsFile: URL
    public let scripts: HelperScripts
    public let backupDirectory: URL
    private let broker: PrivilegeBroker
    private let logger: AppLogger
    private let lock = NSLock()
    private var cachedStatus: HelperStatus?

    public init(hostsFile: URL, scripts: HelperScripts, backupDirectory: URL, broker: PrivilegeBroker, logger: AppLogger) {
        self.hostsFile = hostsFile
        self.scripts = scripts
        self.backupDirectory = backupDirectory
        self.broker = broker
        self.logger = logger
    }

    // MARK: Helper status (cached: checking runs sudo)

    public var helperStatus: HelperStatus {
        lock.lock()
        let cached = cachedStatus
        lock.unlock()
        return cached ?? refreshHelperStatus()
    }

    @discardableResult
    public func refreshHelperStatus() -> HelperStatus {
        let status = HelperStatus.from(version: broker.installedHelperVersion())
        lock.lock()
        cachedStatus = status
        lock.unlock()
        return status
    }

    public var bundledHelperVersion: String? { scripts.bundledVersion }

    // MARK: HostsBackend

    public func readHosts() throws -> String {
        do {
            return try String(contentsOf: hostsFile, encoding: .utf8)
        } catch {
            throw BlockerError.failed("Could not read \(hostsFile.path): \(error.localizedDescription)")
        }
    }

    public func write(domains: [String], allowPrompt: Bool) throws {
        guard domains.count <= AppConstants.maxDomains else {
            throw BlockerError.failed("Too many domains (\(domains.count)); the limit is \(AppConstants.maxDomains).")
        }
        if let invalid = domains.first(where: { !Domains.isValid($0) }) {
            throw BlockerError.failed("Refusing to write an invalid domain: \(invalid)")
        }
        let action = domains.isEmpty ? "--clear" : "--apply"

        if helperStatus.isUsable {
            let result = broker.runInstalledHelper(action, stdinLines: domains)
            guard result.succeeded else {
                refreshHelperStatus()
                if result.timedOut { throw BlockerError.failed("Password-free helper timed out.") }
                throw BlockerError.failed(result.message.isEmpty ? "helper failed" : result.message)
            }
            return
        }
        guard allowPrompt else {
            throw BlockerError.authorizationRequired(
                "Password-free mode is unavailable; automatic blocking cannot update hosts."
            )
        }
        let result = broker.runAsAdministrator(scripts.privilegedHelper, arguments: [action], stdinLines: domains)
        try check(result, fallback: "Failed to update the hosts file.")
    }

    public func replaceHosts(with text: String) throws -> URL {
        let backup = try HostsBackup.create(from: hostsFile, in: backupDirectory)
        let staged = backupDirectory.appendingPathComponent("hosts-edit-\(UUID().uuidString)")
        let content = text.hasSuffix("\n") ? text : text + "\n"
        try DurableFile.write(Data(content.utf8), to: staged, mode: 0o600)
        defer { try? FileManager.default.removeItem(at: staged) }
        try check(broker.replaceAsAdministrator(hostsFile, with: staged), fallback: "Could not save the hosts file.")
        logger.info("hosts file edited by hand; previous version backed up to \(backup.path)")
        return backup
    }

    // MARK: Password-free mode

    public func installHelper(forUser user: String) throws {
        guard !user.isEmpty, user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw BlockerError.failed("Refusing unsafe user name: \(user)")
        }
        let result = broker.runAsAdministrator(scripts.installer, arguments: [user], stdinLines: [])
        let status = refreshHelperStatus()
        if result.succeeded && status.isUsable {
            logger.info("password-free helper installed: \(status)")
            return
        }
        try check(result, fallback: "The helper was installed but did not pass its health check.")
        throw BlockerError.failed("The helper was installed but did not pass its health check.")
    }

    private func check(_ result: ProcessResult, fallback: String) throws {
        guard !result.succeeded else { return }
        if result.wasCancelled { throw BlockerError.cancelled }
        throw BlockerError.failed(result.message.isEmpty ? fallback : result.message)
    }
}
