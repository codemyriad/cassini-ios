import SwiftUI
import CassiniNotebook

struct NoteDetailView: View {
    let noteID: UUID
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var showSearch = false
    @State private var followPlayback = true
    @State private var showBookmarks = false
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var editing: TranscriptSegment?
    @State private var exportItem: ExportItem?
    @State private var consent = false
    private var note: Note? { store.note(noteID) }
    private var activeSegment: UUID? {
        note?.transcript.last { $0.start <= store.player.position && $0.end > store.player.position }?.id
    }
    var body: some View {
        Group {
            if let note {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            detailHeader(note)
                            if store.finalizingID == noteID {
                                HStack(spacing: 12) { ProgressView(); Text("Saving a compact copy. Your original audio is safe.").font(.subheadline).foregroundStyle(Color.muted) }
                            }
                            if store.recorder.isActive { NoticeCard(title: "Finish recording to listen to this note.", symbol: "mic") }
                            if let failure = note.failureMessage { NoticeCard(title: failure, symbol: "exclamationmark.circle") }
                            if let unavailable = note.playbackUnavailable { NoticeCard(title: unavailable, symbol: "waveform.slash") }
                            if note.status == .transcribing || note.status == .queued { processingCard(note) }
                            if showSearch {
                                HStack {
                                    Image(systemName: "magnifyingglass")
                                    TextField("Find in transcript", text: $query).autocorrectionDisabled().accessibilityIdentifier("transcriptSearch")
                                    Button("Close search", systemImage: "xmark.circle.fill") { showSearch = false; query = "" }.labelStyle(.iconOnly)
                                }.padding(14).background(Color.card, in: RoundedRectangle(cornerRadius: 14))
                            }
                            if !note.bookmarks.isEmpty {
                                DisclosureGroup(isExpanded: $showBookmarks) {
                                    VStack(spacing: 4) {
                                        ForEach(note.bookmarks) { bookmark in
                                            HStack {
                                                Button { seek(bookmark.time) } label: {
                                                    HStack { Text(TimeText.clock(bookmark.time)).monospacedDigit().foregroundStyle(Color.ember); Text(bookmark.label).foregroundStyle(Color.ink); Spacer() }.padding(.vertical, 10)
                                                }.buttonStyle(.plain)
                                                Button("Remove bookmark", systemImage: "minus.circle") { store.update(noteID) { $0.bookmarks.removeAll { $0.id == bookmark.id } } }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                            }.font(.subheadline)
                                        }
                                    }.padding(.top, 8)
                                } label: { Label("\(note.bookmarks.count) marked \(note.bookmarks.count == 1 ? "moment" : "moments")", systemImage: "bookmark").font(.subheadline.weight(.medium)) }
                            }
                            if note.transcript.isEmpty {
                                transcriptEmpty(note)
                            } else {
                                HStack {
                                    Text("TRANSCRIPT").font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(Color.muted)
                                    Spacer()
                                    Button { followPlayback.toggle() } label: { Label(followPlayback ? "Following" : "Follow audio", systemImage: "text.line.first.and.arrowtriangle.forward") }.font(.caption).accessibilityValue(followPlayback ? "On" : "Off")
                                }
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(note.transcript.filter { query.isEmpty || $0.text.localizedStandardContains(query) || ($0.speaker?.localizedStandardContains(query) ?? false) }) { segment in
                                        transcriptRow(segment).id(segment.id)
                                    }
                                    if !query.isEmpty && !note.transcript.contains(where: { $0.text.localizedStandardContains(query) || ($0.speaker?.localizedStandardContains(query) ?? false) }) {
                                        ContentUnavailableView.search(text: query)
                                    }
                                }
                                Text("Tap a word to listen from that moment. Touch and hold a passage to edit it or label its speaker.")
                                    .font(.caption).foregroundStyle(Color.muted).padding(.top, 8)
                            }
                        }.padding(24).frame(maxWidth: 800).frame(maxWidth: .infinity)
                    }
                    .onScrollPhaseChange { _, phase in if phase == .interacting { followPlayback = false } }
                    .onChange(of: activeSegment) { _, id in
                        guard followPlayback, store.player.isPlaying, query.isEmpty, let id else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { playbackBar(note) }
                .toolbar { detailToolbar(note) }
            } else { ContentUnavailableView("Recording unavailable", systemImage: "waveform.slash", description: Text("Return to your library to choose a recording.")) }
        }
        .background(Color.paper)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: noteID) { if let note { store.loadPlayer(note) } }
        .onDisappear { if store.player.noteID == noteID { store.player.pause() } }
        .sheet(isPresented: $renaming) {
            NavigationStack {
                Form { TextField("Recording title", text: $titleDraft).accessibilityIdentifier("recordingTitleField") }
                    .navigationTitle("Rename recording").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { renaming = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                let title = String(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                                if store.update(noteID, { $0.title = title }) { renaming = false }
                            }.disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }.presentationDetents([.medium]).presentationDragIndicator(.visible)
        }
        .alert("Transcribe on this device", isPresented: $consent) {
            Button("Allow & Transcribe") { store.downloadsAllowed = true; store.enqueue(noteID) }
            Button("Not now", role: .cancel) {}
        } message: { Text("Cassini uses Apple’s on-device speech model. If needed, iOS will download a language model, which may use several hundred MB. Your audio is never sent for transcription. You can change this in Settings.") }
        .sheet(item: $editing) { segment in SegmentEditor(segment: segment) { revised in store.update(noteID) { note in if let index = note.transcript.firstIndex(where: { $0.id == revised.id }) { note.transcript[index] = revised } } } }
        .sheet(item: $exportItem) { item in ShareSheet(url: item.url) }
    }
    private func detailHeader(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { StatusPill(status: note.status); Spacer(); Text(note.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Color.muted) }
            Text(note.title).font(.system(.largeTitle, design: .serif)).tracking(-0.7).foregroundStyle(Color.ink).textSelection(.enabled).accessibilityIdentifier("noteTitle")
            HStack(spacing: 16) {
                Label(TimeText.clock(note.duration), systemImage: "waveform")
                if note.wordCount > 0 { Text("\(note.wordCount.formatted()) words") }
                Text(Locale.current.localizedString(forIdentifier: note.language) ?? note.language).lineLimit(1)
            }.font(.caption).foregroundStyle(Color.muted)
        }
    }
    private func processingCard(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(note.status == .queued ? "Waiting to transcribe" : store.processingMessage).font(.subheadline.weight(.medium)); Spacer(); Button("Cancel") { store.cancelTranscription(noteID) }.font(.subheadline) }
            if note.status == .transcribing { ProgressView(value: store.processingProgress).tint(.ember) }
            Text("Your audio is saved. Transcription happens on this device. Keep Cassini open for long recordings.").font(.caption).foregroundStyle(Color.muted)
        }.padding(18).background(Color.card, in: RoundedRectangle(cornerRadius: 18))
    }
    private func transcriptEmpty(_ note: Note) -> some View {
        VStack(spacing: 16) {
            Image(systemName: note.status == .ready ? "text.bubble" : "text.alignleft").font(.system(size: 30, weight: .light)).foregroundStyle(Color.ember)
            Text(note.status == .ready ? "No speech found" : "Let your recording become words.").font(.system(.title2, design: .serif)).multilineTextAlignment(.center)
            Text(note.status == .ready ? "Try a different language or check that voices are audible in the recording." : "A searchable transcript, with every passage connected to the original audio.").font(.subheadline).foregroundStyle(Color.muted).multilineTextAlignment(.center)
            if note.status != .transcribing && note.status != .queued {
                Button { requestTranscription() } label: { Label(note.status == .failed ? "Try again" : "Transcribe", systemImage: "text.badge.waveform") }.buttonStyle(PrimaryButtonStyle()).frame(maxWidth: 290).disabled(store.finalizingID == noteID)
            }
        }.padding(.vertical, 40).frame(maxWidth: .infinity)
    }
    private func transcriptRow(_ segment: TranscriptSegment) -> some View {
        let active = activeSegment == segment.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { seek(segment.start) } label: { Text(TimeText.clock(segment.start)).font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(Color.ember).padding(.vertical, 6) }.accessibilityLabel("Play from \(TimeText.clock(segment.start))")
                if let speaker = segment.speaker { Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(Color.muted) }
                Spacer()
                if active && store.player.isPlaying { Image(systemName: "waveform").font(.caption).foregroundStyle(Color.ember).accessibilityLabel("Now playing") }
            }
            Text(linkedText(segment)).font(.system(.body, design: .serif)).lineSpacing(7).foregroundStyle(Color.ink).tint(Color.ink)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "cassini", let time = Double(url.lastPathComponent) else { return .systemAction }
                    seek(time); return .handled
                })
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Color.ember.opacity(0.065) : Color.clear, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .leading) { if active { RoundedRectangle(cornerRadius: 2).fill(Color.ember).frame(width: 3).padding(.vertical, 16) } }
        .contextMenu {
            Button("Edit passage", systemImage: "pencil") { editing = segment }
            Button("Label speaker", systemImage: "person") { editing = segment }
            Button("Mark this moment", systemImage: "bookmark") { store.addBookmark(noteID, at: segment.start) }
            Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = segment.text }
        }
        .accessibilityAction(named: "Edit passage") { editing = segment }
        .accessibilityAction(named: "Mark this moment") { store.addBookmark(noteID, at: segment.start) }
    }
    private func linkedText(_ segment: TranscriptSegment) -> AttributedString {
        if segment.words.isEmpty {
            var result = AttributedString(segment.text)
            result.link = URL(string: "cassini://seek/\(segment.start)")
            if !query.isEmpty && segment.text.localizedStandardContains(query) { result.backgroundColor = Color.ember.opacity(0.15) }
            return result
        }
        var result = AttributedString()
        for word in segment.words {
            var part = AttributedString(word.text)
            part.link = URL(string: "cassini://seek/\(word.start)")
            if (store.player.isPlaying && store.player.position >= word.start && store.player.position < word.end) || (!query.isEmpty && word.text.localizedStandardContains(query)) {
                part.backgroundColor = Color.ember.opacity(0.18)
            }
            result.append(part)
        }
        return result
    }
    private func playbackBar(_ note: Note) -> some View {
        VStack(spacing: 7) {
            ZStack {
                Waveform(levels: note.waveform, progress: store.player.position / max(1, note.duration)).frame(height: 32).padding(.horizontal, 2)
                Slider(value: Binding(get: { store.player.position }, set: { store.player.seek($0) }), in: 0...max(0.1, note.duration))
                    .tint(.ember).accessibilityLabel("Playback position").accessibilityValue(TimeText.clock(store.player.position))
            }.frame(height: 36)
            HStack {
                Text(TimeText.clock(store.player.position))
                Spacer()
                Text("−" + TimeText.clock(max(0, note.duration - store.player.position)))
            }.font(.caption2.monospacedDigit()).foregroundStyle(Color.muted)
            HStack {
                Menu {
                    ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in Button("\(rate.formatted())×") { store.player.rate = rate } }
                } label: { Text("\(store.player.rate.formatted())×").font(.subheadline.weight(.semibold)).frame(width: 48, height: 48) }.accessibilityLabel("Playback speed")
                Spacer()
                Button { store.player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title2).frame(width: 48, height: 48) }.accessibilityLabel("Back 15 seconds")
                Button { store.togglePlayback() } label: { Image(systemName: store.player.isPlaying ? "pause.fill" : "play.fill").font(.title2).foregroundStyle(Color.paper).frame(width: 58, height: 58).background(Color.ink, in: Circle()) }.accessibilityLabel(store.player.isPlaying ? "Pause playback" : "Play recording").accessibilityIdentifier("playButton")
                Button { store.player.skip(15) } label: { Image(systemName: "goforward.15").font(.title2).frame(width: 48, height: 48) }.accessibilityLabel("Forward 15 seconds")
                Spacer()
                Button { store.addBookmark(noteID, at: store.player.position); showBookmarks = true } label: { Image(systemName: "bookmark").font(.title3).frame(width: 48, height: 48) }.accessibilityLabel("Mark this moment")
            }.foregroundStyle(Color.ink)
        }.dynamicTypeSize(...DynamicTypeSize.accessibility1).padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8).frame(maxWidth: 800).frame(maxWidth: .infinity).background(.regularMaterial)
            .disabled(store.recorder.isActive || store.player.noteID != noteID)
    }
    @ToolbarContentBuilder private func detailToolbar(_ note: Note) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Find in transcript", systemImage: "magnifyingglass") { showSearch.toggle() }
            Menu {
                Button(note.isFavorite ? "Remove star" : "Star recording", systemImage: note.isFavorite ? "star.slash" : "star") { store.update(noteID) { $0.isFavorite.toggle() } }
                Button("Rename", systemImage: "pencil") { titleDraft = note.title; renaming = true }
                Menu("Export transcript", systemImage: "square.and.arrow.up") {
                    ForEach(TranscriptFormat.allCases) { format in Button(format.title) { export(note, format: format) } }
                }.disabled(note.transcript.isEmpty)
                Button("Share audio", systemImage: "waveform") { if let url = store.audioURL(note) { exportItem = ExportItem(url: url) } }.disabled(store.finalizingID == noteID)
                Button("Transcribe again", systemImage: "arrow.clockwise") { requestTranscription() }.disabled(note.status == .transcribing || note.status == .queued || store.finalizingID == noteID || note.playbackUnavailable != nil)
                Divider()
                Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) { store.trash(noteID); dismiss() }
            } label: { Image(systemName: "ellipsis").frame(minWidth: 32, minHeight: 32) }.accessibilityLabel("Recording actions")
        }
    }
    private func requestTranscription() { if store.downloadsAllowed { store.enqueue(noteID) } else { consent = true } }
    private func seek(_ time: Double) {
        guard !store.recorder.isActive, let note, note.playbackUnavailable == nil else { return }
        store.loadPlayer(note); store.player.seek(time)
        if !store.player.isPlaying { store.togglePlayback() }
    }
    private func export(_ note: Note, format: TranscriptFormat) {
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Exports/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let filename = String(note.title.map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : "-" }.prefix(80))
            let url = folder.appendingPathComponent(filename.isEmpty ? "Transcript" : filename).appendingPathExtension(format.rawValue)
            try format.data(for: note).write(to: url, options: .atomic)
            exportItem = ExportItem(url: url)
        } catch { store.errorMessage = error.localizedDescription }
    }
}

private struct ExportItem: Identifiable { let id = UUID(); let url: URL }
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct SegmentEditor: View {
    let segment: TranscriptSegment
    let save: (TranscriptSegment) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var speaker: String
    init(segment: TranscriptSegment, save: @escaping (TranscriptSegment) -> Void) {
        self.segment = segment; self.save = save
        _text = State(initialValue: segment.text); _speaker = State(initialValue: segment.speaker ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Passage at \(TimeText.clock(segment.start))") { TextEditor(text: $text).frame(minHeight: 180).accessibilityLabel("Passage text") }
                Section { TextField("Speaker name (optional)", text: $speaker) } header: { Text("Speaker") } footer: { Text("Labels apply to this passage. Speakers are not identified automatically.") }
            }.navigationTitle("Edit passage").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            var revised = segment
                            revised.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if revised.text != segment.text { revised.words = [] }
                            let name = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
                            revised.speaker = name.isEmpty ? nil : String(name.prefix(100))
                            save(revised); dismiss()
                        }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.tint(.ember)
    }
}
