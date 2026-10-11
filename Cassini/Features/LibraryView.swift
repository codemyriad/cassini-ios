import SwiftUI
import UniformTypeIdentifiers
import CassiniNotebook

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var importing = false
    @State private var settings = false
    @State private var trash = false
    private var visible: [Note] {
        store.notes.filter { $0.trashedAt == nil && (!favoritesOnly || $0.isFavorite) && $0.matches(query) }
    }
    private var grouped: [(Date, [Note])] {
        Dictionary(grouping: visible, by: { Calendar.current.startOfDay(for: $0.createdAt) })
            .sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }
    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    searchField
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
                    if let notice = store.notice {
                        HStack(alignment: .top) {
                            NoticeCard(title: notice)
                            Button { store.notice = nil } label: { Image(systemName: "xmark").frame(width: 32, height: 44) }.accessibilityLabel("Dismiss notice")
                        }
                    }
                    if store.recorder.isActive { activeRecording }
                    if store.isImporting { Label("Importing audio…", systemImage: "arrow.down.doc").font(.subheadline).foregroundStyle(Color.muted) }
                    if visible.isEmpty { emptyState }
                    else {
                        ForEach(grouped, id: \.0) { date, notes in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(dayLabel(date).uppercased()).font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(Color.muted)
                                ForEach(notes) { note in
                                    Button { if note.status == .recording { store.showingRecorder = true } else { store.selectedNote = note.id } } label: {
                                        NoteRow(note: note, query: query, processing: store.processingID == note.id ? store.processingProgress : nil)
                                    }.buttonStyle(.plain)
                                    .contextMenu {
                                        Button(note.isFavorite ? "Remove star" : "Star recording", systemImage: note.isFavorite ? "star.slash" : "star") { store.update(note.id) { $0.isFavorite.toggle() } }
                                        if note.status != .recording { Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) { store.trash(note.id) } }
                                    }
                                }
                            }
                        }
                    }
                    Label("On-device transcription. Your words stay yours.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(Color.muted).frame(maxWidth: .infinity).padding(.top, 12)
                }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 28).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .background(Color.paper)
            .safeAreaInset(edge: .bottom, spacing: 0) { captureBar }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) { OrbitMark(size: 25); Text("cassini").font(.system(.title3, design: .rounded, weight: .semibold)).tracking(-0.6) }
                        .foregroundStyle(Color.ink).fixedSize().accessibilityElement(children: .combine).accessibilityLabel("Cassini")
                }.sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Recently Deleted", systemImage: "trash") { trash = true }
                    Button("Settings", systemImage: "slider.horizontal.3") { settings = true }
                }
            }
            .navigationDestination(item: $store.selectedNote) { id in NoteDetailView(noteID: id) }
            .sheet(isPresented: $store.showingRecorder) { RecordingView().environment(store) }
            .sheet(isPresented: $settings) { SettingsView().environment(store) }
            .sheet(isPresented: $trash) { TrashView().environment(store) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { Task { await store.importAudio(url) } }
                case .failure(let error): store.errorMessage = error.localizedDescription
                }
            }
            .alert("Something needs attention", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
                if AVAudioApplicationPermission.denied { Button("Open Settings") { openSystemSettings() } }
            } message: { Text(store.errorMessage ?? "") }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dynamicType.isAccessibilitySize ? "Recordings" : "A little more present.").font(.system(.largeTitle, design: .serif)).tracking(-1).foregroundStyle(Color.ink)
            if !dynamicType.isAccessibilitySize { Text("Keep the conversation. Find the important parts.").font(.subheadline).foregroundStyle(Color.muted) }
        }.padding(.top, 18)
    }
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.muted)
            TextField("Search recordings and words", text: $query).font(.body).autocorrectionDisabled().accessibilityIdentifier("librarySearch")
            if !query.isEmpty { Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }.labelStyle(.iconOnly).foregroundStyle(Color.muted) }
        }.padding(15).background(Color.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.ink.opacity(0.07), lineWidth: 1))
    }
    private func filterButton(_ title: String, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { if let symbol { Image(systemName: symbol) }; Text(title) }
                .font(.subheadline.weight(.medium)).fixedSize(horizontal: true, vertical: false).padding(.horizontal, 14).padding(.vertical, 11)
                .foregroundStyle(selected ? Color.paper : Color.muted)
                .background(selected ? Color.ink : Color.clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var emptyState: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(Color.ember.opacity(0.06)).frame(width: 148, height: 148)
                Circle().stroke(Color.ember.opacity(0.1), lineWidth: 1).frame(width: 180, height: 180)
                OrbitMark(size: 88)
            }.padding(.top, 24)
            VStack(spacing: 10) {
                Text(query.isEmpty ? (favoritesOnly ? "Keep your favorites close." : "Good conversations\ndeserve to be kept.") : "No matching recordings.")
                    .font(.system(.title2, design: .serif)).multilineTextAlignment(.center).foregroundStyle(Color.ink)
                Text(query.isEmpty ? (favoritesOnly ? "Star a recording to find it here." : "Record a thought, an interview, or a meeting.\nTurn it into words you can come back to.") : "Try a different word or recording title.")
                    .font(.subheadline).foregroundStyle(Color.muted).multilineTextAlignment(.center)
            }
            if query.isEmpty && !favoritesOnly {
                HStack(spacing: 20) {
                    Label("Record", systemImage: "waveform")
                    Label("Transcribe", systemImage: "text.alignleft")
                    Label("Revisit", systemImage: "bookmark")
                }.font(.caption).foregroundStyle(Color.ember).padding(.top, 6)
            }
        }.frame(maxWidth: .infinity).padding(.bottom, 22)
    }
    private var activeRecording: some View {
        Button { store.showingRecorder = true } label: {
            HStack(spacing: 14) {
                Image(systemName: store.recorder.isPaused ? "pause.circle" : "waveform.circle.fill").font(.title).foregroundStyle(Color.ember)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.recorder.isPaused ? "Recording paused" : "Recording in progress").font(.headline)
                    Text("Tap to return").font(.caption).foregroundStyle(Color.muted)
                }
                Spacer(); Text(TimeText.clock(store.recorder.elapsed)).font(.body.monospacedDigit())
            }.padding(18).background(Color.card, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
    }
    private var captureBar: some View {
        let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 18))
        return layout {
            Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down").font(.subheadline.weight(.semibold)).frame(minWidth: 88, minHeight: 52) }
                .disabled(store.isImporting)
            Button { Task { await store.startRecording() } } label: {
                Label(store.recorder.isActive ? "Return to recording" : "Record", systemImage: store.recorder.isActive ? "waveform" : "mic.fill")
            }.buttonStyle(PrimaryButtonStyle()).disabled(store.isStartingRecording || store.isFinishingRecording).accessibilityIdentifier("recordButton")
        }.dynamicTypeSize(...DynamicTypeSize.accessibility1).padding(.horizontal, 24).padding(.vertical, 14).frame(maxWidth: 760).frame(maxWidth: .infinity)
            .background(.regularMaterial)
    }
    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.wide).day().year())
    }
}

