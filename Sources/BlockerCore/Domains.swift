import Foundation

public struct ServicePreset {
    public let site: String
    public let label: String
    public let domains: [String]
}

/// Hosts files cannot express wildcards. These deliberately small presets cover
/// alternate entry points without blocking broad CDNs shared by other services.
public enum Domains {
    public static let presets: [ServicePreset] = [
        ServicePreset(site: "youtube.com", label: "YouTube", domains: [
            "youtube.com", "www.youtube.com", "m.youtube.com",
            "music.youtube.com", "studio.youtube.com", "youtu.be",
        ]),
        ServicePreset(site: "instagram.com", label: "Instagram", domains: [
            "instagram.com", "www.instagram.com", "m.instagram.com",
        ]),
        ServicePreset(site: "x.com", label: "X / Twitter", domains: [
            "x.com", "www.x.com", "mobile.x.com", "twitter.com",
            "www.twitter.com", "mobile.twitter.com",
        ]),
        ServicePreset(site: "reddit.com", label: "Reddit", domains: [
            "reddit.com", "www.reddit.com", "old.reddit.com",
            "new.reddit.com", "np.reddit.com", "redd.it",
        ]),
        ServicePreset(site: "tiktok.com", label: "TikTok", domains: [
            "tiktok.com", "www.tiktok.com", "m.tiktok.com",
        ]),
        ServicePreset(site: "facebook.com", label: "Facebook", domains: [
            "facebook.com", "www.facebook.com", "m.facebook.com",
        ]),
    ]

    private static let presetBySite: [String: ServicePreset] =
        Dictionary(uniqueKeysWithValues: presets.map { ($0.site, $0) })

    private static let aliases: [String: String] = {
        var map: [String: String] = [:]
        for preset in presets {
            for domain in preset.domains { map[domain] = preset.site }
        }
        return map
    }()

    private static let domainPattern = try! NSRegularExpression(
        pattern: "^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+"
            + "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
    )
    private static let schemePattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9+.-]*://")

    public static func isValid(_ domain: String) -> Bool {
        let range = NSRange(domain.startIndex..., in: domain)
        return domainPattern.firstMatch(in: domain, range: range) != nil
    }

    /// `"https://www.YouTube.com/feed"` → `"youtube.com"`; `nil` if not a domain.
    public static func normalize(_ raw: String) -> String? {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        d = schemePattern.stringByReplacingMatches(
            in: d, range: NSRange(d.startIndex..., in: d), withTemplate: ""
        )
        d = String(d.split(separator: "/", omittingEmptySubsequences: false).first ?? "")
        d = String(d.split(separator: "?", omittingEmptySubsequences: false).first ?? "")
        d = String(d.split(separator: "#", omittingEmptySubsequences: false).first ?? "")
        d = String(d.split(separator: "@", omittingEmptySubsequences: false).last ?? "")
        d = String(d.split(separator: ":", omittingEmptySubsequences: false).first ?? "")
        if d.hasPrefix("www.") { d.removeFirst(4) }
        d = d.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !d.isEmpty else { return nil }
        // URLComponents applies UTS #46 mapping and Punycode for IDNs.
        var components = URLComponents()
        components.host = d
        guard let encoded = components.encodedHost?.lowercased(), isValid(encoded) else {
            return nil
        }
        return encoded
    }

    public static func canonicalSite(_ domain: String) -> String {
        aliases[domain] ?? domain
    }

    public static func preset(for site: String) -> ServicePreset? {
        presetBySite[site]
    }

    /// The exact hosts represented by user-visible site entries, in order.
    public static func expanded(_ sites: [String]) -> [String] {
        var seen = Set<String>()
        var domains: [String] = []
        for raw in sites {
            let site = canonicalSite(raw)
            let candidates = presetBySite[site]?.domains ?? [site, "www.\(site)"]
            for domain in candidates where seen.insert(domain).inserted {
                domains.append(domain)
            }
        }
        return domains
    }

    public static func displayName(_ site: String) -> String {
        guard let preset = presetBySite[site] else { return site }
        return "\(preset.label) — \(site) (\(preset.domains.count) domains)"
    }

    /// Normalizes, canonicalizes and de-duplicates entries while keeping order.
    public static func canonicalList(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        var sites: [String] = []
        for entry in entries {
            guard let domain = normalize(entry) else { continue }
            let site = canonicalSite(domain)
            if seen.insert(site).inserted { sites.append(site) }
        }
        return sites
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Parses one domain or URL per line, or `127.0.0.1`/`::1` lines copied from hosts.
    public static func parseSiteList(_ text: String) throws -> [String] {
        var seen = Set<String>()
        var sites: [String] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            let line = String(rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first ?? "").trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let candidates: [String]
            if tokens[0] == "127.0.0.1" || tokens[0] == "::1" {
                candidates = Array(tokens.dropFirst())
            } else if tokens.count == 1 {
                candidates = tokens
            } else {
                candidates = []
            }
            if candidates.isEmpty {
                let shown = rawLine.trimmingCharacters(in: .whitespaces)
                throw ParseError(description: "Invalid entry on line \(lineNumber): \(shown.isEmpty ? "(empty)" : shown)")
            }
            for candidate in candidates {
                guard let domain = normalize(candidate) else {
                    throw ParseError(description: "Invalid domain on line \(lineNumber): \(candidate)")
                }
                let site = canonicalSite(domain)
                if seen.insert(site).inserted { sites.append(site) }
            }
        }
        return sites
    }
}
