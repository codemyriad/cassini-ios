import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The Library (board 00, features.md section 1): the wordmark, the search with the privacy line, the activity area
/// (the banners, the recording card, the transcription banner), then the day sections or, while searching, the
/// flat results. Import audio and Record are pinned to the bottom.
struct LibraryView: View {
    @Environment(LibraryScreenModel.self) private var model
    @Environment(NoticesStore.self) private var notices
    @Environment(ImportStore.self) private var imports
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(ErrorPresenter.self) private var errors
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.restoresSceneState) private var restoresSceneState
    @SceneStorage("library.query") private var savedQuery = ""
    @SceneStorage("library.favoritesOnly") private var savedFavoritesOnly = false
    /// The open dialog (Rename, Start over?, Transcribe again?) and the title typed into Rename, kept with the scene.
    @SceneStorage("library.dialog") private var savedDialog: Data?
    @State private var renameDraft: String?
    @State private var importing = false
    @State private var restored = false
    @State private var dialogRestored = false

    var body: some View {
        @Bindable var model = model
        let content = model.content
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.row) {
                header.padding(.bottom, 8)
                SearchField(query: $model.query)
                filters.padding(.top, 6)
                activity(content.facts).padding(.top, 6)
                LibraryRows()
            }
            .padding(.horizontal, Spacing.gutter).padding(.top, 12).padding(.bottom, 28)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.paper)
        .overlay(alignment: .topLeading) { UITestInteractiveMarker(loaded: library.isLoaded && !content.loading) }
        .trashUndoSnackbar()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CaptureBar(unavailable: content.emptyState == .unavailable) { importing = true }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 8) { OrbitMark(size: 25); // The wordmark sets the name in lower case; VoiceOver reads it as written.
                    Text(verbatim: ProductName.full.lowercased()).font(.system(.title3, design: .rounded, weight: .semibold)).tracking(-0.6) }
                    .foregroundStyle(Color.ink).fixedSize().accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(verbatim: ProductName.full))
                    .accessibilityAddTraits(.isHeader).accessibilityShowsLargeContentViewer()
                    .accessibilityIdentifier("wordmark")
            }.sharedBackgroundHidden()
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(TrashCopy.title, systemImage: "trash") { router.show(.trash) }
                    .accessibilityIdentifier("recentlyDeletedButton")
                Button(LibraryCopy.settings, systemImage: "slider.horizontal.3") { router.show(.settings) }
                    .accessibilityIdentifier("settingsButton")
            }
        }
        .onAppear(perform: restoreSceneState)
        .onChange(of: model.query) { _, query in if restoresSceneState { savedQuery = query } }
        .onChange(of: model.favoritesOnly) { _, only in if restoresSceneState { savedFavoritesOnly = only } }
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
            case .failure(let error): errors.present(error.localizedDescription)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dynamicType.isAccessibilitySize ? LibraryCopy.headlineLarge : LibraryCopy.headline)
                .font(.system(.largeTitle, design: .serif)).tracking(-1).foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            if !dynamicType.isAccessibilitySize { Text(LibraryCopy.subheadline).font(.subheadline).foregroundStyle(Color.muted) }
        }.padding(.top, 18)
    }

    /// The banners (NoticeCenter's notices and the list's own states), the recording card and the transcription banner.
    @ViewBuilder private func activity(_ facts: LibraryFacts) -> some View {
        BannerList(specs: notices.library(facts),
                   onAction: { spec, action in notices.perform(action, on: spec) { importing = true } },
                   onDismiss: notices.dismiss)
        LibraryActivity()
    }

    /// All and Starred (an iOS extra), with the number of notes shown.
    private var filters: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                filterButton(LibraryCopy.all, selected: !model.favoritesOnly) { model.favoritesOnly = false }
                filterButton(LibraryCopy.starred, symbol: "star", selected: model.favoritesOnly) { model.favoritesOnly = true }
                Spacer()
            }
            if model.isSearching {
                Menu {
                    ForEach(SearchDate.allCases, id: \.self) { date in
                        Button {
                            model.searchDate = date
                        } label: {
                            if model.searchDate == date { Label(dateTitle(date), systemImage: "checkmark") }
                            else { Text(dateTitle(date)) }
                        }
                    }
                } label: {
                    Label(dateTitle(model.searchDate), systemImage: "calendar")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).frame(minHeight: HitTarget.minimum)
                        .foregroundStyle(model.searchDate == .any ? Color.muted : Color.paper)
                        .background(model.searchDate == .any ? Color.clear : Color.ink, in: Capsule())
                        .overlay(Capsule().stroke(Color.muted.opacity(0.3), lineWidth: 1))
                }
                .accessibilityIdentifier("librarySearchDate")
            }
        }
    }

    private func dateTitle(_ date: SearchDate) -> String {
        switch date {
        case .any: LibraryCopy.anyDate
        case .today: LibraryCopy.today
        case .week: LibraryCopy.pastWeek
        case .month: LibraryCopy.pastMonth
        }
    }

    private func filterButton(_ title: String, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { if let symbol { Image(systemName: symbol) }; Text(title) }
                .font(.subheadline.weight(.medium)).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14).frame(minHeight: HitTarget.minimum)
                .foregroundStyle(selected ? Color.paper : Color.muted)
                .background(selected ? Color.ink : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The presented confirmation's action; the model clears the dialog.
    private func confirm(_ dialog: LibraryDialog) { Task { await model.confirm(dialog) } }

    private func restoreSceneState() {
        guard restoresSceneState, !restored else { return }
        restored = true
        model.query = savedQuery
        model.favoritesOnly = savedFavoritesOnly
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

    private struct RenameTarget: Identifiable { let id: UUID }

    private var renaming: Binding<RenameTarget?> {
        Binding(get: { if case .rename(let id) = model.dialog { RenameTarget(id: id) } else { nil } },
                set: { if $0 == nil, case .rename = model.dialog { model.dismissDialog() } })
    }

    private func confirming(_ kind: KeyPath<LibraryDialog, Bool>) -> Binding<Bool> {
        Binding(get: { model.dialog?[keyPath: kind] ?? false }, set: { if !$0, model.dialog?[keyPath: kind] == true { model.dismissDialog() } })
    }
}

private extension LibraryDialog {
    var startOver: Bool { if case .startOver = self { true } else { false } }
    var transcribeFresh: Bool { if case .transcribeFresh = self { true } else { false } }
}

private extension ToolbarContent {
    /// Keeps the item out of iOS 26's shared glass background; earlier systems draw no background behind bar items.
    @ToolbarContentBuilder func sharedBackgroundHidden() -> some ToolbarContent {
        if #available(iOS 26.0, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}
