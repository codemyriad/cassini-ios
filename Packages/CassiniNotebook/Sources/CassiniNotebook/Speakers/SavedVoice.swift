import Foundation

/// One speaker's voiceprint from one analysis of a note. Prints stay in private storage and never go into an export.
public struct SpeakerPrint: Codable, Hashable, Sendable {
    public var speakerID: String
    /// The model and weights that made the print; prints of different models cannot be compared.
    public var model: String
    public var vector: [Float]
    /// Seconds in which this speaker, and nobody else, speaks.
    public var speechSeconds: Double
    public init(speakerID: String, model: String, vector: [Float], speechSeconds: Double) {
        self.speakerID = speakerID; self.model = model; self.vector = vector; self.speechSeconds = speechSeconds
    }
}

/// A print the user confirmed as a saved voice: one per note and speaker.
public struct VoiceSample: Codable, Hashable, Sendable {
    public var noteID: UUID
    public var print: SpeakerPrint
    public init(noteID: UUID, print: SpeakerPrint) { self.noteID = noteID; self.print = print }
}

/// A person the user named and asked Cassini to remember: the confirmed samples of their voice. Stored only on this
/// device. Android keeps a running mean; iOS keeps the samples, so taking one back is exact.
public struct SavedVoice: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var samples: [VoiceSample]
    /// Immutable zero-based save order. Missing only before the first save or in a legacy version-one file.
    public let saveSequence: Int?
    public init(id: UUID = UUID(), name: String, samples: [VoiceSample], saveSequence: Int? = nil) {
        self.id = id; self.name = name; self.samples = samples; self.saveSequence = saveSequence
    }

    func saved(at sequence: Int) -> SavedVoice {
        SavedVoice(id: id, name: name, samples: samples, saveSequence: sequence)
    }

    /// Seconds of confirmed speech in the samples.
    public var confirmedSpeech: Double { samples.reduce(0) { $0 + $1.print.speechSeconds } }

    /// Notes the samples come from.
    public var recordingCount: Int { Set(samples.map(\.noteID)).count }

    /// The samples that can be compared with a print of `model` with `dimension` values.
    public func usableSamples(model: String, dimension: Int? = nil) -> [VoiceSample] {
        samples.filter { sample in
            sample.print.model == model && (dimension.map { sample.print.vector.count == $0 } ?? true)
                && sample.print.speechSeconds >= VoiceLibrary.minimumRememberSeconds
        }
    }

    /// The normalised mean of the usable samples, or nil when none is usable.
    public func mean(model: String, dimension: Int) -> [Float]? {
        let vectors = usableSamples(model: model, dimension: dimension).compactMap { VoiceMatcher.normalized($0.print.vector) }
        guard !vectors.isEmpty else { return nil }
        let sum = vectors.reduce([Float](repeating: 0, count: dimension)) { zip($0, $1).map(+) }
        return VoiceMatcher.normalized(sum)
    }

    /// The cosine of `print` with this voice, or nil when no sample can be compared with it.
    public func score(_ print: SpeakerPrint) -> Float? {
        mean(model: print.model, dimension: print.vector.count).flatMap { VoiceMatcher.cosine(print.vector, $0) }
    }
}

/// Whether a saved voice can still be compared with new prints: it is stale when none of its samples was made with the
/// current model (Android: another model or dimension than the pinned one). Saved voices then says "Name them again in
/// a note to keep recognising them", and the Name a speaker sheet lists the voice last, without a score.
public enum VoiceStaleness {
    public static func isStale(_ voice: SavedVoice, model: String = VoiceprintModel.sha256, dimension: Int? = nil) -> Bool {
        voice.usableSamples(model: model, dimension: dimension).isEmpty
    }
}
