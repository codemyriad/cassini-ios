import Foundation

/// The title and file name an imported file gets (Android `ImportRepository.titleOf` / `extensionOf`).
public enum ImportTitles {
    /// The English title of a file without a usable name; the app passes its localized copy.
    public static let fallbackTitle = "Imported audio"

    /// Extensions that name a container the import reads itself, or the staging file: a file named so gets the
    /// extension of what it is instead.
    static let reserved: Set<String> = ["opus", "wav", "tmp"]

    /// The note title from a display name: the name without its last extension, trimmed and cut to 200 characters;
    /// `fallback` when nothing is left. A name that is only an extension (`.opus`) is kept whole.
    public static func title(displayName: String?, fallback: String = fallbackTitle) -> String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var stem = name
        if let dot = name.lastIndex(of: ".") { stem = String(name[..<dot]) }
        if stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { stem = name }
        return NoteTitles.fit(stem) ?? fallback
    }

    /// The extension of an imported `source.*` file: the display name's when it is `[a-z0-9]{1,5}` and not reserved,
    /// else the one the content names, else `bin`.
    public static func fileExtension(displayName: String?, content: String?) -> String {
        if let name = displayName, let dot = name.lastIndex(of: ".") {
            let candidate = name[name.index(after: dot)...].lowercased()
            let valid = (1...5).contains(candidate.unicodeScalars.count)
                && candidate.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            if valid && !reserved.contains(candidate) { return candidate }
        }
        return content ?? "bin"
    }
}
