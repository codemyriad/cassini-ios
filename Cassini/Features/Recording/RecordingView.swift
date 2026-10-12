import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The Recording screen, dark in both appearances: the header (minimise, status, format), the title, the banner, the
/// timer, waveform and hint, and the controls. Before the capture runs and while it is saved, the caption says why and
/// Pause and Finish are disabled.
struct RecordingView: View {
    @Environment(RecordingStore.self) private var recording
    @State private var bookmarkFeedback = 0

    private var screen: RecordingScreenModel { recording.screen }
    private var capturing: Bool { screen.phase == .recording || screen.phase == .paused }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    RecordingHeader(phase: screen.phase, format: screen.format, minimise: screen.minimise)
                    RecordingTitleField(title: Binding(get: { screen.title }, set: { screen.setTitle($0) }))
                        .padding(.top, 28)
                    if let banner = screen.banner {
                        Banner(spec: banner, style: .onDark, onAction: { screen.perform($0) })
                        .padding(.top, 8)
                    }
                    Spacer(minLength: 24)
                    VStack(spacing: 28) {
                        RecordingTimer(elapsed: screen.elapsed)
                        RecordingWaveform(levels: screen.levels, isPaused: screen.phase != .recording)
                        Text(caption).font(.subheadline).foregroundStyle(.white.opacity(0.62))
                            .multilineTextAlignment(.center).frame(maxWidth: 300)
                    }
                    Spacer(minLength: 24)
                    Button {
                        recording.addBookmark(); bookmarkFeedback += 1
                    } label: {
                        Label { Text("Mark a moment", tableName: "Recording") } icon: { Image(systemName: "bookmark") }
                            .font(.subheadline).padding(.horizontal, 20).padding(.vertical, 12)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                    .disabled(!capturing).sensoryFeedback(.success, trigger: bookmarkFeedback).padding(.bottom, 24)
                    RecordingControls(isPaused: screen.phase == .paused, capturing: capturing,
                                      library: screen.minimise, pauseOrResume: screen.pauseOrResume, finish: screen.finish)
                }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 28)
                .frame(maxWidth: ReadableWidth.recording, minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.recordingBackground.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear { screen.appeared() }
        .onChange(of: screen.phase) { old, new in
            guard old != new, new == .recording || new == .paused else { return }
            AccessibilityNotification.Announcement(new == .paused ? RecordingCopy.status(paused: true) : RecordingCopy.status(paused: false)).post()
        }
    }

    private var caption: String {
        switch screen.phase {
        case .needsPermission: String(localized: "Cassini needs the microphone to record.", table: "Recording")
        case .starting: String(localized: "Starting the microphone…", table: "Recording")
        case .stopping: String(localized: "Saving the recording…", table: "Recording")
        case .recording, .paused: RecordingCopy.hint(screen.space)
        }
    }
}

private struct RecordingHeader: View {
    let phase: RecordingPhase
    let format: CaptureFormat
    let minimise: () -> Void

    var body: some View {
        HStack {
            Button(action: minimise) {
                Image(systemName: "chevron.down").font(.headline)
                    .frame(width: HitTarget.minimum, height: HitTarget.minimum)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .accessibilityLabel(Text("Minimise to library (recording continues)", tableName: "Recording"))
            Spacer()
            if phase == .recording || phase == .paused { RecordingStatus(isPaused: phase == .paused) }
            Spacer()
            Text(RecordingCopy.format(format)).font(.caption.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.white.opacity(0.1), in: Capsule())
        }
        .frame(minHeight: 48)
    }
}

/// The live dot (a hollow ring while paused) and "Recording" or "Paused".
private struct RecordingStatus: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isPaused { Circle().strokeBorder(.white.opacity(0.62), lineWidth: 1.5) } else { Circle().fill(Color.recordingLive) }
            }
            .frame(width: 10, height: 10)
            Text(RecordingCopy.status(paused: isPaused)).font(.subheadline.weight(.semibold))
                .foregroundStyle(isPaused ? .white.opacity(0.62) : Color.recordingAccent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recording status", tableName: "Recording"))
        .accessibilityValue(RecordingCopy.status(paused: isPaused))
    }
}

private struct RecordingTitleField: View {
    @Binding var title: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Title", tableName: "Recording").font(.footnote).foregroundStyle(.white.opacity(0.62)).accessibilityHidden(true)
            HStack(spacing: 8) {
                TextField(String(localized: "Title", table: "Recording"), text: $title)
                    .font(.system(.title2, design: .serif)).focused($focused).submitLabel(.done)
                    .textInputAutocapitalization(.sentences).onSubmit { focused = false }
                    .accessibilityIdentifier("recordingTitle")
                Image(systemName: "pencil").foregroundStyle(.white.opacity(0.62)).accessibilityHidden(true)
            }
            .padding(.vertical, 4).padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.18)).frame(height: 1) }
        }
    }
}

private struct RecordingTimer: View {
    let elapsed: TimeInterval
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 68

    var body: some View {
        Text(TimeText.clock(elapsed))
            .font(.system(size: size, weight: .ultraLight, design: .rounded)).monospacedDigit()
            .minimumScaleFactor(0.5).lineLimit(1)
            .accessibilityLabel(Text("Recording duration", tableName: "Recording"))
            .accessibilityValue(RecordingCopy.spoken(elapsed))
    }
}

/// Library, Pause or Resume, and Finish, in three equal columns.
private struct RecordingControls: View {
    let isPaused: Bool
    let capturing: Bool
    let library: () -> Void
    let pauseOrResume: () -> Void
    let finish: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            LabelledCircle(label: Text("Library", tableName: "Recording"), action: library) {
                Image(systemName: "list.bullet").font(.title3).frame(width: 56, height: 56)
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            }
            .frame(maxWidth: .infinity)
            Button(action: pauseOrResume) {
                ZStack {
                    Circle().fill(.white.opacity(0.14)).frame(width: 88, height: 88)
                    if isPaused { Circle().fill(Color.recordingLive).frame(width: 26, height: 26) } else { Image(systemName: "pause.fill").font(.system(size: 30)) }
                }
            }
            .disabled(!capturing).opacity(capturing ? 1 : 0.38)
            .accessibilityLabel(Text(isPaused ? "Resume recording" : "Pause recording", tableName: "Recording"))
            .accessibilityIdentifier("pauseResumeRecording")
            .frame(maxWidth: .infinity)
            LabelledCircle(label: Text("Finish", tableName: "Recording"), action: finish) {
                RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 18, height: 18)
                    .frame(width: 56, height: 56).background(Color.recordingFinish, in: Circle())
            }
            .disabled(!capturing).opacity(capturing ? 1 : 0.38)
            .accessibilityIdentifier("finishRecording")
            .frame(maxWidth: .infinity)
        }
    }
}

private struct LabelledCircle<Circle: View>: View {
    let label: Text
    let action: () -> Void
    @ViewBuilder let circle: () -> Circle

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                circle()
                label.font(.footnote)
            }
        }
        .buttonStyle(.plain)
    }
}
