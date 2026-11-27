import Foundation

nonisolated enum LenverLocale {
    static var selected: Locale {
        forLanguage(Bundle.main.preferredLocalizations.first ?? "en")
    }

    static func forLanguage(_ language: String) -> Locale {
        Locale(identifier: language.lowercased().hasPrefix("pt") ? "pt_BR" : "en_US")
    }
}
