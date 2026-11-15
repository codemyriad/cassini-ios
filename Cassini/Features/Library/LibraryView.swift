import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The Library: pinned native search, existing filters and notices, then day groups or highlighted meeting results.
/// Import audio and Record stay at the bottom; no decorative privacy or meeting-progress card.
struct LibraryView: View {
    @Environment(LibraryScreenModel.self) private var model
    @Environment(NoticesStore.self) private var notices
    @Environment(ImportStore.self) private var imports
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(ErrorPresenter.self) private var errors
    @Environment(\.calendar) private var calendar
    @Environment(\.restoresSceneState) private var restoresSceneState
    @SceneStorage("library.query") private var savedQuery = ""
    /// The open dialog (Rename, Start over?, Transcribe again?) and the title typed into Rename, kept with the scene.
    @SceneStorage("library.dialog") private var savedDialog: Data?
    @State private var renameDraft: String?
    @State private var importing = false
    @State private var searchPresented = false
    @State private var listPosition = ScrollPosition()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var searchGlass
    @State private var restored = false
    @State private var dialogRestored = false
    @State private var editMode: EditMode = .inactive
    @State private var selectedNotes: Set<UUID> = []
    @State private var archiveExport = ArchiveExportModel()
    @State private var exportTarget: ExportTarget?
    @State private var confirmedExport: (UUID, ExportSheetState.Choice)?

