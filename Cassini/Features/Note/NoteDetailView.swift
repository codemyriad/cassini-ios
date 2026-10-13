import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The Note screen (Android `NoteScreen`): one destination whose body follows the note's mode. Reading: the chips, the
/// banners and the transcript with the active word, auto-follow and in-note search, over the player. Queued: the card,
/// then the reading content of a transcript. Processing: the progress card and the draft, no player. Paused: the banner,
/// the read-only draft and the player. Failed: the banner, then the transcript or the draft so far. Audio only and
/// unplayable: their banners, with the player for the first.
///
/// The rules are the pure `NoteMode`, `NoteBanners`, `NoteTranscripts` and `NoteScreenState` (CassiniNotebook); the
/// `NoteScreenModel` keeps the screen's state and carries out the effects the rules return; this view reads the stores
/// and lays the screen out. It never reads the playback position itself: the transcript, the player bar and the follow
/// chip do, so a tick redraws only them.
struct NoteDetailView: View {
    let noteID: UUID
    /// What the Library asked the screen to do once it opens (an export, Document info, Rename).
    let start: NoteStartAction?
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(ProcessingStore.self) private var processing
    @Environment(RecordingStore.self) private var recording
    @Environment(Router.self) private var router
    @Environment(ErrorPresenter.self) private var errors
    @Environment(VoicesStore.self) private var voices
    @Environment(ExportStore.self) private var exports
    @Environment(TrashService.self) private var trash
    @Environment(\.clock) private var clock
    @Environment(\.calendar) private var calendar
    @State private var model: NoteScreenModel
    @State private var cache = TranscriptCache()

    init(noteID: UUID, query: String? = nil, start: NoteStartAction? = nil) {
        self.noteID = noteID
        self.start = start
        _model = State(initialValue: NoteScreenModel(noteID: noteID, query: query))
    }

    private var note: Note? { library.note(noteID) }
    private var job: Job? { processing.state.jobs[noteID] }
    /// Why the transcript cannot be changed now.
    private var readOnly: ReadOnlyReason? { note.flatMap { ReadOnlyReason.of($0, job: job) } }

    private var stores: NoteScreenStores {
        NoteScreenStores(library: library, playback: playback, processing: processing, recording: recording, router: router,
                         errors: errors, exports: exports, trash: trash)
    }

