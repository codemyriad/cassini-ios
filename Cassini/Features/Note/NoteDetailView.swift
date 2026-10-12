import SwiftUI
import CassiniEngine
import CassiniNotebook

struct NoteDetailView: View {
    let noteID: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(ProcessingStore.self) private var processing
    @Environment(RecordingStore.self) private var recording
    @Environment(Router.self) private var router
    @Environment(ErrorPresenter.self) private var errors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var showSearch = false
    @State private var followPlayback = true
    @State private var showBookmarks = false
    @State private var renaming = false
    @State private var editing: TranscriptSegment?
    @State private var showingSpeakers = false
    @State private var showingVersions = false
    @State private var shareItem: ShareItem?

    private var note: Note? { library.note(noteID) }
    private var ownsPlayer: Bool { playback.state.noteID == noteID }
    private var activeSegment: UUID? {
        guard ownsPlayer else { return nil }
        let position = playback.state.position
        return note?.transcript.last { $0.start <= position && $0.end > position }?.id
    }

    var body: some View {
        Group {
            if let note {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.section) {
                            NoteHeader(note: note)
                            notices(note)
                            if note.status == .transcribing || note.status == .queued { ProcessingCard(note: note) }
                            if showSearch { InNoteSearchBar(query: $query) { showSearch = false; query = "" } }
                            if !note.bookmarks.isEmpty { BookmarksSection(note: note, isExpanded: $showBookmarks, seek: seek) }
                            if note.transcript.isEmpty {
                                TranscriptEmptyState(note: note, requestTranscription: requestTranscription)
                            } else {
                                TranscriptList(note: note, query: query, activeSegment: activeSegment, followPlayback: $followPlayback,
                                               showSpeakers: { showingSpeakers = true }, edit: { editing = $0 }, seek: seek)
                            }
                        }.padding(Spacing.gutter).frame(maxWidth: ReadableWidth.note).frame(maxWidth: .infinity)
                    }
                    .onScrollPhaseChange { _, phase in if phase == .interacting { followPlayback = false } }
                    .onChange(of: activeSegment) { _, id in
                        guard followPlayback, playback.state.isPlaying, query.isEmpty, let id else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    PlaybackBar(note: note, addBookmark: { showBookmarks = true })
                        .disabled(recording.state.isActive || !ownsPlayer)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Find in transcript", systemImage: "magnifyingglass") { showSearch.toggle() }
                        NoteMenu(note: note, renaming: $renaming, showingSpeakers: $showingSpeakers, showingVersions: $showingVersions,
                                 shareItem: $shareItem, requestTranscription: requestTranscription)
                    }
                }
            } else {
                ContentUnavailableView("Recording unavailable", systemImage: "waveform.slash", description: Text("Return to your library to choose a recording."))
            }
        }
        .background(Color.paper)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: noteID) { if let note, !recording.state.isActive { playback.load(note) } }
        .onDisappear { if ownsPlayer { playback.pause() } }
        .sheet(isPresented: $renaming) { RenameNoteSheet(noteID: noteID) }
        .sheet(item: $editing) { segment in
            SegmentEditor(segment: segment, speakers: note?.speakers ?? []) { revised in
                library.update(noteID) { note in
                    if let index = note.transcript.firstIndex(where: { $0.id == revised.id }) { note.transcript[index] = revised }
                }
            }
        }
        .sheet(isPresented: $showingSpeakers) { SpeakersView(noteID: noteID) }
        .sheet(isPresented: $showingVersions) { TranscriptVersionsView(noteID: noteID) }
        .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
    }

    @ViewBuilder private func notices(_ note: Note) -> some View {
        if recording.finishingNoteID == noteID {
            HStack(spacing: 12) { ProgressView(); Text("Saving a compact copy. Your original audio is safe.").font(.subheadline).foregroundStyle(Color.muted) }
        }
        if recording.state.isActive { NoticeCard(title: "Finish recording to listen to this note.", symbol: "mic") }
        if let failure = note.failure { NoticeCard(title: failure.transcriptionMessage, symbol: "exclamationmark.circle") }
        if let failure = note.speakerAnalysisFailure { NoticeCard(title: failure.speakerAnalysisMessage, symbol: "person.2") }
        if let problem = note.playbackProblem { NoticeCard(title: problem, symbol: "waveform.slash") }
    }

    /// Transcribe; without consent for the speech model, the model download screen asks first, and a refusal says why.
    private func requestTranscription() {
        Task {
            switch await processing.transcribe(noteID) {
            case .needsConsent: router.push(.modelDownload(noteID: noteID))
            case .refused(let refusal): errors.present(refusal.message)
            case .queued: break
            }
        }
    }

    private func seek(_ time: TimeInterval) {
        guard !recording.state.isActive, let note, note.audio.isPlayable else { return }
        playback.play(note, from: time)
    }
}
