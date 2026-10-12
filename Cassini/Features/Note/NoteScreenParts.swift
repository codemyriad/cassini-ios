import SwiftUI
import CassiniEngine
import CassiniNotebook

// The parts of the Note screen that follow fast-changing state (the playback position, the job's progress, the
// recording) live in their own views, so that state redraws them and not the screen around them.

/// The banners of the note, the playback failure among them (the one fact here that moves with the player).
struct NoteBannersView: View {
    let note: Note
    let job: Job?
    let mode: NoteMode
    let facts: NoteBannerFacts
    let act: (NoteBanner, NoteBanner.Action) -> Void
    let dismiss: (NoteBanner) -> Void
    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        var facts = facts
        facts.playbackFailed = playback.failed(note.id)
        // The player's state changes on every tick; the banners only when it fails, so a list that compares equal is
        // not drawn again.
        return NoteBannerList(banners: NoteBanners.of(note, job: job, mode: mode, facts: facts), act: act, dismiss: dismiss)
            .equatable()
    }
}

private struct NoteBannerList: View, @MainActor Equatable {
    let banners: [NoteBanner]
    let act: (NoteBanner, NoteBanner.Action) -> Void
    let dismiss: (NoteBanner) -> Void

    static func == (a: NoteBannerList, b: NoteBannerList) -> Bool { a.banners == b.banners }

    var body: some View {
        #if DEBUG
        let _ = RenderProbe.rendered("banners")
        #endif
        ForEach(banners) { banner in
            NoteBannerView(banner: banner, act: { act(banner, $0) }, dismiss: { dismiss(banner) })
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
    let addBookmark: () -> Void
    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        PlaybackBar(note: note, addBookmark: addBookmark)
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

/// The draft of the running job, as it grows; "Words may still change" while it does.
struct RunningDraft: View {
    let noteID: UUID
    let cache: TranscriptCache
    @Environment(JobProgress.self) private var progress

    var body: some View {
        if case .transcribing(_, let draft)? = progress.phase(for: noteID), !draft.words.isEmpty {
            DraftSection(transcript: cache.draft(draft), changing: true)
        }
    }
}

/// "Draft transcript" and its paragraphs, read-only.
struct DraftSection: View {
    let transcript: NoteTranscript
    let changing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(NoteCopy.draftTitle).font(.caption.weight(.semibold)).tracking(1.2).textCase(.uppercase)
                    .foregroundStyle(Color.muted).accessibilityAddTraits(.isHeader)
                if changing {
                    Text(NoteCopy.draftTag).font(.caption2.weight(.medium)).foregroundStyle(Color.muted)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.ink.opacity(0.06), in: Capsule())
                }
            }
            TranscriptList(transcript: transcript, style: .draft, renamable: false)
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
    private var savedKey: [DraftWord]?
    private var savedValue = NoteTranscript.empty
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

    func draft(_ draft: DraftState) -> NoteTranscript {
        if draft != draftKey {
            draftKey = draft
            draftValue = NoteTranscripts.draft(draft.words, tentativeFromMs: draft.tentativeFromMs)
        }
        return draftValue
    }

    /// A stopped job's saved words: all settled.
    func saved(_ words: [DraftWord]) -> NoteTranscript {
        if words != savedKey {
            savedKey = words
            savedValue = NoteTranscripts.draft(words, tentativeFromMs: nil)
        }
        return savedValue
    }

    func matches(_ transcript: NoteTranscript, query: String) -> [TranscriptMatch] {
        if hitsKey?.0 != transcript || hitsKey?.1 != query {
            hitsKey = (transcript, query)
            hitsValue = TranscriptSearch.matches(transcript.turns, query: query)
        }
        return hitsValue
    }
}
