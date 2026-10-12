import Foundation

/// Whether a speaker label is still a placeholder rather than a name. Notes store only the label text, so this is a
/// scan over every placeholder Cassini has written: "Speaker N" (and Android's Italian "Voce N", which portable
/// documents may carry).
public enum DefaultLabels {
    /// The placeholder up to its number, in every language a note may hold.
    public static let prefixes = ["Speaker ", "Voce "]

    /// The label Cassini writes for the `number`th speaker of an analysis (from 1).
    public static func placeholder(_ number: Int) -> String { "Speaker \(number)" }

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
