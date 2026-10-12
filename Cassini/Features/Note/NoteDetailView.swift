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
    @Environment(VoicesStore.self) private var voices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var showSearch = false
    @State private var followPlayback = true
    @State private var showBookmarks = false
    @State private var renaming = false
    @State private var editing: TranscriptSegment?
    @State private var showingSpeakers = false
    @State private var showingVersions = false
    @State private var naming: SpeakerRef?
    @State private var shareItem: ShareItem?
    @State private var trustToggled = false
    /// Job banners closed on this screen.
    @State private var closedBanners: Set<String> = []
    @State private var confirmingStartOver = false
    /// This screen, as the owner of the player.
    @State private var playerOwner = PlaybackOwner()

    private var note: Note? { library.note(noteID) }
    private var ownsPlayer: Bool { playback.owns(noteID) }
    /// What the player opens; a change opens, reloads or leaves it. It follows the same block as the player, so the
    /// player opens again as soon as a recording lets it go.
    private var playerKey: NotePlayer.Key? { NotePlayer.key(for: note, blocked: playback.isBlocked) }
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
                            NoteHeader(note: note) { trustToggled.toggle() }
                            notices(note)
                            if note.status == .transcribing || note.status == .queued { ProcessingCard(note: note) }
                            if showSearch { InNoteSearchBar(query: $query) { showSearch = false; query = "" } }
                            if !note.bookmarks.isEmpty { BookmarksSection(note: note, isExpanded: $showBookmarks, seek: seek) }
                            if note.transcript.isEmpty {
                                TranscriptEmptyState(note: note, requestTranscription: { requestTranscription() })
                            } else {
                                TranscriptList(note: note, query: query, activeSegment: activeSegment, followPlayback: $followPlayback,
                                               showSpeakers: { showingSpeakers = true }, edit: { editing = $0 }, seek: seek,
                                               suggestion: suggestionCard(in: note))
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
                    if NotePlayer.hasPlayer(note) {
                        PlaybackBar(note: note, addBookmark: { showBookmarks = true })
                            .disabled(playback.isBlocked || !ownsPlayer)
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Find in transcript", systemImage: "magnifyingglass") { showSearch.toggle() }
                        NoteMenu(note: note, renaming: $renaming, showingSpeakers: $showingSpeakers, showingVersions: $showingVersions,
                                 shareItem: $shareItem, requestTranscription: { requestTranscription() })
                    }
                }
            } else {
                ContentUnavailableView("Recording unavailable", systemImage: "waveform.slash", description: Text("Return to your library to choose a recording."))
            }
        }
        .background(Color.paper)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: playerKey) {
            if let note, playerKey != nil { playback.show(note, owner: playerOwner) } else { playback.leave(playerOwner) }
        }
        .onDisappear { playback.leave(playerOwner) }
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
        .sheet(item: $naming) { NameSpeakerSheet(noteID: noteID, speakerID: $0.id) }
        .shareSheet(item: $shareItem)
        .confirmationDialog(Text("Start over?", tableName: "Notices"), isPresented: $confirmingStartOver, titleVisibility: .visible) {
            Button(String(localized: "Start over", table: "Notices"), role: .destructive) { processing.startOver(noteID) }
        } message: {
            Text("The draft so far is discarded. Your recording is kept.", tableName: "Notices")
        }
    }

    @ViewBuilder private func notices(_ note: Note) -> some View {
        if recording.finishingNoteID == noteID {
            HStack(spacing: 12) { ProgressView(); Text("Saving a compact copy. Your original audio is safe.").font(.subheadline).foregroundStyle(Color.muted) }
        }
        if recording.state.isActive { NoticeCard(title: "Finish recording to listen to this note.", symbol: "mic") }
        if let document = note.document {
            DocumentTrustNotice(info: document, toggled: trustToggled,
                                playAnyway: note.audio.isPlayable && !recording.state.isActive ? { playAnyway(note) } : nil)
        }
        let job = processing.state.jobs[noteID]
        if job == nil, let failure = note.failure { NoticeCard(title: failure.transcriptionMessage, symbol: "exclamationmark.circle") }
        BannerList(specs: NoteBanners.banners(note, job: job, failureText: \.transcriptionMessage, dismissed: closedBanners),
                   onAction: { _, action in perform(action, note: note, job: job) },
                   onDismiss: { dismiss($0, note: note, job: job) })
        if let problem = note.playbackProblem { NoticeCard(title: problem, symbol: "waveform.slash") }
        if playback.failed(noteID) {
            NoticeCard(title: String(localized: "This audio can’t be played", table: "Playback"), symbol: "waveform.slash")
        }
    }

    private func perform(_ action: BannerAction, note: Note, job: Job?) {
        switch NoteBanners.command(for: action, note: note, job: job) {
        case .transcribe(let kind): requestTranscription(kind: kind)
        case .confirmStartOver: confirmingStartOver = true
        case nil: break
        }
    }

    private func dismiss(_ spec: BannerSpec, note: Note, job: Job?) {
        switch NoteBanners.dismissal(of: spec, note: note, job: job) {
        case .clearJob: processing.clearFailed(noteID)
        case .hide(let id): closedBanners.insert(id)
        }
    }

    /// "Is this Luca?" above the first passage of each speaker a saved voice may be.
    private func suggestionCard(in note: Note) -> (TranscriptSegment) -> AnyView? {
        let cards = Dictionary(voices.suggestions(for: note).map { ($0.segmentID, $0) }, uniquingKeysWith: { first, _ in first })
        guard !cards.isEmpty else { return { _ in nil } }
        let ordinals = Dictionary(SpeakerStats.of(note.transcript).map { ($0.speakerID, $0.ordinal) }, uniquingKeysWith: { a, _ in a })
        return { segment in
            cards[segment.id].map { card in
                AnyView(SuggestionCard(noteID: noteID, suggestion: card, ordinal: ordinals[card.speakerID] ?? 0) { naming = SpeakerRef(id: $0) })
            }
        }
    }

    /// Android `BannerAction.PLAY_ANYWAY`: the note stops showing its not-verified banner, and plays.
    private func playAnyway(_ note: Note) {
        library.update(noteID) { $0.document?.trustAcknowledged = true }
        if ownsPlayer { playback.play() }
    }

    /// Transcribe; without consent for the speech model, the model download screen asks first, and a refusal says why.
    private func requestTranscription(kind: JobKind = .transcribe) {
        Task {
            switch await processing.transcribe(noteID, kind: kind) {
            case .needsConsent: router.push(.modelDownload(noteID: noteID))
            case .refused(let refusal): errors.present(refusal.message)
            case .queued: break
            }
        }
    }

    private func seek(_ time: TimeInterval) {
        guard !recording.state.isActive, let note else { return }
        playback.play(note, from: time)
    }
}
