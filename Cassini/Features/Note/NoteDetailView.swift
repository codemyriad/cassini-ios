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
    @Environment(ProcessingStore.self) private var processing
    @Environment(Router.self) private var router
    @Environment(VoicesStore.self) private var voices
    @Environment(\.clock) private var clock
    @Environment(\.calendar) private var calendar
    @State private var model: NoteScreenModel
    @State private var cache = TranscriptCache()
    @State private var headerTitleVisible = true

    init(model: @autoclosure () -> NoteScreenModel) {
        let model = model()
        self.noteID = model.noteID
        _model = State(initialValue: model)
    }

    /// Read the current route when appearing; a reused destination can retain old initializer arguments.
    private var requestedStart: NoteStartAction? {
        guard case .note(_, _, let start)? = router.path.last(where: { $0.noteID == noteID }) else { return nil }
        return start
    }

    private var note: Note? { model.note }
    private var job: Job? { model.job }
    /// Why the transcript cannot be changed now.
    private var readOnly: ReadOnlyReason? { model.readOnly }

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
        .task(id: model.playerKey) { model.updatePlayer() }
        .task(id: job.map { "\($0.state)-\($0.doneMs)" }) { await model.loadSavedDraft() }
        .onDisappear { model.disappeared() }
        .onAppear { model.appeared(start: requestedStart) }
        .onChange(of: router.session(noteID).opening) { _, _ in
            // The reused destination can still carry its previous route arguments during this update.
            guard case .note(_, let query, let start)? = router.path.last(where: { $0.noteID == noteID }) else { return }
            model.reopened(query: query, start: start)
        }
        .onChange(of: NoteScreenState.isGone(note)) { _, gone in if gone { router.close(noteID: noteID) } }
        .onChange(of: model.screen.search?.query) { _, query in router.keepSearch(query, for: noteID) }
        .backButtonTitle(router.below(noteID: noteID) == .library ? MeetingPhase1Copy.allMeetings : nil,
                         accessibilityLabel: router.below(noteID: noteID) == .library ? MeetingPhase1Copy.backToAllMeetings : nil)
        .noteSheetsAndDialogs(model: model)
        .keepsNoteOverlay(noteID: noteID, note: note, readOnly: readOnly, sheet: $model.sheet, draft: $model.sheetDraft,
                          dialog: $model.screen.dialog)
        .shareSheet(item: $model.shareItem)
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
                ProcessingBody(model: model, cache: cache) {
                    NoteHeader(note: note, subtitle: subtitle)
                    NoteSectionView(section: .card, note: note, mode: mode, model: model)
                } banners: {
                    NoteSectionView(section: .banners, note: note, mode: mode, model: model)
                }
            } else {
                NoteReadingScroll(note: note, mode: mode, transcript: transcript, subtitle: subtitle, matches: matches,
                                  current: current, model: model, cache: cache,
                                  actions: transcriptActions, suggestion: { suggestionCard($0, in: transcript) },
                                  titleVisibilityChanged: { headerTitleVisible = $0 })
            }
        }
        .overlay(alignment: .topLeading) {
            if let speechModels = processing.speechModels {
                // The diagnostics callback precedes .ended. Its flag alone does not mean the reading banners exist.
                if speechModels.suggestion.completedWhistle {
                    if mode.showsReading {
                        UITestStateMarker(identifier: "noteSuggestionDecision", value: "completed")
                    }
                } else if case .audioOnly = mode {
                    UITestStateMarker(identifier: "noteSuggestionDecision", value: "no-result")
                }
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
                    NotePlayerBar(note: note, markMoment: { model.markMoment(at: $0) })
                }
            }
            .animation(.default, value: model.screen.follow)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if !headerTitleVisible, mode != .processing {
                    Text(note.title).font(.headline).foregroundStyle(Color.ink).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("noteCompactTitle")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if mode == .reading, !transcript.isEmpty {
                    Button(NoteCopy.searchInTranscript, systemImage: "magnifyingglass") { model.screen.openSearch() }
                        .accessibilityIdentifier("searchTranscript")
                }
                NoteMenu(note: note, transcribeRow: TranscribeRow.of(note, job: job), transcribeAction: model.transcribeAction,
                         exportingDocument: model.exportingDocument,
                         perform: { model.perform($0) })
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
            wordTap: { model.run(model.screen.wordTapped($0, in: cache.shownSealed)) },
            playTurn: { model.run(model.screen.playTurn($0, in: cache.shownSealed)) },
            nameSpeaker: { model.speakerTapped($0) },
            editPassage: { model.editPassage($0) },
            markMoment: { model.markMoment(at: $0) })
    }

    /// "Is this Luca?" above the first paragraph of a placeholder speaker a saved voice may be.
    private func suggestionCard(_ turn: NoteTurn, in transcript: NoteTranscript) -> AnyView? {
        guard readOnly == nil, !turn.allSuggestions.isEmpty else { return nil }
        return AnyView(VStack(spacing: 12) {
            ForEach(turn.allSuggestions, id: \.byteSpeakerID) { suggestion in
                let ordinal = transcript.speakers.firstIndex { Data($0.utf8) == Data(suggestion.speakerID.utf8) } ?? 0
                SuggestionCard(suggestion: suggestion, ordinal: ordinal, tint: transcript.speakerTint(for: suggestion.speakerID) ?? .stone, model: model)
            }
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
    @Environment(ProcessingStore.self) private var processing

    private var noteID: UUID { note.id }

    var body: some View {
        switch section {
        case .card:
            if case .queued(let ahead, _) = mode {
                ProcessingCard(note: note, ahead: ahead, model: model)
            } else {
                ProcessingCard(note: note, model: model)
            }
        case .chips:
            if let chips = NoteChips.of(note), chips.trust != nil || chips.version != nil {
                NoteChipsRow(chips: chips, toggleTrust: { model.screen.toggleTrust() },
                             openVersions: { model.versionsTapped() })
            }
        case .banners:
            RecordingNotices(noteID: noteID)
            if let speechModels = processing.speechModels, mode.showsReading {
                ParakeetSuggestionView(store: speechModels, placement: .afterWhistle)
            }
            NoteBannersView(note: note, job: model.job, mode: mode, facts: bannerFacts,
                            act: { _, action in model.bannerAction(action) },
                            dismiss: { model.dismiss($0) })
        }
    }

    private var bannerFacts: NoteBannerFacts {
        let state = processing.state
        let speakerDownload = NoteBanners.speakerDownloadState(processing.models.status(of: .speakers))
        return NoteBannerFacts(trustToggled: model.screen.trustToggled, queueHold: state.hold, waitingJobs: state.queue.count,
                               dismissed: model.screen.dismissed, speechInstallBytes: installBytes.speech,
                               speakersInstallBytes: installBytes.speakers,
                               speechUnavailableText: processing.models.speechUnavailability == .model ? NoteCopy.speechUnavailable : nil,
                               speakerModelsMissing: speakerDownload.missing, speakerModelsInstalling: speakerDownload.installing)
    }

    /// The free-space figures of a model download that failed for want of room: Parakeet's (nil keeps the estimate of
    /// Apple's assets) and the speaker models' (an Identify speakers). Read only for that banner: they look at the
    /// model files.
    private var installBytes: (speech: Int64?, speakers: Int64?) {
        guard case .download(.notEnoughStorage)? = model.job?.failure else { return (nil, nil) }
        let models = processing.models
        return (models.speechRecognizer == .parakeet ? models.speechInstallBytes : nil, models.speakersInstallBytes)
    }
}
