import SwiftUI
import CassiniEngine
import CassiniNotebook

// The parts of the Note screen that follow fast-changing state (the playback position, the job's progress, the
// recording) live in their own views, so that state redraws them and not the screen around them.

/// The banners of the note (the catalogue's, from `NoteBanners`), then the iOS notices: no speakers found, and the
/// playback failure, the one fact here that moves with the player. Only `PlaybackFailedNotice` reads the player, so a
/// playback tick does not draw the banners again.
struct NoteBannersView: View {
    let note: Note
    let job: Job?
    let mode: NoteMode
    let facts: NoteBannerFacts
    let act: (BannerSpec, BannerAction) -> Void
    let dismiss: (BannerSpec) -> Void

    var body: some View {
        #if DEBUG
        let _ = RenderProbe.rendered("banners")
        #endif
        BannerList(specs: NoteBanners.banners(note, job: job, mode: mode, facts: facts,
                                              failureText: \.transcriptionMessage, unplayableText: \.bannerText),
                   onAction: act, onDismiss: dismiss)
        if NoteBanners.noSpeakers(note, job: job) {
            NoticeCard(title: JobFailure.empty.speakerAnalysisMessage, symbol: "person.2.slash")
        }
        if NoteBanners.transcribedByFallback(note, job: job) {
            // cassini-ux `models.parakeetUltra.noteFallback`.
            NoticeCard(title: String(localized: "Parakeet Ultra couldn’t run on this device for this recording, so Whistle transcribed it.",
                                     table: "Notices"))
                .accessibilityIdentifier("notice.parakeetFallback")
        }
        if mode.hasPlayer { PlaybackFailedNotice(noteID: note.id) }
    }
}

/// "This audio can’t be played" while the note's own player has failed.
private struct PlaybackFailedNotice: View {
    let noteID: UUID
    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        if playback.failed(noteID) {
            NoticeCard(title: String(localized: "This audio can’t be played", table: "Playback"), symbol: "waveform.slash")
        }
    }
}

/// While a recording runs the player is closed; while the note's own recording is saved, its compact copy is made.
struct RecordingNotices: View {
    let noteID: UUID
    @Environment(RecordingStore.self) private var recording

    var body: some View {
        if recording.finishingNoteID == noteID {
            HStack(spacing: 12) {
                ProgressView()
                Text("Saving a compact copy. Your original audio is safe.", tableName: "Note")
                    .font(.subheadline).foregroundStyle(Color.muted)
            }
        }
        if recording.state.isActive {
            NoticeCard(title: String(localized: "Finish recording to listen to this note.", table: "Note"), symbol: "mic")
        }
    }
}

/// The player bar, usable while this screen's note owns the player.
struct NotePlayerBar: View {
    let note: Note
    let markMoment: (TimeInterval) -> Void
    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        PlaybackBar(note: note, markMoment: markMoment)
            .disabled(playback.isBlocked || !playback.owns(note.id))
    }
}

/// The Follow playback chip, while the note plays with auto-follow paused.
struct FollowChipHost: View {
    let noteID: UUID
    let follow: PlaybackFollow
    let resume: () -> Void
    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        if follow.showsChip(playing: playback.owns(noteID) && playback.state.isPlaying) {
            FollowChip(action: resume).transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// The draft of the running job, as it grows, with its names; "Words may still change" while it does.
/// `ProcessingBody` follows its end as the list grows.
struct RunningDraft: View {
    let model: NoteScreenModel
    let cache: TranscriptCache

    var body: some View {
        if let draft = model.shownDraft, !draft.words.isEmpty {
            DraftSection(draft: draft, transcript: cache.draft(draft), changing: true, model: model)
        }
    }
}

/// "Draft transcript" and its paragraphs. While the job lets the draft be named, a speaker's header opens Name a
/// speaker and the "Is this Luca?" cards answer in the draft's names.
struct DraftSection: View {
    let draft: DraftState
    let transcript: NoteTranscript
    let changing: Bool
    let model: NoteScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(NoteCopy.draftTitle).font(.caption.weight(.semibold)).tracking(1.2).textCase(.uppercase)
                    .foregroundStyle(Color.muted).accessibilityAddTraits(.isHeader)
                if changing {
                    Text(NoteCopy.draftTag).font(.caption2.weight(.medium)).foregroundStyle(Color.muted)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.ink.opacity(0.1), in: Capsule())
                }
            }
            TranscriptList(transcript: transcript, style: .draft, renamable: draft.namingOpen,
                           actions: TranscriptActions(nameSpeaker: { model.speakerTapped($0) }),
                           suggestion: { turn in
                               guard draft.namingOpen, !turn.allSuggestions.isEmpty else { return nil }
                               return AnyView(VStack(spacing: 12) {
                                   ForEach(turn.allSuggestions, id: \.speakerID) { suggestion in
                                       let ordinal = transcript.speakers.firstIndex(of: suggestion.speakerID) ?? 0
                                       SuggestionCard(suggestion: suggestion, ordinal: ordinal, tint: transcript.speakerTints[suggestion.speakerID] ?? .stone, model: model)
                                   }
                               })
                           })
        }
        .accessibilityIdentifier("draftTranscript")
    }
}

/// The transcripts and search hits the screen shows, made again only when what they come from changed. Comparing
/// a note's passages with the last ones is cheap while they are the same array.
@MainActor final class TranscriptCache {
    private struct SealedKey: Equatable {
        var transcript: [TranscriptSegment]
        var speakers: [NoteSpeaker]?
        var voices: [SavedVoice]
        var suggestions: [SpeakerSuggestion]
    }

    private var sealedKey: SealedKey?
    private var sealedValue = NoteTranscript.empty

    /// The reading transcript last made.
    var shownSealed: NoteTranscript { sealedValue }
    private var draftKey: DraftState?
    private var draftValue = NoteTranscript.empty
    private var hitsKey: (NoteTranscript, String)?
    private var hitsValue: [TranscriptMatch] = []

    func sealed(_ note: Note, voices: [SavedVoice], suggestions: [SpeakerSuggestion]) -> NoteTranscript {
        let key = SealedKey(transcript: note.transcript, speakers: note.speakers, voices: voices, suggestions: suggestions)
        if key != sealedKey {
            sealedKey = key
            sealedValue = NoteTranscripts.sealed(note, voices: voices, suggestions: suggestions)
        }
        return sealedValue
    }

    /// The draft with its names; a stopped job's (`tentativeFromMs` at its end) is all settled.
    func draft(_ draft: DraftState) -> NoteTranscript {
        if draft != draftKey {
            draftKey = draft
            draftValue = NoteTranscripts.draft(draft.words, tentativeFromMs: draft.tentativeFromMs == .max ? nil : draft.tentativeFromMs,
                                               labels: draft.labels, automatic: draft.automatic,
                                               suggestions: draft.suggestions, colourIndices: draft.colourIndices,
                                               provenance: draft.provenance)
        }
        return draftValue
    }

    func matches(_ transcript: NoteTranscript, query: String) -> [TranscriptMatch] {
        if hitsKey?.0 != transcript || hitsKey?.1 != query {
            hitsKey = (transcript, query)
            hitsValue = TranscriptSearch.matches(transcript.turns, query: query)
        }
        return hitsValue
    }
}
