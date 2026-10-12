import SwiftUI
import CassiniNotebook

struct RecordingView: View {
    @Environment(RecordingStore.self) private var recording
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bookmarkFeedback = 0

    private var active: ActiveRecording? { recording.state.activeRecording }
    private var isPaused: Bool { active?.pause != nil }
    private var elapsed: TimeInterval { active?.elapsed ?? 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                HStack {
                    Button { saveTitle(); dismiss() } label: {
                        Image(systemName: "chevron.down").font(.headline).frame(width: HitTarget.minimum, height: HitTarget.minimum).background(.white.opacity(0.08), in: Circle())
                    }.accessibilityLabel("Minimize recording")
                    Spacer()
                    HStack(spacing: 7) {
                        Circle().fill(isPaused ? Color.gray : .recordingLive).frame(width: 7, height: 7)
                        Text(isPaused ? "PAUSED" : "RECORDING").font(.caption.weight(.semibold)).tracking(2)
                    }
                    Spacer()
                    Image(systemName: "lock.shield").font(.title3).frame(width: HitTarget.minimum, height: HitTarget.minimum).foregroundStyle(.white.opacity(0.5)).accessibilityLabel("Saved on this device")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("GIVE THIS MOMENT A NAME").font(.caption2.weight(.semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.5))
                    TextField("Recording title", text: $title, axis: .vertical).font(.system(.title, design: .serif)).lineLimit(1...3).submitLabel(.done).onSubmit { saveTitle() }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 24)
                VStack(spacing: 8) {
                    Text(TimeText.clock(elapsed)).font(.system(size: 68, weight: .ultraLight, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                        .accessibilityLabel("Recording duration \(TimeText.clock(elapsed))")
                    Text("48 kHz  ·  Mono  ·  Original quality").font(.caption).foregroundStyle(.white.opacity(0.45))
                }.padding(.top, 20)
                Waveform(levels: recording.levels, progress: 1, activeColor: isPaused ? .gray : .recordingAccent).frame(height: 115)
                    .accessibilityHidden(false).accessibilityLabel("Microphone level, last six seconds")
                Button {
                    recording.addBookmark(at: elapsed); bookmarkFeedback += 1
                } label: { Label("Mark a moment", systemImage: "bookmark").font(.subheadline).padding(.horizontal, 20).padding(.vertical, 13).background(.white.opacity(0.08), in: Capsule()) }
                    .sensoryFeedback(.success, trigger: bookmarkFeedback)
                if let notice { Text(notice).font(.subheadline).foregroundStyle(Color.recordingLive).multilineTextAlignment(.center) }
                Text("Room to think. We’re listening.\nRecording continues when you lock your screen.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center).lineSpacing(4)
                HStack(spacing: 16) {
                    Button { if isPaused { recording.resume() } else { recording.pause() } } label: {
                        Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 19).background(.white.opacity(0.1), in: Capsule())
                    }
                    Button { saveTitle(); Task { await recording.finish() } } label: {
                        Label("Finish", systemImage: "stop.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 19).background(Color.recordingFinish, in: Capsule())
                    }.accessibilityIdentifier("finishRecording")
                }.padding(.top, 16)
            }.padding(28).frame(maxWidth: ReadableWidth.recording).frame(maxWidth: .infinity)
        }
        .background(Color.recordingBackground).foregroundStyle(.white).preferredColorScheme(.dark)
        .onAppear { title = active?.title ?? "" }
        .onChange(of: title) { _, _ in saveTitle() }
        .onDisappear { saveTitle() }
    }

    private var notice: String? {
        if let failure = recording.resumeFailure { return failure }
        switch active?.pause {
        case .otherApp: return "Recording paused by another app. Resume when you’re ready."
        case .routeLost: return "Your audio input disconnected. Check your microphone, then resume."
        case .user, nil: return nil
        }
    }

    private func saveTitle() { recording.rename(title) }
}
