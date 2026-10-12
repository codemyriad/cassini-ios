/// File names for saved copies and exports (features.md section 9).
public enum ExportNames {
    /// The longest name before the extension, in UTF-16 units.
    public static let maxLength = 100

    /// The name used when the title leaves nothing.
    public static let fallback = "Cassini note"

    private static let forbidden: Set<Unicode.Scalar> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

    /// A file name for `title` with extension `ext` (without the dot).
    public static func file(_ title: String, ext: String) -> String { stem(title) + "." + ext }

    /// The name before the extension: `/ \ : * ? " < > |` and control characters become `_`, whitespace runs become
    /// one space, dots and spaces are trimmed at both ends, and the name is cut to `maxLength` UTF-16 units, never
    /// inside a surrogate pair (then trimmed again). A name with nothing left is `fallback`.
    public static func stem(_ title: String) -> String {
        var replaced = String.UnicodeScalarView()
        var space = false
        for scalar in title.unicodeScalars {
            if forbidden.contains(scalar) || isControl(scalar) {
                replaced.append("_"); space = false
            } else if isSpace(scalar) {
                if !space { replaced.append(" ") }
                space = true
            } else {
                replaced.append(scalar); space = false
            }
        }
        var name = trim(String(replaced))
        let units = Array(name.utf16)
        if units.count > maxLength {
            let end = UTF16.isLeadSurrogate(units[maxLength - 1]) ? maxLength - 1 : maxLength
            name = trim(String(decoding: units[..<end], as: UTF16.self))
        }
        return name.isEmpty ? fallback : name
    }

    /// Java's `Character.isISOControl`: C0 controls, DEL and C1 controls.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
    }

    /// Java's `isWhitespace || isSpaceChar` for a scalar that is not a control: the space, line and paragraph
    /// separators.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }

    private static func trim(_ name: String) -> String {
        let scalars = name.unicodeScalars
        let keep: (Unicode.Scalar) -> Bool = { $0 != "." && $0 != " " }
        guard let first = scalars.firstIndex(where: keep), let last = scalars.lastIndex(where: keep) else { return "" }
        return String(scalars[first...last])
    }
}
