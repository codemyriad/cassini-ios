import SwiftUI
import UniformTypeIdentifiers
import CassiniEngine
import CassiniNotebook

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NoticesStore.self) private var notices
    @Environment(ImportStore.self) private var imports
    @Environment(RecordingStore.self) private var recording
    @Environment(Router.self) private var router
    @Environment(ErrorPresenter.self) private var errors
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.calendar) private var calendar
    @Environment(\.clock) private var clock
    @Environment(\.restoresSceneState) private var restoresSceneState
    @SceneStorage("library.query") private var savedQuery = ""
    @SceneStorage("library.favoritesOnly") private var savedFavoritesOnly = false
    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var importing = false

    private var visible: [Note] {
        library.notes.filter { $0.trashedAt == nil && (!favoritesOnly || $0.isFavorite) && $0.matches(query) }
    }
    private var grouped: [(Date, [Note])] {
        Dictionary(grouping: visible, by: { calendar.startOfDay(for: $0.createdAt) })
            .sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                header
                SearchField(query: $query)
                filters
                ForEach(notices.notices) { notice in
                    HStack(alignment: .top) {
                        NoticeCard(title: notice.text)
                        Button { notices.dismiss(notice.id) } label: { Image(systemName: "xmark").frame(width: 32, height: HitTarget.minimum) }
                            .accessibilityLabel("Dismiss notice")
                    }
                }
                QueueHeldBanner()
                if recording.state.isActive { ActiveRecordingCard() }
                if imports.isImporting { Label("Importing audio…", systemImage: "arrow.down.doc").font(.subheadline).foregroundStyle(Color.muted) }
                if visible.isEmpty { LibraryEmptyState(query: query, favoritesOnly: favoritesOnly) }
                else {
                    ForEach(grouped, id: \.0) { date, notes in
                        VStack(alignment: .leading, spacing: Spacing.row) {
                            Text(dayLabel(date).uppercased()).font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(Color.muted)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(notes) { note in
                                Button { open(note) } label: { NoteRow(note: note, query: query) }
                                    .buttonStyle(.plain)
                                    .contextMenu { NoteActionsMenu(note: note) }
                            }
                        }
                    }
                }
                Label("On-device transcription. Your words stay yours.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(Color.muted).frame(maxWidth: .infinity).padding(.top, 12)
            }
            .padding(.horizontal, Spacing.gutter).padding(.top, 12).padding(.bottom, 28)
            .frame(maxWidth: ReadableWidth.library).frame(maxWidth: .infinity)
        }
        .background(Color.paper)
        .safeAreaInset(edge: .bottom, spacing: 0) { CaptureBar(importing: $importing) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 8) { OrbitMark(size: 25); Text("cassini").font(.system(.title3, design: .rounded, weight: .semibold)).tracking(-0.6) }
                    .foregroundStyle(Color.ink).fixedSize().accessibilityElement(children: .combine).accessibilityLabel("Cassini")
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Recently Deleted", systemImage: "trash") { router.show(.trash) }
                Button("Settings", systemImage: "slider.horizontal.3") { router.show(.settings) }
            }
        }
        .onAppear {
            guard restoresSceneState else { return }
            query = savedQuery
            favoritesOnly = savedFavoritesOnly
        }
        .onChange(of: query) { _, query in if restoresSceneState { savedQuery = query } }
        .onChange(of: favoritesOnly) { _, favoritesOnly in if restoresSceneState { savedFavoritesOnly = favoritesOnly } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await imports.importAudio(url) } }
            case .failure(let error): errors.present(error.localizedDescription)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dynamicType.isAccessibilitySize ? "Recordings" : "A little more present.").font(.system(.largeTitle, design: .serif)).tracking(-1).foregroundStyle(Color.ink)
            if !dynamicType.isAccessibilitySize { Text("Keep the conversation. Find the important parts.").font(.subheadline).foregroundStyle(Color.muted) }
        }.padding(.top, 18)
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                filterButton(dynamicType.isAccessibilitySize ? "All" : "All recordings", selected: !favoritesOnly) { favoritesOnly = false }
                filterButton("Starred", symbol: "star", selected: favoritesOnly) { favoritesOnly = true }
                Spacer()
                Text("\(visible.count)").font(.caption.monospacedDigit()).foregroundStyle(Color.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                filterButton("All", selected: !favoritesOnly) { favoritesOnly = false }
                filterButton("Starred", symbol: "star", selected: favoritesOnly) { favoritesOnly = true }
            }
        }
    }

    private func filterButton(_ title: String, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { if let symbol { Image(systemName: symbol) }; Text(title) }
                .font(.subheadline.weight(.medium)).fixedSize(horizontal: true, vertical: false).padding(.horizontal, 14).padding(.vertical, 11)
                .foregroundStyle(selected ? Color.paper : Color.muted)
                .background(selected ? Color.ink : Color.clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func open(_ note: Note) {
        if note.isRecording { router.presentRecording() } else { router.show(.note(note.id)) }
    }

    private func dayLabel(_ date: Date) -> String {
        let today = calendar.startOfDay(for: clock.now)
        if date == today { return "Today" }
        if calendar.date(byAdding: .day, value: -1, to: today) == date { return "Yesterday" }
        var style = Date.FormatStyle.dateTime.month(.wide).day().year()
        style.calendar = calendar; style.timeZone = calendar.timeZone
        if let locale = calendar.locale { style.locale = locale }
        return date.formatted(style)
    }
}
