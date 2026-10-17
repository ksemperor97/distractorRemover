import Foundation

/// Reads the app-managed section of a hosts file.
///
/// Only `privileged_helper.sh` ever writes hosts. The app never renders a full
/// hosts file; it only checks whether the helper's result is the requested
/// state, which keeps a single writer for both the silent and the prompt path.
public enum HostsFile {
    public struct Inspection: Equatable {
        public var startMarkers = 0
        public var endMarkers = 0
        /// Lines between the first start marker and the following end marker.
        public var sectionLines: [String] = []
        /// Every START is closed by an END before the next START. Equal counts
        /// alone are not enough: reversed or nested markers have no safe boundary.
        public var isWellFormed = true

        public var hasSection: Bool { startMarkers > 0 }
    }

    public static func inspect(_ content: String) -> Inspection {
        var result = Inspection()
        var inside = false
        var capturing = false
        var capturedFirst = false
        for line in content.components(separatedBy: "\n") {
            if line == AppConstants.markStart {
                result.startMarkers += 1
                if inside { result.isWellFormed = false }
                inside = true
                capturing = !capturedFirst
                continue
            }
            if line == AppConstants.markEnd {
                result.endMarkers += 1
                if !inside { result.isWellFormed = false }
                if capturing { capturedFirst = true }
                inside = false
                capturing = false
                continue
            }
            if capturing { result.sectionLines.append(line) }
        }
        if inside { result.isWellFormed = false }
        return result
    }

    /// The body lines the helper writes for `domains` (markers excluded).
    public static func sectionBody(for domains: [String]) -> [String] {
        domains.flatMap { ["127.0.0.1\t\($0)", "::1\t\($0)"] }
    }

    /// True when `content` is exactly the requested state: no managed section
    /// for an empty list, otherwise one complete section listing `domains`.
    public static func matches(_ content: String, domains: [String]) -> Bool {
        let inspection = inspect(content)
        guard inspection.isWellFormed else { return false }
        if domains.isEmpty {
            return inspection.startMarkers == 0 && inspection.endMarkers == 0
        }
        return inspection.startMarkers == 1
            && inspection.endMarkers == 1
            && inspection.sectionLines == sectionBody(for: domains)
    }

    public static func isBlocking(_ content: String) -> Bool {
        inspect(content).hasSection
    }
}
