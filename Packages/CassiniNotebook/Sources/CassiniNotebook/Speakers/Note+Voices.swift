import Foundation

/// A change to a note's speakers made by naming, a suggestion, Forget or a merge. It is a value, so the change can run
/// again on a newer note (see `NoteEdit`) and give the same result.
public enum SpeakerChange: Hashable, Sendable {
    case rename(speakerID: String, name: String)
    case match(speakerID: String, VoiceMatchState)
    /// "Not <name>": the voice is never offered for the speaker again; a label that is the voice's name goes back to
    /// the placeholder when `restorePlaceholder`.
    case reject(speakerID: String, voiceID: UUID, restorePlaceholder: Bool)
    case merge(source: String, target: String, stamp: VersionStamp)
    /// The voice was forgotten: no speaker is linked to it or offered it any more. Names stay.
    case unlinkVoice(UUID)
}

extension Note {
    public mutating func apply(_ changes: [SpeakerChange]) {
        for change in changes {
            switch change {
            case .rename(let id, let name): renameSpeaker(id, name: name)
            case .match(let id, let match):
                if let index = speakers?.firstIndex(where: { $0.id == id }) { speakers?[index].match = match }
            case .reject(let id, let voice, let restore): rejectVoice(voice, for: id, restorePlaceholder: restore)
            case .merge(let source, let target, let stamp): mergeSpeaker(source, into: target, stamp: stamp)
            case .unlinkVoice(let voice): unlinkVoice(voice)
            }
        }
    }

    /// "Not <name>": the speaker is never matched to `voiceID` again.
    public mutating func rejectVoice(_ voiceID: UUID, for speakerID: String, restorePlaceholder: Bool) {
        guard let index = speakers?.firstIndex(where: { $0.id == speakerID }), let speaker = speakers?[index] else { return }
        if !speaker.excludedVoiceIDs.contains(voiceID) { speakers?[index].excludedVoiceIDs.append(voiceID) }
        speakers?[index].match = .rejected(voice: voiceID, score: speaker.match.score ?? 0)
        if restorePlaceholder { speakers?[index].name = DefaultLabels.placeholder(index + 1) }
        refreshSpeakerLabels()
    }

    /// Drops every link and offer to `voiceID`, in the shown transcript and in every version. Rejections stay, and
    /// names already written stay.
    public mutating func unlinkVoice(_ voiceID: UUID) {
        dropMatches { $0 == voiceID }
    }

    /// Drops every link and offer to a voice not in `known` (a voice forgotten meanwhile).
    public mutating func reconcileVoices(_ known: Set<UUID>) {
        dropMatches { !known.contains($0) }
    }

    private mutating func dropMatches(_ dropped: (UUID) -> Bool) {
        func clean(_ list: inout [NoteSpeaker]) {
            for index in list.indices {
                if let voice = list[index].match.voiceID, !list[index].match.isRejection, dropped(voice) {
                    list[index].match = .unmatched
                }
            }
        }
        if var list = speakers { clean(&list); speakers = list }
        if var history = versions {
            for index in history.indices { clean(&history[index].speakers) }
            versions = history
        }
    }

    /// For each speaker of `turns`, the voices it must not be matched to: those rejected for the speaker of the shown
    /// transcript whose passages overlap its turns the most. So a voice rejected before is not offered again when the
    /// speakers are identified again.
    public func carriedExclusions(for turns: [SpeakerTurn]) -> [String: Set<UUID>] {
        let excludedBy = Dictionary((speakers ?? []).map { ($0.id, Set($0.excludedVoiceIDs)) }, uniquingKeysWith: { $0.union($1) })
        var overlap: [String: [String: Double]] = [:]
        for turn in turns where turn.isValid {
            for segment in transcript {
                guard let old = segment.speakerID, let excluded = excludedBy[old], !excluded.isEmpty else { continue }
                let seconds = min(turn.end, segment.end) - max(turn.start, segment.start)
                if seconds > 0 { overlap[turn.speakerID, default: [:]][old, default: 0] += seconds }
            }
        }
        return overlap.compactMapValues { olds in
            let best = olds.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
            return best.flatMap { excludedBy[$0.key] }
        }
    }

    /// Puts a speaker analysis into the note: the transcript before it is kept as a version, every passage gets a
    /// speaker of `turns`, the speakers are numbered in order of first appearance and get their match (`autoName` names
    /// a speaker after an automatic match), and the result is a new version. Without a valid turn, or when no passage
    /// gets a speaker, nothing but `speakerAnalysisFailure` changes.
    public mutating func applySpeakerAnalysis(turns: [SpeakerTurn], matches: [String: VoiceMatch], voiceNames: [UUID: String],
                                              autoName: Bool, stamp: VersionStamp) {
        let attributed = SpeakerAttribution.assign(transcript, turns: turns)
        var order: [String] = []
        for segment in attributed { if let id = segment.speakerID, !order.contains(id) { order.append(id) } }
        guard SpeakerAttribution.canAttribute(turns), !order.isEmpty else {
            speakerAnalysisFailure = .empty
            return
        }
        let excluded = carriedExclusions(for: turns)
        let analyzed = order.enumerated().map { offset, id in
            var speaker = NoteSpeaker(id: id, name: DefaultLabels.placeholder(offset + 1))
            speaker.excludedVoiceIDs = (excluded[id] ?? []).sorted { $0.uuidString < $1.uuidString }
            guard let match = matches[id], let name = voiceNames[match.voiceID], !speaker.excludedVoiceIDs.contains(match.voiceID)
            else { return speaker }
            if autoName && match.automatic {
                speaker.name = name
                speaker.match = .auto(voice: match.voiceID, score: match.score)
            } else {
                speaker.match = .suggested(voice: match.voiceID, score: match.score)
            }
            return speaker
        }
        saveCurrentVersion(name: "Before speaker analysis", id: stamp.before, date: stamp.date)
        transcript = attributed
        speakers = analyzed
        refreshSpeakerLabels()
        selectedVersionID = nil
        saveCurrentVersion(name: "Speaker analysis", id: stamp.after, date: stamp.date)
        speakerAnalysisFailure = nil
    }
}
