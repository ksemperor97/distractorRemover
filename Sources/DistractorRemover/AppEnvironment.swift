import BlockerCore
import Foundation

/// Where things live for this run. `DISTRACTORREMOVER_SANDBOX=<dir>` redirects
/// the support directory and hosts file to `<dir>` and runs the helper scripts
/// unprivileged against that scratch hosts file — handy for development, demos
/// and screenshots without touching `/etc/hosts`.
struct AppEnvironment {
    let paths: AppPaths
    let scripts: HelperScripts
    let broker: PrivilegeBroker
    let version: String
    /// `DISTRACTORREMOVER_DEBUG_SHOW`: open a UI surface at launch (menu,
    /// schedule-editor, block-list, status) for screenshots.
    let debugShow: String?

    static func make() -> AppEnvironment {
        let env = ProcessInfo.processInfo.environment
        let scripts = HelperScripts(directory: resourceDirectory(env))
        let debugShow = env["DISTRACTORREMOVER_DEBUG_SHOW"].flatMap { $0.isEmpty ? nil : $0 }

        if let sandbox = env["DISTRACTORREMOVER_SANDBOX"], !sandbox.isEmpty {
            let paths = AppPaths.sandbox(root: URL(fileURLWithPath: sandbox, isDirectory: true))
            let fm = FileManager.default
            try? fm.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: paths.hostsFile.path) {
                try? "127.0.0.1\tlocalhost\n::1\tlocalhost\n".write(to: paths.hostsFile, atomically: true, encoding: .utf8)
            }
            let broker = SandboxPrivilegeBroker(
                hostsFile: paths.hostsFile, scripts: scripts, stateDirectory: paths.supportDirectory
            )
            if env["DISTRACTORREMOVER_SANDBOX_PROMPT"] == "cancel" { broker.promptResponse = .cancel }
            return AppEnvironment(paths: paths, scripts: scripts, broker: broker, version: version(), debugShow: debugShow)
        }
        return AppEnvironment(
            paths: .standard(), scripts: scripts, broker: SystemPrivilegeBroker(),
            version: version(), debugShow: debugShow
        )
    }

    /// The app bundle's Resources, else the repository's `helper/` (swift run).
    private static func resourceDirectory(_ env: [String: String]) -> URL {
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("privileged_helper.sh").path) {
            return resources
        }
        if let override = env["DISTRACTORREMOVER_RESOURCES"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return repositoryRoot.appendingPathComponent("helper", isDirectory: true)
    }

    private static func version() -> String {
        if let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !short.isEmpty {
            return short
        }
        let file = repositoryRoot.appendingPathComponent("VERSION")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "development"
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DistractorRemover
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()
    }
}
