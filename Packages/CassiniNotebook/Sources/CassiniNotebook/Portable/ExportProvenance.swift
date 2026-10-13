import CassiniCore

/// The `provenance.speechToText.<variant>` record an export writes for one transcript version, with Android's keys:
/// the on-device run's record (`x-inferenceMs`, `x-resumedFromMs`, `x-speakerDiarization`) while the version holds
/// the run's words, else a record of a transcript edited by hand; and, for a version a merge made, the merge's
/// aliases (`x-speakerMerges`, `x-speakerAssignmentEditedBy`, `x-derivedFromTranscript`) through `SpeakerMerges`.
public enum ExportProvenance {
    /// A transcript whose words are not an on-device run's: edited passages, or an import sealed again.
    public static let userEdited = JSONObject([("engine", .string("cassini-ios")), ("kind", .string("user-edited"))])

    /// `run` is the run's provenance for the version's words (nil when they are not the run's); `derivedFrom` the
    /// variant id the version the merge started from got in the same export.
    public static func record(run: TranscriptProvenance?, merges: [String: String]?, derivedFrom: String?) -> JSONObject {
        let base = run?.record() ?? userEdited
        guard let merges, !merges.isEmpty else { return base }
        return SpeakerMerges.processing(base, aliases: merges, sourceVariant: derivedFrom)
    }
}
