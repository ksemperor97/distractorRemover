import Foundation

/// The user's language choice. `system` follows macOS (Korean if Korean is the
/// first preferred language, otherwise English).
public enum LanguagePreference: String, CaseIterable {
    case system, korean = "ko", english = "en"
}

public enum Language: Equatable {
    case english, korean

    public static func resolve(_ preference: LanguagePreference,
                               preferredLanguages: [String] = Locale.preferredLanguages) -> Language {
        switch preference {
        case .korean: return .korean
        case .english: return .english
        case .system: return preferredLanguages.first?.hasPrefix("ko") == true ? .korean : .english
        }
    }
}

/// Holds the current language. Strings are picked when shown, so a change
/// applies to the next menu, dialog or window without restarting.
public final class Localizer {
    public static let shared = Localizer()
    private static let key = "language"
    private let defaults: UserDefaults
    /// When set (sandbox mode), the choice lives in this file instead of the
    /// app's preferences, so trying things out never changes the real app.
    private var file: URL?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func storePreference(in file: URL) {
        self.file = file
    }

    public var preference: LanguagePreference {
        get {
            let raw = file.map { (try? String(contentsOf: $0, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) } ?? defaults.string(forKey: Self.key)
            return raw.flatMap(LanguagePreference.init(rawValue:)) ?? .system
        }
        set {
            if let file {
                try? newValue.rawValue.write(to: file, atomically: true, encoding: .utf8)
            } else {
                defaults.set(newValue.rawValue, forKey: Self.key)
            }
        }
    }

    public var language: Language { Language.resolve(preference) }
}

/// Picks the English or Korean text for the current language.
public func L(_ english: String, _ korean: String) -> String {
    Localizer.shared.language == .korean ? korean : english
}
