import Foundation

/// Stateless localization helper backed by Xcode String Catalogs.
/// Strictly restricts supported languages to the 8-language allowlist (no `ja`)
/// and falls back to `"en"` for any unsupported system language.
public enum AppLocalization {
    public static let supportedLanguageCodes: [String] = [
        "en",
        "zh-Hans",
        "zh-Hant",
        "ko",
        "ru",
        "es",
        "fr",
        "de",
    ]

    public static let autonyms: [String: String] = [
        "en": "English",
        "zh-Hans": "简体中文",
        "zh-Hant": "繁體中文",
        "ko": "한국어",
        "ru": "Русский",
        "es": "Español",
        "fr": "Français",
        "de": "Deutsch",
    ]

    private static let singleSubtagLanguages: Set<String> = [
        "en",
        "ko",
        "ru",
        "es",
        "fr",
        "de",
    ]

    public static func resolveLanguageCode(
        preferredLocalizations: [String] = Bundle.main.preferredLocalizations
    ) -> String {
        guard let rawFirst = preferredLocalizations.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return "en"
        }

        let normalized = rawFirst
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        let subtags = normalized.split(separator: "-").map(String.init)
        guard let primary = subtags.first else {
            return "en"
        }

        if primary == "zh" {
            let remaining = Set(subtags.dropFirst())
            if remaining.contains("hant")
                || remaining.contains("tw")
                || remaining.contains("hk")
                || remaining.contains("mo")
            {
                return "zh-Hant"
            }
            return "zh-Hans"
        }

        if singleSubtagLanguages.contains(primary) {
            return primary
        }

        return "en"
    }

    public static var effectiveLanguageCode: String {
        resolveLanguageCode()
    }

    public static var effectiveLocale: Locale {
        Locale(identifier: effectiveLanguageCode)
    }

    public static var effectiveLanguageAutonym: String {
        autonyms[effectiveLanguageCode] ?? "English"
    }

    public static func localized(
        _ key: String.LocalizationValue,
        locale: Locale = effectiveLocale
    ) -> String {
        String(localized: LocalizedStringResource(key, locale: locale, bundle: .main))
    }
}