struct NoteRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let note: Note
    var query = ""
    var processing: Double?
    var body: some View {
        let rowLayout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        VStack(alignment: .leading, spacing: 13) {
            rowLayout {
                Text(note.title).font(.system(.title3, design: .serif, weight: .medium)).foregroundStyle(Color.ink).lineLimit(2)
                if !dynamicType.isAccessibilitySize { Spacer(minLength: 4) }
                HStack {
                    if note.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(Color.ember).accessibilityLabel("Starred") }
                    Text(TimeText.clock(note.duration)).font(.caption.monospacedDigit()).foregroundStyle(Color.muted).padding(.top, 4)
                }.fixedSize()
            }
            if !note.transcript.isEmpty { Text(note.preview(matching: query)).font(.subheadline).foregroundStyle(Color.muted).lineLimit(2).lineSpacing(3) }
            rowLayout {
                Text(note.createdAt, style: .time).font(.caption).foregroundStyle(Color.muted)
                StatusPill(status: note.status)
                if !dynamicType.isAccessibilitySize { Spacer() }
                if !note.bookmarks.isEmpty { Label("\(note.bookmarks.count)", systemImage: "bookmark.fill").font(.caption2).foregroundStyle(Color.muted) }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Color.muted)
            }
            if note.status == .transcribing { ProgressView(value: processing).tint(.ember) }
        }.padding(19).frame(maxWidth: .infinity, alignment: .leading).background(Color.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.ink.opacity(0.055), lineWidth: 1))
            .accessibilityElement(children: .combine)
    }
}

import AVFoundation
private enum AVAudioApplicationPermission {
    @MainActor static var denied: Bool { AVAudioApplication.shared.recordPermission == .denied }
}
@MainActor func openSystemSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}
