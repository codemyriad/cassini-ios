import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The Library (board 00, features.md section 1): the wordmark, the search with the privacy line, the activity area
/// (notices, the recording card, the transcription banner, imports), then the day sections or, while searching, the
/// flat results. Import audio and Record are pinned to the bottom.
struct LibraryView: View {
    @Environment(LibraryScreenModel.self) private var model
    @Environment(NoticesStore.self) private var notices
    @Environment(ImportStore.self) private var imports
    @Environment(ProcessingStore.self) private var processing
    @Environment(RecordingStore.self) private var recording
    @Environment(TrashService.self) private var trash
    @Environment(Router.self) private var router
    @Environment(ErrorPresenter.self) private var errors
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.calendar) private var calendar
    @Environment(\.restoresSceneState) private var restoresSceneState
    @SceneStorage("library.query") private var savedQuery = ""
    @SceneStorage("library.favoritesOnly") private var savedFavoritesOnly = false
    @State private var importing = false
    @State private var dialog: LibraryDialog?
    @State private var voiceModelReady = false
    @State private var restored = false

    var body: some View {
        @Bindable var model = model
        let content = model.content
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.row) {
                header.padding(.bottom, 8)
                SearchField(query: $model.query)
                filters.padding(.top, 6)
                activity.padding(.top, 6)
                if !content.loading || content.emptyState == .unavailable {
                    if let state = content.emptyState {
                        LibraryEmptyStateView(state: state, record: record, importAudio: { importing = true })
                            .padding(.top, 8)
                    }
                    if let results = content.results {
                        ForEach(results) { row($0, day: $0.day ?? .today) }
                    } else {
                        ForEach(content.sections) { section in
                            Text(LibraryFormat(calendar: calendar).day(section.key).uppercased())
                                .font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(Color.muted)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.top, 14)
                            ForEach(section.rows) { row($0, day: section.key) }
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.gutter).padding(.top, 12).padding(.bottom, 28)
            .frame(maxWidth: ReadableWidth.library).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.paper)
        .trashUndoSnackbar()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CaptureBar(unavailable: content.emptyState == .unavailable) { importing = true }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 8) { OrbitMark(size: 25); Text(verbatim: "cassini").font(.system(.title3, design: .rounded, weight: .semibold)).tracking(-0.6) }
                    .foregroundStyle(Color.ink).fixedSize().accessibilityElement(children: .combine).accessibilityLabel(Text(verbatim: "Cassini"))
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(TrashCopy.title, systemImage: "trash") { router.show(.trash) }
                Button(LibraryCopy.settings, systemImage: "slider.horizontal.3") { router.show(.settings) }
            }
        }
        .onAppear(perform: restoreSceneState)
        .onChange(of: model.query) { _, query in if restoresSceneState { savedQuery = query } }
        .onChange(of: model.favoritesOnly) { _, only in if restoresSceneState { savedFavoritesOnly = only } }
        .task { voiceModelReady = await processing.speakerModelsReady() }
        .fileImporter(isPresented: $importing, allowedContentTypes: ImportStore.contentTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): imports.start(urls)
            case .failure(let error): errors.present(error.localizedDescription)
            }
        }
        .sheet(item: renaming) { RenameNoteDialog(noteID: $0.id) }
        .alert(LibraryCopy.startOverTitle, isPresented: confirming(\.startOver), presenting: dialog) { dialog in
            Button(LibraryCopy.startOver, role: .destructive) { if case .startOver(let id) = dialog { startOver(id) } }
            Button(LibraryCopy.cancel, role: .cancel) {}
        } message: { _ in Text(LibraryCopy.startOverBody) }
        .alert(LibraryCopy.freshTitle, isPresented: confirming(\.transcribeFresh), presenting: dialog) { dialog in
            Button(LibraryCopy.transcribeAgain) {
                if case .transcribeFresh(let id) = dialog { Task { await model.transcribe(id, kind: .transcribeAgain) } }
            }
            Button(LibraryCopy.cancel, role: .cancel) {}
        } message: { _ in Text(LibraryCopy.freshBody) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dynamicType.isAccessibilitySize ? LibraryCopy.headlineLarge : LibraryCopy.headline)
                .font(.system(.largeTitle, design: .serif)).tracking(-1).foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            if !dynamicType.isAccessibilitySize { Text(LibraryCopy.subheadline).font(.subheadline).foregroundStyle(Color.muted) }
        }.padding(.top, 18)
    }

    /// Notices, the queue hold, the recording card, the transcription banner and the imports.
    @ViewBuilder private var activity: some View {
        ForEach(notices.notices) { notice in
            HStack(alignment: .top) {
                NoticeCard(title: notice.text)
                Button { notices.dismiss(notice.id) } label: { Image(systemName: "xmark").frame(width: HitTarget.minimum, height: HitTarget.minimum) }
                    .accessibilityLabel(LibraryCopy.dismissNotice)
            }
        }
        QueueHeldBanner()
        LibraryActivity()
        ImportActivity()
    }

    /// All and Starred (an iOS extra), with the number of notes shown.
    private var filters: some View {
        @Bindable var model = model
        return HStack {
            filterButton(LibraryCopy.all, selected: !model.favoritesOnly) { model.favoritesOnly = false }
            filterButton(LibraryCopy.starred, symbol: "star", selected: model.favoritesOnly) { model.favoritesOnly = true }
            Spacer()
        }
    }

    private func filterButton(_ title: String, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { if let symbol { Image(systemName: symbol) }; Text(title) }
                .font(.subheadline.weight(.medium)).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14).frame(minHeight: HitTarget.minimum)
                .foregroundStyle(selected ? Color.paper : Color.muted)
                .background(selected ? Color.ink : Color.clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ row: LibraryRow, day: DayKey) -> some View {
        NoteRow(row: row, day: day) { action in
            switch action {
            case .open: model.open(row.id)
            case .resume: Task { await model.resume(row.id) }
            case .rename: dialog = .rename(row.id)
            case .trash: Task { await trash.requestTrash(row.id) }
            }
        }
        .contextMenu {
            if let note = model.note(row.id) { NoteActionsMenu(note: note, voiceModelReady: voiceModelReady, dialog: $dialog) }
        }
    }

    private func record() { Task { await recording.start() } }

    private func startOver(_ id: UUID) {
        Task {
            if await processing.startOver(id) == .needsConsent { router.show(.modelDownload(noteID: id)) }
        }
    }

    private func restoreSceneState() {
        guard restoresSceneState, !restored else { return }
        restored = true
        model.query = savedQuery
        model.favoritesOnly = savedFavoritesOnly
    }

    private struct RenameTarget: Identifiable { let id: UUID }

    private var renaming: Binding<RenameTarget?> {
        Binding(get: { if case .rename(let id) = dialog { RenameTarget(id: id) } else { nil } }, set: { if $0 == nil { dialog = nil } })
    }

    private func confirming(_ kind: KeyPath<LibraryDialog, Bool>) -> Binding<Bool> {
        Binding(get: { dialog?[keyPath: kind] ?? false }, set: { if !$0 { dialog = nil } })
    }
}

private extension LibraryDialog {
    var startOver: Bool { if case .startOver = self { true } else { false } }
    var transcribeFresh: Bool { if case .transcribeFresh = self { true } else { false } }
}
