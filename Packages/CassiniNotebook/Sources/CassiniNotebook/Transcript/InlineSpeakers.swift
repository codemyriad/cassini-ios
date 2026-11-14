import Foundation

extension NoteTurn {
    /// Draft chips have no header of their own. Offer each identifiable chip speaker once,
    /// retaining the exact name and tint already used in the paragraph, even without a voice suggestion.
    public func inlineSpeakersForNaming(isDraft: Bool, renamable: Bool) -> [TurnInterjection] {
        guard isDraft, renamable else { return [] }
        var seen = Set<Data>()
        return interjections.filter { chip in
            guard let id = chip.speakerID, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Data(id.utf8) != Data(NoteTranscripts.draftOneVoice.utf8), Data(id.utf8) != speakerID.map({ Data($0.utf8) }), chip.name != .unknown else { return false }
            return seen.insert(Data(id.utf8)).inserted
        }
    }
}
