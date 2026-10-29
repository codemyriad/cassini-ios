import CryptoKit
import Foundation

/// The provenance of the latest on-device run, with what it describes: the words it made and, after its speaker step,
/// the speakers it gave them. Kept beside the note (`provenance.json`), not in it, so the note model stays as WP0 froze
/// it; an export asks `provenance(for:)` with the note's current transcript.
///
/// The record describes a transcript only while it holds the words the run made, so selecting another version, an edit
/// of a passage or an import that replaces the words leaves an export without it. Speaker attribution, renames and
/// merges keep the words; the speaker record holds while every speaker id in the transcript is one the analysis gave
/// (a merge only removes ids), and is left out once the speakers come from somewhere else.
public struct ProvenanceRecord: Codable, Hashable, Sendable {
    /// The run's provenance, without its speaker record.
    public var provenance: TranscriptProvenance
    /// `fingerprint(of:)` of the words the run saved.
    public var words: String
    public var speakerDiarization: TranscriptProvenance.SpeakerDiarization?
    /// The speaker step's match counts, held with `speakerDiarization`; nil when no prints were made.
    public var speakerIdentification: TranscriptProvenance.SpeakerIdentification?
    /// The speaker ids the analysis gave the words, sorted.
    public var speakerIDs: [String]?

    public init(provenance: TranscriptProvenance, transcript: [TranscriptSegment]) {
        var plain = provenance
        plain.speakerDiarization = nil
        plain.speakerIdentification = nil
        self.provenance = plain
        words = Self.fingerprint(of: transcript)
    }

    private enum CodingKeys: String, CodingKey {
        case provenance, words, speakerDiarization, speakerIdentification, speakerIDs
    }

    /// A speaker record that no longer reads (one of a build that told speakers apart with FluidAudio, which has none
    /// of Sortformer's members) is left out; the words' record still holds.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provenance = try c.decode(TranscriptProvenance.self, forKey: .provenance)
        words = try c.decode(String.self, forKey: .words)
        speakerDiarization = try? c.decodeIfPresent(TranscriptProvenance.SpeakerDiarization.self, forKey: .speakerDiarization)
        speakerIdentification = speakerDiarization == nil ? nil
            : try? c.decodeIfPresent(TranscriptProvenance.SpeakerIdentification.self, forKey: .speakerIdentification)
        speakerIDs = speakerDiarization == nil ? nil : try c.decodeIfPresent([String].self, forKey: .speakerIDs)
    }

    /// Whether `transcript` holds the words this run made.
    public func describes(_ transcript: [TranscriptSegment]) -> Bool { words == Self.fingerprint(of: transcript) }

    /// Records the speaker step over `transcript`, the words with the speakers it gave them, and the step's matches
    /// against the saved voices when it made prints.
    public mutating func addSpeakers(_ diarization: TranscriptProvenance.SpeakerDiarization,
                                     identification: TranscriptProvenance.SpeakerIdentification? = nil,
                                     transcript: [TranscriptSegment]) {
        speakerDiarization = diarization
        speakerIdentification = identification
        speakerIDs = Self.speakerIDs(of: transcript).sorted()
    }

    /// The provenance of `transcript`: nil when it does not hold this run's words, and without the speaker record when
    /// its speakers are not the ones the analysis gave.
    public func provenance(for transcript: [TranscriptSegment]) -> TranscriptProvenance? {
        guard describes(transcript) else { return nil }
        var result = provenance
        let current = Self.speakerIDs(of: transcript)
        if let speakerDiarization, let speakerIDs, !current.isEmpty, current.isSubset(of: Set(speakerIDs)) {
            result.speakerDiarization = speakerDiarization
            result.speakerIdentification = speakerIdentification
        }
        return result
    }

    /// SHA-256 of the words in time order with their times, ignoring how they are split into passages and who says
    /// them. A passage without word times counts as one word.
    public static func fingerprint(of transcript: [TranscriptSegment]) -> String {
        var text = ""
        for segment in transcript {
            if segment.words.isEmpty {
                text += token(segment.text, segment.start, segment.end)
            } else {
                for word in segment.words { text += token(word.text, word.start, word.end) }
            }
        }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func token(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> String {
        "\(CheckpointState.ms(start))\t\(CheckpointState.ms(end))\t\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    private static func speakerIDs(of transcript: [TranscriptSegment]) -> Set<String> {
        Set(transcript.compactMap(\.speakerID))
    }
}
