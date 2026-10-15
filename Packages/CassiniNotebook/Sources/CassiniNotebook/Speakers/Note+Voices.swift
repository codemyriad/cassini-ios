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
                if let index = speakers?.firstIndex(where: { $0.id == id }) {
                    changeShownSpeakers { $0.speakers?[index].match = match }
                }
            case .reject(let id, let voice, let restore): rejectVoice(voice, for: id, restorePlaceholder: restore)
            case .merge(let source, let target, let stamp): mergeSpeaker(source, into: target, stamp: stamp)
            case .unlinkVoice(let voice): unlinkVoice(voice)
            }
        }
    }

    /// "Not <name>": the speaker is never matched to `voiceID` again.
    public mutating func rejectVoice(_ voiceID: UUID, for speakerID: String, restorePlaceholder: Bool) {
        guard let index = speakers?.firstIndex(where: { $0.id == speakerID }), let speaker = speakers?[index] else { return }
        changeShownSpeakers { note in
            if !speaker.excludedVoiceIDs.contains(voiceID) { note.speakers?[index].excludedVoiceIDs.append(voiceID) }
            note.speakers?[index].match = .rejected(voice: voiceID, score: speaker.match.score ?? 0)
            if restorePlaceholder { note.speakers?[index].name = DefaultLabels.placeholder(index + 1) }
            note.refreshSpeakerLabels()
        }
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

    /// Puts back the voice links (`match`, `excludedVoiceIDs`) that `before` had, in the shown speakers and in every
    /// version it had, after the saved voices could not be written. Names and anything else stay as they are now.
    public mutating func restoreVoiceLinks(from before: Note) {
        func restore(_ list: inout [NoteSpeaker], from old: [NoteSpeaker]) {
            let links = Dictionary(old.map { ($0.id, ($0.match, $0.excludedVoiceIDs)) }, uniquingKeysWith: { first, _ in first })
            for index in list.indices {
                guard let link = links[list[index].id] else { continue }
                list[index].match = link.0
                list[index].excludedVoiceIDs = link.1
            }
        }
        if var list = speakers { restore(&list, from: before.speakers ?? []); speakers = list }
        if var history = versions {
            let old = Dictionary((before.versions ?? []).map { ($0.id, $0.speakers) }, uniquingKeysWith: { first, _ in first })
            for index in history.indices {
                if let speakers = old[history[index].id] { restore(&history[index].speakers, from: speakers) }
            }
            versions = history
        }
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

    /// The named speakers whose names an analysis carries over: the shown ones, or, when the shown transcript has none
    /// yet (Transcribe again cleared them), those of the latest version that has some. A speaker counts with a name
    /// that is no placeholder and no rejection.
    private var carriedSpeakers: [NoteSpeaker] {
        let shown = speakers ?? []
        let named = shown.isEmpty ? (versions ?? []).last(where: { !$0.speakers.isEmpty })?.speakers ?? [] : shown
        return named.filter { !DefaultLabels.isDefault(id: $0.id, label: $0.name) && !$0.match.isRejection }
    }

    /// The saved voices the carried speakers are linked to (`carriedSpeakers`, `NoteSpeaker.linkedVoiceID`), each with
    /// the link it had. An automatic match to one of them gets that link back, so a speaker named after a saved voice
    /// keeps its name on Transcribe again and Identify speakers again even with automatic naming off.
    public var carriedVoiceLinks: [UUID: VoiceMatchState] {
        var links: [UUID: VoiceMatchState] = [:]
        for speaker in carriedSpeakers {
            guard let voice = speaker.linkedVoiceID else { continue }
            // A confirmation wins over an automatic match of another speaker to the same voice.
            if case .confirmed = links[voice] { continue }
            links[voice] = speaker.match
        }
        return links
    }

    /// The carried speakers (`carriedSpeakers`) as note-local voices (Android's), so that Transcribe again and Identify
    /// speakers again carry their names over even when they were never saved. A speaker counts with its print among
    /// `prints` and no link to a saved voice in `savedVoiceIDs` (those match on their own, `carriedVoiceLinks`).
    /// Speakers with the same name make one voice.
    public func localVoices(prints: [SpeakerPrint], savedVoiceIDs: Set<UUID>) -> [SavedVoice] {
        let byID = Dictionary(prints.map { ($0.speakerID, $0) }, uniquingKeysWith: { _, latest in latest })
        var voices: [SavedVoice] = []
        for speaker in carriedSpeakers {
            guard !(speaker.linkedVoiceID.map(savedVoiceIDs.contains) ?? false), let print = byID[speaker.id] else { continue }
            let sample = VoiceSample(noteID: id, print: print)
            if let index = voices.firstIndex(where: { NameMatch.same($0.name, speaker.name) }) {
                voices[index].samples.append(sample)
            } else {
                voices.append(SavedVoice(name: speaker.name, samples: [sample]))
            }
        }
        return voices
    }

    /// Puts a speaker analysis into the note: every passage gets a speaker of `turns`, the speakers are numbered in
    /// order of first appearance and get their match (`autoName` names a speaker after an automatic match). A
    /// transcription shown as it was made, with no speakers yet (the analysis that follows it in the same job, or
    /// Identify speakers on it later), takes the speakers into its own version, as Android seals a transcription and
    /// its speakers as one variant. Otherwise the transcript before it is kept as a version and the result is a new
    /// one. A match to one of `localVoices` (the
    /// note's own names, `localVoices(prints:savedVoiceIDs:)`) names the speaker when it is automatic, whatever
    /// `autoName` says, and links it to no saved voice, as Android stores such a match as none. An automatic match to
    /// a voice of `carriedLinks` (`carriedVoiceLinks`) names the speaker whatever `autoName` says too, and gives it the
    /// link it had: confirmed stays confirmed. Without a valid turn,
    /// or when no passage gets a speaker, nothing but `speakerAnalysisFailure` changes. `attributed` is the transcript
    /// with its speakers when the job already gave each word one as it went (the streaming diarizer, Android's
    /// `Diarization.assign` per window); it holds the note's words, and `turns` then only carry the exclusions.
    public mutating func applySpeakerAnalysis(turns: [SpeakerTurn], matches: [String: VoiceMatch], voiceNames: [UUID: String],
                                              localVoices: Set<UUID> = [], carriedLinks: [UUID: VoiceMatchState] = [:],
                                              autoName: Bool, stamp: VersionStamp, attributed: [TranscriptSegment]? = nil) {
        let attributed = attributed ?? SpeakerAttribution.assign(transcript, turns: turns)
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
            if localVoices.contains(match.voiceID) {
                if match.automatic { speaker.name = name }
            } else if match.automatic, case .confirmed = carriedLinks[match.voiceID] {
                speaker.name = name
                speaker.match = .confirmed(voice: match.voiceID, score: match.score)
            } else if match.automatic && (autoName || carriedLinks[match.voiceID] != nil) {
                speaker.name = name
                speaker.match = .auto(voice: match.voiceID, score: match.score)
            } else {
                speaker.match = .suggested(voice: match.voiceID, score: match.score)
            }
            return speaker
        }
        if let sealed = attributableInPlace {
            // A transcription and its speakers are one version, as Android seals them.
            transcript = attributed
            speakers = analyzed
            refreshSpeakerLabels()
            versions?[sealed].segments = transcript
            versions?[sealed].speakers = speakers ?? []
        } else {
            saveCurrentVersion(.beforeSpeakerAnalysis, id: stamp.before, date: stamp.date)
            // The version the analysis re-attributes: the one just kept, or the shown one when it already held them.
            let source = selectedVersionID
            transcript = attributed
            speakers = analyzed
            refreshSpeakerLabels()
            selectedVersionID = nil
            saveCurrentVersion(.speakerAnalysis, id: stamp.after, date: stamp.date)
            if let index = versions?.lastIndex(where: { $0.id == selectedVersionID }) { versions?[index].attributedFrom = source }
        }
        speakerAnalysisFailure = nil
    }

    /// The index of the shown version when it is a transcription without speakers, which an analysis attributes in
    /// place.
    private var attributableInPlace: Int? {
        guard let index = shownVersionIndex, let version = versions?[index], version.kind == .transcription,
              version.speakers.isEmpty else { return nil }
        return index
    }
}