    var body: some View {
        @Bindable var model = model
        let content = model.content
        let exportable = Set(ArchiveSelection.ids(library.notes))
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.row) {
                if content.facts.liveNotes > 0 || model.favoritesOnly || searchPresented || model.isSearching {
                    filters.padding(.top, 6)
                }
                if model.isSearching, let count = content.facts.results {
                    Text(LibraryPhase1Copy.template("format.searchCount.meetings", count: count))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("librarySearchCount")
                }
                activity.padding(.top, 6)
                ImportCardsView()
                if !content.loading || content.emptyState == .unavailable {
                    if let hero = content.hero, !model.favoritesOnly { FirstRunHeroView(hero: hero) }
                    // Banners cover no-match and unavailable states; the empty Library uses the Wave 5 hero and Starred has its own.
                    if content.emptyState == .noStarred { NoStarredState().padding(.top, 8) }
                    // LazyVStack can retain a covered row body for an unchanged UUID even after the
                    // model publishes new capture/job facts. Key the stateless drawing by its presentation;
                    // navigation, selection and actions still use the stable note UUID.
                    if let results = content.results {
                        ForEach(results, id: \.self) { row($0, day: $0.day ?? .today, exportable: exportable.contains($0.id)) }
                    } else {
                        ForEach(content.sections) { section in
                            Text(LibraryFormat(calendar: calendar).day(section.key).uppercased())
                                .font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(Color.muted)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.top, 14)
                            ForEach(section.rows, id: \.self) { row($0, day: section.key, exportable: exportable.contains($0.id)) }
                        }
                    }
                }
            }
            // iOS 18 otherwise retains ordinary row bodies when the same notes become flat search results.
            .id(content.results != nil)
            .padding(.horizontal, Spacing.gutter).padding(.top, 12).padding(.bottom, 28)
            .readableWidth()
        }
        .accessibilityIdentifier("libraryScroll")
        .meetingScrollEdge()
        .scrollDismissesKeyboard(.immediately)
        .scrollPosition($listPosition)
        .overlay(alignment: .topLeading) { UITestInteractiveMarker(loaded: library.isLoaded && !content.loading) }
        .trashUndoSnackbar()
        .background(Color.paper)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CaptureBar(unavailable: content.emptyState == .unavailable) { importing = true }
        }
        .librarySearchBar { searchHeader }
        .navigationTitle(MeetingPhase1Copy.allMeetings)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: restoreSceneState)
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { _, mode in if !mode.isEditing { selectedNotes.removeAll() } }
        .onChange(of: exportable) { _, eligible in
            selectedNotes.formIntersection(eligible)
            if eligible.isEmpty { editMode = .inactive }
        }
        .shareSheet(item: $archiveExport.shareItem)
        .onChange(of: model.query) { _, query in
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { searchPresented = true }
            if restoresSceneState { savedQuery = query }
        }
        .onChange(of: searchPresented) { _, presented in
            if presented { model.beginSearch(); listPosition.scrollTo(edge: .top) } else { model.closeSearch() }
        }
        .onChange(of: model.searched) { _, _ in
            if searchPresented { listPosition.scrollTo(edge: .top) }
        }
        .onChange(of: model.dialog) { _, dialog in
            if dialog == nil { renameDraft = nil }
            keepDialog()
        }
        .onChange(of: renameDraft) { _, _ in keepDialog() }
        // The dialog's note must be read first.
        .task(id: library.isLoaded) { restoreDialog() }
        .task { await model.refreshSpeakerModels() }
        .fileImporter(isPresented: $importing, allowedContentTypes: ImportStore.contentTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): imports.start(urls)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { errors.present(error.localizedDescription) }
            }
        }
        .sheet(item: $exportTarget, onDismiss: shareConfirmedExport) { target in
            if let note = model.note(target.id), let menu = model.menu(target.id) {
                ExportFormatSheet(note: note, jobPending: menu.transcribe == .stop || menu.transcribe == .removeFromQueue) {
                    confirmedExport = (target.id, $0)
                }
            }
        }
        .sheet(item: renaming) { RenameNoteDialog(noteID: $0.id, draft: renameDraft) { renameDraft = $0 } }
        .alert(LibraryCopy.startOverTitle, isPresented: confirming(\.startOver), presenting: model.dialog) { dialog in
            Button(LibraryCopy.startOver, role: .destructive) { confirm(dialog) }
            Button(LibraryCopy.cancel, role: .cancel) {}
        } message: { _ in Text(LibraryCopy.startOverBody) }
        .alert(LibraryCopy.freshTitle, isPresented: confirming(\.transcribeFresh), presenting: model.dialog) { dialog in
            Button(LibraryCopy.transcribeAgain) { confirm(dialog) }
            Button(LibraryCopy.cancel, role: .cancel) {}
        } message: { _ in Text(LibraryCopy.freshBody) }
    }

    @ViewBuilder private var searchHeader: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    searchControls
                }
            } else {
                searchControls
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .readableWidth()
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: searchPresented)
    }

    private var searchControls: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            SearchField(query: $model.query, isPresented: $searchPresented)
                .frame(maxWidth: .infinity)
            searchActions
        }
    }

    @ViewBuilder private var searchActions: some View {
        if #available(iOS 26.0, *) {
            searchButtons.glassEffect(.regular, in: Capsule())
                .glassEffectID("libraryActions", in: searchGlass)
        } else {
            searchButtons.background(.regularMaterial, in: Capsule())
        }
    }

    private var searchButtons: some View {
        ZStack {
            if searchPresented {
                Button(LibraryPhase1Copy.close, systemImage: "xmark") {
                    model.closeSearch()
                    searchPresented = false
                }
                .accessibilityIdentifier("closeLibrarySearch")
                .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    Button(TrashCopy.title, systemImage: "trash") { router.show(.trash) }
                        .accessibilityIdentifier("recentlyDeletedButton")
                    Button(LibraryCopy.settings, systemImage: "slider.horizontal.3") { router.show(.settings) }
                        .accessibilityIdentifier("settingsButton")
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: searchPresented)
        .labelStyle(.iconOnly).font(.system(size: 20)).foregroundStyle(Color.ink)
        .buttonStyle(LibraryHeaderButtonStyle())
        .padding(2).frame(width: searchPresented ? 48 : 92, height: 48)
    }

    /// All real notices, the recording card, standalone downloads and import/export progress stay available.
    /// The Wave 5 first-run hero replaces the `LIB_EMPTY` banner (`L-27`).
    @ViewBuilder private var activity: some View {
        BannerList(specs: notices.library(model.content.facts).filter { $0.kind != .libEmpty },
                   onAction: { spec, action in notices.perform(action, on: spec) { importing = true } },
                   onDismiss: notices.dismiss)
        LibraryActivity()
        ImportBatchesView()
        ArchiveExportProgressView(model: archiveExport)
    }

    private var filters: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            if searchPresented || model.isSearching {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterButton(LibraryPhase1Copy.searchStarred, symbol: "star", selected: model.searchStarred) {
                            model.searchStarred.toggle()
                        }
                        Menu {
                            Button(LibraryPhase1Copy.anySpeaker) { model.searchSpeaker = nil }
                            ForEach(model.searchSpeakers, id: \.self) { name in
                                Button(name) { model.searchSpeaker = name }
                            }
                        } label: {
                            chipLabel(model.searchSpeaker.map { LibraryPhase1Copy.speakerTemplate.replacingOccurrences(of: "{name}", with: $0) }
                                      ?? LibraryPhase1Copy.speakerNone, selected: model.searchSpeaker != nil)
                        }.accessibilityIdentifier("librarySearchSpeaker")
                        Menu {
                            ForEach(SearchDate.allCases, id: \.self) { date in
                                Button { model.searchDate = date } label: {
                                    if model.searchDate == date { Label(dateTitle(date), systemImage: "checkmark") }
                                    else { Text(dateTitle(date)) }
                                }
                            }
                        } label: {
                            chipLabel(dateTitle(model.searchDate), selected: model.searchDate != .any)
                        }.accessibilityIdentifier("librarySearchDate")
                        filterButton(LibraryPhase1Copy.recordedByMe, selected: model.recordedByMe) { model.recordedByMe.toggle() }
                            .accessibilityIdentifier("libraryRecordedByMe")
                    }
                }.accessibilityIdentifier("librarySearchFilters")
            } else {
                HStack {
                    Picker(LibraryPhase1Copy.filtersAccessibilityLabel, selection: $model.favoritesOnly) {
                        Text(LibraryPhase1Copy.all).tag(false)
                        Text(LibraryPhase1Copy.starred).tag(true)
                    }.pickerStyle(.segmented)
                    ArchiveExportControls(selectedNotes: $selectedNotes, archiveExport: archiveExport)
                }
            }
        }
    }

    private func chipLabel(_ title: String, selected: Bool) -> some View {
        Text(title).font(.subheadline.weight(.medium)).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14).frame(minHeight: HitTarget.minimum)
            .foregroundStyle(selected ? Color.paper : Color.muted)
            .background(selected ? Color.ink : Color.ink.opacity(0.1), in: Capsule())
    }

    private func dateTitle(_ date: SearchDate) -> String {
        switch date {
        case .any: LibraryPhase1Copy.anyDate
        case .today: LibraryPhase1Copy.today
        case .week: LibraryPhase1Copy.pastWeek
        case .month: LibraryPhase1Copy.pastMonth
        case .year: LibraryPhase1Copy.thisYear
        }
    }

    private func filterButton(_ title: String, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { if let symbol { Image(systemName: symbol) }; Text(title) }
                .font(.subheadline.weight(.medium)).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14).frame(minHeight: HitTarget.minimum)
                .foregroundStyle(selected ? Color.paper : Color.muted)
                .background(selected ? Color.ink : Color.ink.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ row: LibraryRow, day: DayKey, exportable: Bool) -> some View {
        HStack {
            if editMode.isEditing && exportable {
                Button {
                    if !selectedNotes.insert(row.id).inserted { selectedNotes.remove(row.id) }
                } label: { Image(systemName: selectedNotes.contains(row.id) ? "checkmark.circle.fill" : "circle").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel(row.title)
                .accessibilityIdentifier("selectArchiveNote-\(row.id)")
                .accessibilityAddTraits(selectedNotes.contains(row.id) ? [.isSelected] : [])
            }
            NoteRow(row: row, day: day, selected: router.selectedNoteID == row.id) { action in
            switch action {
            case .open: model.open(row.id)
            case .resume: Task { await model.resume(row.id) }
            case .rename: Task { await model.perform(.rename, on: row.id) }
            case .trash: Task { await model.perform(.moveToTrash, on: row.id) }
            }
            }
            .contextMenu { NoteActionsMenu(noteID: row.id) { exportTarget = ExportTarget(id: row.id) } }
        }
    }


    /// The presented confirmation's action; the model clears the dialog.
    private func confirm(_ dialog: LibraryDialog) { Task { await model.confirm(dialog) } }

    private func restoreSceneState() {
        if model.isSearching { searchPresented = true }
        guard restoresSceneState, !restored else { return }
        restored = true
        if !savedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { searchPresented = true }
        model.query = savedQuery
    }

    /// Opens the dialog the scene kept, once the notes are read, unless its note has gone meanwhile.
    private func restoreDialog() {
        guard restoresSceneState, library.isLoaded, !dialogRestored else { return }
        dialogRestored = true
        guard model.dialog == nil else { return }
        guard let kept = SavedLibraryDialog(savedDialog)?.restored(over: library.notes) else {
            savedDialog = nil
            return
        }
        renameDraft = kept.draft
        model.dialog = kept.dialog
    }

    private func keepDialog() {
        guard restoresSceneState, dialogRestored else { return }
        savedDialog = model.dialog.flatMap { SavedLibraryDialog($0, draft: renameDraft).encoded }
    }

    // Present on the persistent Library, since the context menu disappears before the selector opens.
    private func shareConfirmedExport() {
        guard let (id, choice) = confirmedExport else { return }
        confirmedExport = nil
        let action: NoteAction
        if let format = choice.transcriptFormat { action = .export(format) }
        else if choice == .originalAudio { action = .shareAudio }
        else { action = .exportDocument }
        Task { await model.perform(action, on: id) }
    }

    private struct ExportTarget: Identifiable { let id: UUID }

    private struct RenameTarget: Identifiable { let id: UUID }

    private var renaming: Binding<RenameTarget?> {
        Binding(get: { if case .rename(let id) = model.dialog { RenameTarget(id: id) } else { nil } },
                set: { if $0 == nil, case .rename = model.dialog { model.dismissDialog() } })
    }

    private func confirming(_ kind: KeyPath<LibraryDialog, Bool>) -> Binding<Bool> {
        Binding(get: { model.dialog?[keyPath: kind] ?? false }, set: { if !$0, model.dialog?[keyPath: kind] == true { model.dismissDialog() } })
    }
}

private extension View {
    /// Native bars let content fade beneath the glass; older systems keep their material inset.
    @ViewBuilder func librarySearchBar<Header: View>(@ViewBuilder content: () -> Header) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .top, spacing: 0, content: content)
        }
    }
}

private extension LibraryDialog {
    var startOver: Bool { if case .startOver = self { true } else { false } }
    var transcribeFresh: Bool { if case .transcribeFresh = self { true } else { false } }
}

/// Native Edit/Done keeps its system localization, with a full target inside the button label.
