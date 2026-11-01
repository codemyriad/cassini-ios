/// The language of a transcript variant (decision D53.2): the language of the recognizer run that made its words,
/// written the same in the word body (`language`), the transcript descriptor and the run's processing step. It never
/// comes from the Settings speech language. A version made from other words (a passage edit, a merge, a re-attribution)
/// keeps the language of the words it came from, and an imported variant keeps its stored value as it is, with no
/// rewriting through `Locale`. The shared cases are coordination `ux-draft/library-vectors/language-tag`.
public enum TranscriptLanguage {
    /// BCP-47 "undetermined": what a run writes when its recognizer does not say which language it heard (Parakeet).
    public static let undetermined = "und"

    /// The language a run writes: the BCP-47 tag of the language its recognizer ran in or reported (Apple Speech's
    /// locale that actually ran, such as `it-IT`), else `und`. `reported` is nil for a recognizer that reports none.
    public static func ofRun(reported: String?) -> String { known(reported) ?? undetermined }

    /// The stored value when it names a language, as stored; nil when nobody said: absent, empty, `und`, or `auto` (an
    /// earlier Mac build's "not detected"). `und` and `auto` match in any case, as BCP-47 tags do (Android
    /// `Transcript.knownLanguage`).
    public static func known(_ stored: String?) -> String? {
        guard let stored, !stored.isEmpty, !unknown.contains(stored.lowercased()) else { return nil }
        return stored
    }

    private static let unknown: Set<String> = [undetermined, "auto"]
}
