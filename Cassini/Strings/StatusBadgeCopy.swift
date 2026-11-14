import Foundation
import CassiniNotebook

/// Catalog access shared by future badge consumers; the interface language selects the resource bundle.
enum StatusBadgeCopy {
    static func template(_ id: String, language: String = DefaultLabels.appLanguage) -> String {
        let selected = Bundle.preferredLocalizations(from: Bundle.main.localizations,
            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"
        let bundle = Bundle.main.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
        return StatusBadgeStrings.template(id, bundle: bundle, locale: Locale(identifier: language))
    }
}
