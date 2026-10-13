import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The Note screen (Android `NoteScreen`): one destination whose body follows the note's mode. Reading: the chips, the
/// banners and the transcript with the active word, auto-follow and in-note search, over the player. Queued: the card,
/// then the reading content of a transcript. Processing: the progress card and the draft, no player. Paused: the banner,
/// the read-only draft and the player. Failed: the banner, then the transcript or the draft so far. Audio only and
/// unplayable: their banners, with the player for the first.
///
/// The rules are the pure `NoteMode`, `NoteBanners`, `NoteTranscripts` and `NoteScreenState` (CassiniNotebook); this
/// view reads the stores, keeps the screen's state and carries out the effects the rules return. It never reads the
/// playback position itself: the transcript, the player bar and the follow chip do, so a tick redraws only them.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var screen: NoteScreenState
    @State private var sheet: NoteSheet?
    /// The text typed so far into Name this speaker or Rename, kept with the open sheet.
    @State private var sheetDraft: String?
    @State private var shareItem: ShareItem?
    @State private var exportingDocument = false
    @State private var showBookmarks = false
    /// This screen, as the owner of the player.
    @State private var playerOwner = PlaybackOwner()
    @State private var geometry = FollowGeometry()
    @State private var scrollPosition = ScrollPosition()
    @State private var cache = TranscriptCache()
    @State private var resumeFollow: Task<Void, Never>?
    /// The search kept with the stack was brought back into this view.
    @State private var restored = false
    /// The saved progress of a stopped or failed job, for its read-only draft.
    @State private var savedDraft: [DraftWord] = []

    init(noteID: UUID, query: String? = nil, start: NoteStartAction? = nil) {
        self.noteID = noteID
        self.start = start
        _screen = State(initialValue: NoteScreenState(query: query))
    }

    private var note: Note? { library.note(noteID) }
    private var job: Job? { processing.state.jobs[noteID] }

    var body: some View {
        #if DEBUG
        let _ = RenderProbe.rendered("screen")
        #endif
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
            if let note, playerKey != nil { playback.show(note, owner: playerOwner) } else { playback.leave(playerOwner) }
        }
        .task(id: job.map { "\($0.state)-\($0.doneMs)" }) {
            let stopped = job.map { $0.state == .paused || $0.state == .failed } == true
            let draft = stopped ? await processing.savedDraft(noteID) : []
            if !Task.isCancelled { savedDraft = draft }
        }
        .onDisappear {
            playback.leave(playerOwner)
            resumeFollow?.cancel()
        }
        .onAppear(perform: appeared)
        .onChange(of: router.session(noteID).started) { _, started in if !started { runStart() } }
        .onChange(of: NoteScreenState.isGone(note)) { _, gone in if gone { router.close(noteID: noteID) } }
        .onChange(of: screen.search?.query) { _, query in router.keepSearch(query, for: noteID) }
        .backButtonTitle(router.below(noteID: noteID) == .library ? NoteCopy.backToLibrary : nil)
        .sheet(item: $sheet, content: sheetContent)
        .keepsNoteOverlay(noteID: noteID, note: note, readOnly: readOnly, sheet: $sheet, draft: $sheetDraft,
                          dialog: $screen.dialog)
        .alert(dialogTitle, isPresented: dialogShown, presenting: screen.dialog, actions: dialogActions,
               message: dialogMessage)
        .shareSheet(item: $shareItem)
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
        let matches = screen.search.map { cache.matches(transcript, query: $0.query) } ?? []
        let current = screen.search?.current(of: matches.count) ?? 0
        let currentMatch = matches.indices.contains(current) ? matches[current] : nil
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    NoteHeader(note: note, subtitle: NoteSubtitle.of(note, mode: mode, now: clock.now, calendar: calendar))
                    ForEach(mode.sections, id: \.self) { section($0, note: note, mode: mode) }
                    if mode.hasPlayer, !note.bookmarks.isEmpty {
                        BookmarksSection(note: note, isExpanded: $showBookmarks, seek: seek)
                    }
                    if case .processing = mode {
                        RunningDraft(noteID: noteID, cache: cache)
                    } else if mode.showsDraft, !savedDraft.isEmpty {
                        DraftSection(transcript: cache.saved(savedDraft), changing: false)
                    }
                    if note.saysNoSpeech(in: mode) {
                        NoSpeechState()
                    } else if !transcript.isEmpty {
                        ReadingTranscript(noteID: noteID, transcript: transcript, hits: TranscriptHits(matches, current: current),
                                          renamable: true, following: screen.follow.following,
                                          actions: transcriptActions, geometry: geometry, proxy: proxy,
                                          position: $scrollPosition, suggestion: { suggestionCard($0, in: transcript) })
                    }
                }
                .padding(Spacing.gutter).readableWidth()
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollMetrics.self) { ScrollMetrics($0) } action: { _, metrics in
                geometry.offset = metrics.offset; geometry.top = metrics.top
                geometry.height = metrics.height; geometry.maxOffset = metrics.maxOffset
            }
            .onScrollPhaseChange { _, phase in scrolled(phase) }
            // Also on the first value: a search the Library opened scrolls to its first match.
            .task(id: currentMatch) {
                guard let currentMatch else { return }
                await Task.yield()
                reveal(currentMatch, in: transcript, proxy: proxy)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if screen.search != nil {
                InNoteSearchBar(query: searchQuery, current: current, total: matches.count,
                                previous: { screen.search?.previous(of: matches.count) },
                                next: { screen.search?.next(of: matches.count) },
                                close: { screen.closeSearch() })
                    .padding(.horizontal, Spacing.gutter).padding(.vertical, 8)
                    .readableWidth()
                    .background(Color.paper)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                FollowChipHost(noteID: noteID, follow: screen.follow) { resume() }
                if mode.hasPlayer, note.audio.isPlayable { NotePlayerBar(note: note, addBookmark: { showBookmarks = true }) }
            }
            .animation(.default, value: screen.follow)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if mode == .reading, !transcript.isEmpty {
                    Button(NoteCopy.searchInTranscript, systemImage: "magnifyingglass") { screen.openSearch() }
                        .accessibilityIdentifier("searchTranscript")
                }
                NoteMenu(note: note, transcribeRow: TranscribeRow.of(note, job: job), exportingDocument: exportingDocument,
                         perform: { perform($0, note: note, readOnly: readOnly) })
            }
        }
    }

    @ViewBuilder private func section(_ section: NoteSection, note: Note, mode: NoteMode) -> some View {
        switch section {
        case .card: ProcessingCard(note: note)
        case .chips:
            if let chips = NoteChips.of(note) {
                NoteChipsRow(chips: chips, toggleTrust: { screen.toggleTrust() },
                             openVersions: { run(screen.versionsTapped(readOnly: readOnly)) },
                             openSpeakers: { run(screen.speakersTapped(readOnly: readOnly)) })
            }
        case .banners:
            RecordingNotices(noteID: noteID)
            // The callbacks read the note and its job when called: an unchanged list keeps the ones it was made with.
            NoteBannersView(note: note, job: job, mode: mode, facts: bannerFacts,
                            act: { _, action in
                                if let note = self.note { run(screen.bannerAction(action, note: note, job: self.job)) }
                            },
                            dismiss: { banner in
                                if let note = self.note { run(screen.dismiss(banner, note: note, job: self.job)) }
                            })
        }
    }

    /// Scrolls the current search match into the middle of the pane, unless its line is in view already; without
    /// animation under Reduce Motion.
    private func reveal(_ match: TranscriptMatch, in transcript: NoteTranscript, proxy: ScrollViewProxy) {
        if let turn = transcript.turn(match.turnID), let frame = geometry.frames[match.turnID], geometry.height > 0 {
            let fraction = turn.text.isEmpty ? 0 : Double(match.range.lowerBound) / Double(turn.text.count)
            let lineY = frame.minY - geometry.top + frame.height * fraction
            if lineY >= 0, lineY + Self.lineHeight <= geometry.height { return }
        }
        withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(match.turnID, anchor: .center) }
    }

    /// About one line of the transcript's body text.
    private static let lineHeight: CGFloat = 24

    private var bannerFacts: NoteBannerFacts {
        let state = processing.state
        return NoteBannerFacts(trustToggled: screen.trustToggled, queueHold: state.hold, waitingJobs: state.queue.count,
                               dismissed: screen.dismissed)
    }

    private var searchQuery: Binding<String> {
        Binding(get: { screen.search?.query ?? "" }, set: { screen.search?.setQuery($0) })
    }

    /// The paragraphs' callbacks. A paragraph that did not change keeps the callbacks it was made with, so they read
    /// the transcript and the read-only gate as they are when called, not as they were when it was drawn.
    private var transcriptActions: TranscriptActions {
        TranscriptActions(
            wordTap: { run(screen.wordTapped($0, in: cache.shownSealed)) },
            playTurn: { run(screen.playTurn($0, in: cache.shownSealed)) },
            nameSpeaker: { run(screen.speakerTapped($0, readOnly: readOnly)) },
            editPassage: { run(screen.editPassage($0, readOnly: readOnly)) },
            markMoment: { time in
                library.markMoment(noteID, at: time)
                showBookmarks = true
            })
    }

    /// Why the transcript cannot be changed now.
    private var readOnly: ReadOnlyReason? { note.flatMap { ReadOnlyReason.of($0, job: job) } }

    /// "Is this Luca?" above the first paragraph of a placeholder speaker a saved voice may be.
    private func suggestionCard(_ turn: NoteTurn, in transcript: NoteTranscript) -> AnyView? {
        guard let suggestion = turn.suggestion else { return nil }
        let ordinal = transcript.speakers.firstIndex(of: suggestion.speakerID) ?? 0
        return AnyView(SuggestionCard(noteID: noteID, suggestion: suggestion, ordinal: ordinal) { id in
            run(screen.speakerTapped(id, readOnly: readOnly))
        })
    }

    // MARK: Follow

    /// A drag during playback pauses auto-follow; once the scrolling stops, 4 s without scrolling resume it.
    private func scrolled(_ phase: ScrollPhase) {
        switch phase {
        case .interacting:
            resumeFollow?.cancel()
            screen.follow.dragged(playing: playback.owns(noteID) && playback.state.isPlaying)
        case .idle where !screen.follow.following:
            resumeFollow?.cancel()
            resumeFollow = Task {
                try? await Task.sleep(for: PlaybackFollow.resumeAfter)
                guard !Task.isCancelled else { return }
                screen.follow.resume()
            }
        default:
            break
        }
    }

    private func resume() {
        resumeFollow?.cancel()
        screen.follow.resume()
    }

    // MARK: Effects

    private func run(_ effect: NoteEffect?) {
        guard let effect else { return }
        switch effect {
        case .seekAndPlay(let time): seek(time)
        case .nameSpeaker(let id): sheet = .naming(id, draft: nil)
        case .openVersions: sheet = .versions
        case .openSpeakers: sheet = .speakers
        case .editPassage(let id):
            if let segment = note?.transcript.first(where: { $0.id == id }) { sheet = .editing(segment) }
        case .transcribe(let kind): requestTranscription(kind)
        case .startOver: Task { handle(await processing.startOver(noteID)) }
        case .acknowledgeTrustAndPlay:
            library.update(noteID) { $0.document?.trustAcknowledged = true }
            if playback.owns(noteID) { playback.play() }
        case .continueQueue: processing.continueQueue()
        case .clearFailed: processing.clearFailed(noteID)
        }
    }

    private func perform(_ action: NoteMenuAction, note: Note, readOnly: ReadOnlyReason?) {
        switch action {
        case .toggleStar: library.update(noteID) { $0.isFavorite.toggle() }
        case .speakers: run(screen.speakersTapped(readOnly: readOnly))
        case .versions: run(screen.versionsTapped(readOnly: readOnly))
        case .rename: sheet = .rename(draft: nil)
        case .documentInfo: sheet = .documentInfo
        case .exportTranscript(let format): export(format)
        case .exportDocument: exportDocument()
        case .shareAudio: if let url = library.originalAudioURL(note) { shareItem = ShareItem(url: url) }
        case .transcribe: requestTranscription(.transcribe)
        case .transcribeAgain: run(screen.transcribeAgain(note))
        case .stop: processing.stop(noteID)
        case .removeFromQueue: processing.dequeue(noteID)
        case .resume: requestTranscription(job?.kind ?? .transcribe)
        case .startOver: run(screen.bannerAction(.startOver, note: note, job: job))
        case .moveToTrash: Task { await trash.requestTrash(noteID) }
        }
    }

    /// Transcribe; without consent for the speech model, the model download screen asks first, and a refusal says why.
    private func requestTranscription(_ kind: JobKind) {
        Task { handle(await processing.transcribe(noteID, kind: kind)) }
    }

    /// What queuing a transcription led to: without consent the model download asks first; a refusal says why.
    private func handle(_ outcome: TranscribeOutcome) {
        switch outcome {
        case .needsConsent: router.push(.modelDownload(noteID: noteID))
        case .refused(let refusal): errors.present(refusal.message)
        case .queued: break
        }
    }

    private func seek(_ time: TimeInterval) {
        guard !recording.state.isActive, let note else { return }
        playback.play(note, from: time)
    }

    private func export(_ format: TranscriptFormat) {
        Task {
            do throws(ExportError) { shareItem = exports.shareItem(try await exports.exportTranscript(noteID, format: format)) }
            catch { errors.present(ExportCopy.message(error)) }
        }
    }

    private func exportDocument() {
        exportingDocument = true
        Task {
            do { shareItem = exports.shareItem(try await exports.exportPortable(noteID)) }
            catch { errors.present(ExportCopy.notSaved) }
            exportingDocument = false
        }
    }

    /// Brings back the search the stack kept for this screen (when SwiftUI built the view again), and runs the
    /// Library's start action.
    private func appeared() {
        if !restored {
            restored = true
            if let kept = router.session(noteID).search { screen.search = NoteScreenState(query: kept).search }
        }
        runStart()
    }

    /// Runs the Library's start action once for the screen: the router remembers that it ran, and a route restored
    /// with the scene carries none. A screen leaving the stack forgets it ran, and runs nothing.
    private func runStart() {
        guard let start, router.isOpen(noteID), !router.session(noteID).started else { return }
        router.markStarted(noteID)
        switch start {
        case .export(let format): export(format)
        case .documentInfo: sheet = .documentInfo
        case .rename: sheet = .rename(draft: nil)
        }
    }

    // MARK: Sheets and dialogs

    @ViewBuilder private func sheetContent(_ sheet: NoteSheet) -> some View {
        switch sheet {
        case .rename(let draft): RenameNoteSheet(noteID: noteID, draft: draft) { sheetDraft = $0 }
        case .speakers: SpeakersView(noteID: noteID)
        case .versions: TranscriptVersionsView(noteID: noteID)
        case .documentInfo: DocumentInfoSheet(noteID: noteID)
        case .naming(let speakerID, let draft):
            NameSpeakerSheet(noteID: noteID, speakerID: speakerID, draft: draft) { sheetDraft = $0 }
        case .editing(let segment): SegmentEditor(noteID: noteID, segment: segment)
        }
    }

    private var dialogShown: Binding<Bool> {
        Binding(get: { screen.dialog != nil }, set: { if !$0 { screen.dismissDialog() } })
    }

    private var dialogTitle: String {
        switch screen.dialog {
        case .readOnly(let reason)?: NoteCopy.readOnly(reason)
        case .startOver?: NoteCopy.startOverTitle
        case .transcribeFresh?: NoteCopy.freshTitle
        case nil: ""
        }
    }

    @ViewBuilder private func dialogActions(_ dialog: NoteDialog) -> some View {
        switch dialog {
        case .readOnly: Button(NoteCopy.close, role: .cancel) { screen.dismissDialog() }
        case .startOver:
            Button(NoteCopy.startOver, role: .destructive) { run(screen.confirmDialog()) }
            Button(NoteCopy.cancel, role: .cancel) { screen.dismissDialog() }
        case .transcribeFresh:
            Button(NoteCopy.transcribeAgain) { run(screen.confirmDialog()) }
            Button(NoteCopy.cancel, role: .cancel) { screen.dismissDialog() }
        }
    }

    @ViewBuilder private func dialogMessage(_ dialog: NoteDialog) -> some View {
        switch dialog {
        case .readOnly: EmptyView()
        case .startOver: Text(NoteCopy.startOverBody)
        case .transcribeFresh: Text(NoteCopy.freshBody)
        }
    }
}

/// What auto-follow needs to know about the scroll view: its offset, the top inset (the search bar and the
/// navigation bar), the height between the insets, and the largest offset.
private struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var top: CGFloat
    var height: CGFloat
    var maxOffset: CGFloat

    init(_ geometry: ScrollGeometry) {
        let insets = geometry.contentInsets
        offset = geometry.contentOffset.y
        top = insets.top
        height = max(0, geometry.containerSize.height - insets.top - insets.bottom)
        maxOffset = max(-insets.top, geometry.contentSize.height + insets.bottom - geometry.containerSize.height)
    }
}
