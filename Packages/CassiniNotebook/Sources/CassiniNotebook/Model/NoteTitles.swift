import Foundation

/// The rules of a note title.
public enum NoteTitles {
    public static let maxLength = Limits.titleMaxLength

    /// A title the user typed, trimmed; nil when that is blank or longer than `maxLength`.
    public static func clean(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > maxLength ? nil : trimmed
    }

    /// A title taken from elsewhere (a field without a length limit, a file name): trimmed and cut to `maxLength`;
    /// nil when nothing is left.
    public static func fit(_ input: String?) -> String? {
        guard let input else { return nil }
        let fitted = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fitted.isEmpty ? nil : fitted
    }
}
