import CassiniCore

/// The `provenance.speechToText.<variant>` record an export writes for one transcript version, with Android's keys:
/// the on-device run's record (`TranscriptProvenance.record()`) while the version holds the run's words, else a record
/// of a transcript edited by hand; for a version a later speaker analysis re-attributed, the variant it started from
/// (`x-derivedFromTranscript`) and that variant's document-wide attribution audit (`x-sourceAttribution`), as
/// Android's `SpeakerAttribution.record` writes them; and, for a version a merge made, the merge's aliases
/// (`x-speakerMerges`, `x-speakerAssignmentEditedBy`, `x-derivedFromTranscript`) through `SpeakerMerges`.
public enum ExportProvenance {
    /// A transcript whose words are not an on-device run's: edited passages, or an import sealed again.
    public static let userEdited = JSONObject([("engine", .string("cassini-ios")), ("kind", .string("user-edited"))])

    /// `run` is the run's provenance for the version's words (nil when they are not the run's); `derivedFrom` the
    /// variant id the version the merge started from got in the same export; `attributedFrom` the variant id of the
    /// version a re-attribution started from, and `sourceAttribution` the `provenance.attribution` of the document
    /// that variant came from. The last two count only while the record holds the analysis's speakers.
    public static func record(run: TranscriptProvenance?, merges: [String: String]?, derivedFrom: String?,
                              attributedFrom: String? = nil, sourceAttribution: JSONObject? = nil) -> JSONObject {
        var base = run?.record() ?? userEdited
        if run?.speakerDiarization != nil, let attributedFrom {
            if let sourceAttribution { base["x-sourceAttribution"] = .object(sourceAttribution) }
            base["x-derivedFromTranscript"] = .string(attributedFrom)
        }
        guard let merges, !merges.isEmpty else { return base }
        return SpeakerMerges.processing(base, aliases: merges, sourceVariant: derivedFrom)
    }
}
