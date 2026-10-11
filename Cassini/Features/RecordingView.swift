import SwiftUI
import CassiniNotebook

struct RecordingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bookmarkFeedback = 0
    private let background = Color(red: 0.075, green: 0.12, blue: 0.14)
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                HStack {
                    Button { saveTitle(); dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44).background(.white.opacity(0.08), in: Circle()) }.accessibilityLabel("Minimize recording")
                    Spacer()
                    HStack(spacing: 7) {
                        Circle().fill(store.recorder.isPaused ? Color.gray : .orange).frame(width: 7, height: 7)
                        Text(store.recorder.isPaused ? "PAUSED" : "RECORDING").font(.caption.weight(.semibold)).tracking(2)
                    }
                    Spacer()
                    Image(systemName: "lock.shield").font(.title3).frame(width: 44, height: 44).foregroundStyle(.white.opacity(0.5)).accessibilityLabel("Saved on this device")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("GIVE THIS MOMENT A NAME").font(.caption2.weight(.semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.5))
                    TextField("Recording title", text: $title, axis: .vertical).font(.system(.title, design: .serif)).lineLimit(1...3).submitLabel(.done).onSubmit { saveTitle() }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 24)
                VStack(spacing: 8) {
                    Text(TimeText.clock(store.recorder.elapsed)).font(.system(size: 68, weight: .ultraLight, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1).accessibilityLabel("Recording duration \(TimeText.clock(store.recorder.elapsed))")
                    Text("48 kHz  ·  Mono  ·  Original quality").font(.caption).foregroundStyle(.white.opacity(0.45))
                }.padding(.top, 20)
                Waveform(levels: store.recorder.levels, progress: 1, activeColor: store.recorder.isPaused ? .gray : Color(red: 0.98, green: 0.49, blue: 0.30)).frame(height: 115)
                    .accessibilityHidden(false).accessibilityLabel("Microphone level, last six seconds")
                Button {
                    if let id = store.recorder.noteID { store.addBookmark(id, at: store.recorder.elapsed); bookmarkFeedback += 1 }
                } label: { Label("Mark a moment", systemImage: "bookmark").font(.subheadline).padding(.horizontal, 20).padding(.vertical, 13).background(.white.opacity(0.08), in: Capsule()) }
                    .sensoryFeedback(.success, trigger: bookmarkFeedback)
                if let notice = store.recorder.notice { Text(notice).font(.subheadline).foregroundStyle(.orange).multilineTextAlignment(.center) }
                Text("Room to think. We’re listening.\nRecording continues when you lock your screen.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center).lineSpacing(4)
                HStack(spacing: 16) {
                    Button {
                        if store.recorder.isPaused { store.recorder.resume() } else { store.recorder.pause() }
                    } label: {
                        Label(store.recorder.isPaused ? "Resume" : "Pause", systemImage: store.recorder.isPaused ? "play.fill" : "pause.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 19).background(.white.opacity(0.1), in: Capsule())
                    }
                    Button {
                        saveTitle(); Task { await store.finishRecording() }
                    } label: { Label("Finish", systemImage: "stop.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 19).background(Color(red: 0.78, green: 0.24, blue: 0.12), in: Capsule()) }.accessibilityIdentifier("finishRecording")
                }.padding(.top, 16)
            }.padding(28).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }.background(background).foregroundStyle(.white).preferredColorScheme(.dark)
            .presentationDragIndicator(.visible)
            .onAppear { if let id = store.recorder.noteID { title = store.note(id)?.title ?? "" } }
            .onChange(of: title) { _, _ in saveTitle() }
            .onDisappear { saveTitle() }
    }
    private func saveTitle() {
        guard let id = store.recorder.noteID else { return }
        let value = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        if !value.isEmpty { store.update(id) { $0.title = value } }
    }
}
