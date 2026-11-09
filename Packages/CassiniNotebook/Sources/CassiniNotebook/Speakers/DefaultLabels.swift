import Foundation

/// An unnamed speaker's label, and whether a label is still one rather than a name. The label is written in the
/// user's language when the transcript is produced, and every reader shows it as stored (D47). Notes store only the
/// label text, so telling a placeholder from a name is a scan over the placeholders of every language a note may come
/// from: Cassini's apps on any platform write the glossary's "Speaker {n}".
public enum DefaultLabels {
    /// The word of "Speaker {n}" in each of the app's languages (the coordination glossary, D50).
    public static let words = ["en": "Speaker", "it": "Voce", "fr": "Intervenant", "es": "Hablante", "pt-BR": "Locutor",
                               "pt-PT": "Orador"]

    /// The placeholder up to its number, in every language a note may hold.
    public static let prefixes = words.values.sorted().map { $0 + " " }

    /// The app's language: the localization the system chose for it (`Bundle.main`).
    public static var appLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The label Cassini writes for the `number`th speaker (from 1) in `language`: "Speaker 3", "Intervenant 3";
    /// English in a language the app does not have.
    public static func placeholder(_ number: Int, language: String = appLanguage) -> String {
        "\(words[language] ?? "Speaker") \(number)"
    }

    /// The same unknown-speaker copy as the Note catalog, available to pure projections (chips/previews).
    public static func unknown(language: String = appLanguage) -> String {
        switch language {
        case "it": "Voce sconosciuta"
        case "fr": "Intervenant inconnu"
        case "es": "Hablante desconocido"
        case "pt-BR": "Locutor desconhecido"
        case "pt-PT": "Orador desconhecido"
        default: "Unknown speaker"
        }
    }

    /// True for the speaker id itself, a blank label, or a placeholder prefix followed by a number.
    public static func isDefault(id: String, label: String) -> Bool {
        label == id || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || placeholderNumber(label) != nil
    }

    /// N of "Speaker N", or nil when `label` is no placeholder.
    public static func placeholderNumber(_ label: String) -> Int? {
        for prefix in prefixes where label.hasPrefix(prefix) {
            let rest = label.dropFirst(prefix.count)
            if !rest.isEmpty, rest.allSatisfy(\.isASCII), let number = Int(rest) { return number }
        }
        return nil
    }
}
