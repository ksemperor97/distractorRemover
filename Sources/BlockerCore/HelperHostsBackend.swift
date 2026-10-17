import Foundation

/// Side effects the controller needs. Calls block; the controller runs them off
/// the main thread.
public protocol HostsBackend: AnyObject {
    func readHosts() throws -> String
    /// Makes the managed section list exactly `domains` (removes it when empty).
    func write(domains: [String], allowPrompt: Bool) throws
    /// Backs up hosts and removes every managed marker, even an incomplete one.
    func resetManagedSection(allowPrompt: Bool) throws -> String
}

/// Writes hosts only through `privileged_helper.sh`: silently via the installed
/// helper when password-free mode is on, otherwise by running the bundled copy
/// of the same script behind an administrator prompt.
public final class HelperHostsBackend: HostsBackend {
    public let hostsFile: URL
    public let scripts: HelperScripts
    private let broker: PrivilegeBroker
    private let logger: AppLogger
    private let lock = NSLock()
    private var cachedStatus: HelperStatus?

    public init(hostsFile: URL, scripts: HelperScripts, broker: PrivilegeBroker, logger: AppLogger) {
        self.hostsFile = hostsFile
        self.scripts = scripts
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

    /// An older compatible helper works but lacks backup-based `--reset`.
    public var helperNeedsUpgrade: Bool {
        guard case .ready(let version) = helperStatus, let bundled = bundledHelperVersion else { return false }
        return version != bundled
    }

    public var helperDiagnostic: String {
        switch helperStatus {
        case .notInstalled: return "not ready"
        case .unsupported(let version): return "unsupported v\(version)"
        case .ready(let version):
            guard let bundled = bundledHelperVersion, version != bundled else { return "ready v\(version)" }
            return "ready v\(version); v\(bundled) recovery upgrade available"
        }
    }

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

    public func resetManagedSection(allowPrompt: Bool) throws -> String {
        let result: ProcessResult
        if case .ready(let version) = helperStatus, version == bundledHelperVersion {
            result = broker.runInstalledHelper("--reset", stdinLines: [])
            if result.timedOut { throw BlockerError.failed("Password-free helper timed out during reset.") }
        } else {
            guard allowPrompt else {
                throw BlockerError.authorizationRequired("Administrator approval is required to reset the hosts section.")
            }
            result = broker.runAsAdministrator(scripts.privilegedHelper, arguments: ["--reset"], stdinLines: [])
        }
        try check(result, fallback: "Could not reset the managed hosts section.")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Password-free mode

    public func installHelper(forUser user: String) throws {
        guard !user.isEmpty, user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw BlockerError.failed("Refusing unsafe user name: \(user)")
        }
        let result = broker.runAsAdministrator(scripts.installer, arguments: [user], stdinLines: [])
        let status = refreshHelperStatus()
        if result.succeeded && status.isUsable {
            logger.info("password-free helper installed: \(helperDiagnostic)")
            return
        }
        try check(result, fallback: "The helper was installed but did not pass its health check.")
        throw BlockerError.failed("The helper was installed but did not pass its health check.")
    }

    public func uninstallHelper() throws {
        let result = broker.runAsAdministrator(scripts.uninstaller, arguments: [], stdinLines: [])
        refreshHelperStatus()
        try check(result, fallback: "Could not remove the helper.")
        logger.info("password-free helper removed")
    }

    private func check(_ result: ProcessResult, fallback: String) throws {
        guard !result.succeeded else { return }
        if result.wasCancelled { throw BlockerError.cancelled }
        throw BlockerError.failed(result.message.isEmpty ? fallback : result.message)
    }
}