    var body: some View {
        #if DEBUG
        let _ = RenderProbe.rendered("screen")
        #endif
        @Bindable var model = model
        Group {
            if let note {
                content(note, mode: NoteMode.of(note, job: job, ahead: processing.state.ahead(of: noteID) ?? 0))
            } else {
                ContentUnavailableView(NoteCopy.unavailableTitle, systemImage: "waveform.slash",
                                       description: Text(NoteCopy.unavailableBody))
            }
        }
        .background(Color.paper)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: playerKey) {
            if let note, playerKey != nil { playback.show(note, owner: model.playerOwner) } else { playback.leave(model.playerOwner) }
        }
        .task(id: job.map { "\($0.state)-\($0.doneMs)" }) { await model.loadSavedDraft(job: job, processing) }
        .onDisappear { model.disappeared(playback) }
        .onAppear { model.appeared(start: start, stores) }
        .onChange(of: router.session(noteID).started) { _, started in if !started { model.runStart(start, stores) } }
        .onChange(of: NoteScreenState.isGone(note)) { _, gone in if gone { router.close(noteID: noteID) } }
        .onChange(of: model.screen.search?.query) { _, query in router.keepSearch(query, for: noteID) }
        .backButtonTitle(router.below(noteID: noteID) == .library ? NoteCopy.backToLibrary : nil)
        .noteSheetsAndDialogs(model: model, stores: stores)
        .keepsNoteOverlay(noteID: noteID, note: note, readOnly: readOnly, sheet: $model.sheet, draft: $model.sheetDraft,
                          dialog: $model.screen.dialog)
        .shareSheet(item: $model.shareItem)
    }

    /// What the player opens; a change opens, reloads or leaves it. A mode without a player (a running job) leaves it,
    /// and it follows the same block as a recording, so it opens again as soon as the recording lets it go.
    private var playerKey: NotePlayer.Key? {
        guard let note, NoteMode.of(note, job: job).hasPlayer else { return nil }
        return NotePlayer.key(for: note, blocked: playback.isBlocked)
    }

    // MARK: Content

    private func content(_ note: Note, mode: NoteMode) -> some View {
        let transcript = mode.showsReading
            ? cache.sealed(note, voices: voices.savedVoices, suggestions: readOnly == nil ? voices.suggestions(for: note) : [])
            : .empty
        let matches = model.screen.search.map { cache.matches(transcript, query: $0.query) } ?? []
        let current = model.screen.search?.current(of: matches.count) ?? 0
        let subtitle = NoteSubtitle.of(note, mode: mode, now: clock.now, calendar: calendar)
        return Group {
            if case .processing = mode {
                ProcessingBody(noteID: noteID, cache: cache) {
                    NoteHeader(note: note, subtitle: subtitle)
                    NoteSectionView(section: .card, note: note, mode: mode, model: model, stores: stores)
                } banners: {
                    NoteSectionView(section: .banners, note: note, mode: mode, model: model, stores: stores)
                }
            } else {
                NoteReadingScroll(note: note, mode: mode, transcript: transcript, subtitle: subtitle, matches: matches,
                                  current: current, savedDraft: model.savedDraft, model: model, stores: stores, cache: cache,
                                  actions: transcriptActions, suggestion: { suggestionCard($0, in: transcript) })
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.screen.search != nil {
                InNoteSearchBar(query: searchQuery, current: current, total: matches.count,
                                previous: { model.screen.search?.previous(of: matches.count) },
                                next: { model.screen.search?.next(of: matches.count) },
                                close: { model.screen.closeSearch() })
                    .padding(.horizontal, Spacing.gutter).padding(.vertical, 8)
                    .readableWidth()
                    .background(Color.paper)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                FollowChipHost(noteID: noteID, follow: model.screen.follow) { model.resumeFollowing() }
                if mode.hasPlayer, note.audio.isPlayable {
                    NotePlayerBar(note: note, addBookmark: { model.showBookmarks = true })
                }
            }
            .animation(.default, value: model.screen.follow)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if mode == .reading, !transcript.isEmpty {
                    Button(NoteCopy.searchInTranscript, systemImage: "magnifyingglass") { model.screen.openSearch() }
                        .accessibilityIdentifier("searchTranscript")
                }
                NoteMenu(note: note, transcribeRow: TranscribeRow.of(note, job: job), exportingDocument: model.exportingDocument,
                         perform: { model.perform($0, note: note, job: job, readOnly: readOnly, stores) })
            }
        }
    }

    private var searchQuery: Binding<String> {
        Binding(get: { model.screen.search?.query ?? "" }, set: { model.screen.search?.setQuery($0) })
    }

    /// The paragraphs' callbacks. A paragraph that did not change keeps the callbacks it was made with, so they read
    /// the transcript and the read-only gate as they are when called, not as they were when it was drawn.
    private var transcriptActions: TranscriptActions {
        TranscriptActions(
            wordTap: { model.run(model.screen.wordTapped($0, in: cache.shownSealed), stores) },
            playTurn: { model.run(model.screen.playTurn($0, in: cache.shownSealed), stores) },
            nameSpeaker: { model.run(model.screen.speakerTapped($0, readOnly: readOnly), stores) },
            editPassage: { model.run(model.screen.editPassage($0, readOnly: readOnly), stores) },
            markMoment: { model.markMoment(at: $0, stores) })
    }

    /// "Is this Luca?" above the first paragraph of a placeholder speaker a saved voice may be.
    private func suggestionCard(_ turn: NoteTurn, in transcript: NoteTranscript) -> AnyView? {
        guard let suggestion = turn.suggestion else { return nil }
        let ordinal = transcript.speakers.firstIndex(of: suggestion.speakerID) ?? 0
        return AnyView(SuggestionCard(noteID: noteID, suggestion: suggestion, ordinal: ordinal) { id in
            model.run(model.screen.speakerTapped(id, readOnly: readOnly), stores)
        })
    }
}

/// A section above the transcript: the progress card, the chips (trust, version, speakers) or the banners. The
/// callbacks read the note and its job when called: an unchanged list keeps the ones it was made with.
struct NoteSectionView: View {
    let section: NoteSection
    let note: Note
    let mode: NoteMode
    let model: NoteScreenModel
    let stores: NoteScreenStores

    private var noteID: UUID { note.id }
    private var job: Job? { stores.processing.state.jobs[noteID] }
    private var readOnly: ReadOnlyReason? { stores.library.note(noteID).flatMap { ReadOnlyReason.of($0, job: job) } }

    var body: some View {
        switch section {
        case .card: ProcessingCard(note: note)
        case .chips:
            if let chips = NoteChips.of(note) {
                NoteChipsRow(chips: chips, toggleTrust: { model.screen.toggleTrust() },
                             openVersions: { model.run(model.screen.versionsTapped(readOnly: readOnly), stores) },
                             openSpeakers: { model.run(model.screen.speakersTapped(readOnly: readOnly), stores) })
            }
        case .banners:
            RecordingNotices(noteID: noteID)
            NoteBannersView(note: note, job: job, mode: mode, facts: bannerFacts,
                            act: { _, action in
                                guard let note = stores.library.note(noteID) else { return }
                                model.run(model.screen.bannerAction(action, note: note, job: job), stores)
                            },
                            dismiss: { banner in
                                guard let note = stores.library.note(noteID) else { return }
                                model.run(model.screen.dismiss(banner, note: note, job: job), stores)
                            })
        }
    }

    private var bannerFacts: NoteBannerFacts {
        let state = stores.processing.state
        return NoteBannerFacts(trustToggled: model.screen.trustToggled, queueHold: state.hold, waitingJobs: state.queue.count,
                               dismissed: model.screen.dismissed)
    }
}
