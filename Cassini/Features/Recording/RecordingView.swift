import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The Recording screen, always dark on the night ground (L-08): the pinned header (back to all meetings, status,
/// format), the title, the banner, the timer, waveform and hint in a scrolling middle, then Mark a moment and the
/// pinned controls: All meetings on the left, Stop in the centre and Pause or Resume on the right (L-48, L-49). Before
/// the capture runs and while it is saved, the caption says why and Stop, Pause and Mark a moment are disabled.
struct RecordingView: View {
    @Environment(RecordingStore.self) private var recording
    @State private var bookmarkFeedback = 0

    private var screen: RecordingScreenModel { recording.screen }
    private var capturing: Bool { screen.phase == .recording || screen.phase == .paused }

    var body: some View {
        VStack(spacing: 0) {
            RecordingHeader(phase: screen.phase, format: screen.format, minimise: screen.minimise)
                .padding(.horizontal, 16).padding(.top, 6)
            GeometryReader { geometry in
                // Title, banner and meter scroll together, so the header and the controls stay reachable in short
                // windows and at large text sizes; on a tall screen the meter stays centred in the free height.
                ScrollView {
                    VStack(spacing: 0) {
                        RecordingTitleField(title: Binding(get: { screen.title }, set: { screen.setTitle($0) }))
                            .padding(.top, 18)
                        if let banner = screen.banner {
                            Banner(spec: banner, style: .onDark, onAction: { screen.perform($0) })
                            .padding(.top, 8)
                        }
                        Spacer(minLength: 16)
                        VStack(spacing: 24) {
                            RecordingTimer(elapsed: screen.elapsed)
                            RecordingWaveform(levels: screen.levels, isPaused: screen.phase != .recording)
                            Text(caption).font(.subheadline).foregroundStyle(Color.recordingSecondary)
                                .multilineTextAlignment(.center).frame(maxWidth: 280)
                        }
                        Spacer(minLength: 16)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: ReadableWidth.content, minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            VStack(spacing: 20) {
                Button {
                    recording.addBookmark(); bookmarkFeedback += 1
                } label: {
                    Label { Text("Mark a moment", tableName: "Recording") } icon: { Image(systemName: "bookmark") }
                        .font(.subheadline).padding(.horizontal, 20).padding(.vertical, 12)
                        .frame(minHeight: HitTarget.minimum)
                        .background(Color.recordingButtonWash, in: Capsule())
                }
                .disabled(!capturing).sensoryFeedback(.success, trigger: bookmarkFeedback)
                RecordingControls(isPaused: screen.phase == .paused, capturing: capturing,
                                  allMeetings: screen.minimise, pauseOrResume: screen.pauseOrResume, stop: screen.finish)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 28)
        }
        .frame(maxWidth: ReadableWidth.content)
        .frame(maxWidth: .infinity)
        .background(Color.recordingBackground.ignoresSafeArea())
        .foregroundStyle(Color.recordingText)
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
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        if dynamicType.isAccessibilitySize {
            VStack(spacing: 8) {
                HStack { minimiseButton; Spacer(); formatLabel }
                if phase == .recording || phase == .paused { RecordingStatus(isPaused: phase == .paused) }
            }
        } else {
            HStack {
                minimiseButton
                Spacer()
                if phase == .recording || phase == .paused { RecordingStatus(isPaused: phase == .paused) }
                Spacer()
                formatLabel
            }
            .frame(minHeight: 48)
        }
    }

    private var minimiseButton: some View {
        Button(action: minimise) {
            Image(systemName: "chevron.down").font(.headline)
                .frame(width: HitTarget.minimum, height: HitTarget.minimum)
                .background(Color.recordingButtonWash, in: Circle())
        }
        .accessibilityLabel(MeetingPhase1Copy.backToAllMeetings)
        .accessibilityHint(Text("The recording continues.", tableName: "Recording"))
    }

    private var formatLabel: some View {
        Text(RecordingCopy.format(format)).font(.caption.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.recordingButtonWash, in: Capsule())
    }
}

/// The live dot (a hollow ring while paused) and "Recording" or "Paused".
private struct RecordingStatus: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isPaused { Circle().strokeBorder(Color.recordingSecondary, lineWidth: 1.5) } else { Circle().fill(Color.recordingLive) }
            }
            .frame(width: 10, height: 10)
            Text(RecordingCopy.status(paused: isPaused)).font(.subheadline.weight(.semibold))
                .foregroundStyle(isPaused ? Color.recordingSecondary : Color.recordingAccent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(Text("Recording status", tableName: "Recording"))
        .accessibilityValue(RecordingCopy.status(paused: isPaused))
    }
}

private struct RecordingTitleField: View {
    @Binding var title: String
    @FocusState private var focused: Bool

    var body: some View {
        // L-48: no visible "Title" caption; the field keeps it as its spoken label.
        HStack(spacing: 8) {
                // Wraps rather than cutting a long title at large text sizes.
            TextField(String(localized: "Title", table: "Recording"), text: $title,
                      prompt: Text("Title", tableName: "Recording").foregroundStyle(Color.ink3), axis: .vertical)
                .lineLimit(1...3).font(.title3).focused($focused).submitLabel(.done)
                .textInputAutocapitalization(.sentences).onSubmit { focused = false }
                .accessibilityLabel(Text("Title", tableName: "Recording"))
                .accessibilityIdentifier("recordingTitle")
            Image(systemName: "pencil").foregroundStyle(Color.recordingSecondary).accessibilityHidden(true)
        }
        .frame(minHeight: HitTarget.minimum)
        .padding(.horizontal, 4).padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.recordingLine).frame(height: 1) }
    }
}

private struct RecordingTimer: View {
    let elapsed: TimeInterval
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 56

    var body: some View {
        // System sans with tabular figures, as Android's 56 sp timer (WP4).
        Text(TimeText.clock(elapsed))
            .font(.system(size: size, weight: .medium)).monospacedDigit().tracking(-0.02 * size)
            .minimumScaleFactor(0.5).lineLimit(1)
            .accessibilityLabel(Text("Recording duration", tableName: "Recording"))
            .accessibilityValue(RecordingCopy.spoken(elapsed))
            .accessibilityIdentifier("recordingTimer")
    }
}

/// All meetings on the left, the red Stop pill in the centre and Pause or Resume on the right (L-49). Stop sends the
/// existing finish; it and Pause or Resume are disabled until the capture runs and while it is saved, and All meetings
/// always works.
private struct RecordingControls: View {
    let isPaused: Bool
    let capturing: Bool
    let allMeetings: () -> Void
    let pauseOrResume: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            SideControl(label: Text(MeetingPhase1Copy.allMeetings), action: allMeetings) {
                Image(systemName: "list.bullet").font(.title3)
            }
            .accessibilityIdentifier("recordingAllMeetings")
            .frame(maxWidth: .infinity)
            Button(action: stop) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.onRecord).frame(width: 14, height: 14)
                    Text(MeetingPhase1Copy.stop).font(.headline)
                }
                .foregroundStyle(Color.onRecord)
                .padding(.horizontal, 24).frame(minHeight: StopPill.height)
                .background(Color.recordingFinish, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!capturing).opacity(capturing ? 1 : 0.38)
            .accessibilityIdentifier("stopRecording")
            .layoutPriority(1)
            SideControl(label: Text(isPaused ? MeetingPhase1Copy.resume : MeetingPhase1Copy.pause), action: pauseOrResume) {
                if isPaused { Circle().fill(Color.recordingLive).frame(width: 18, height: 18) }
                else { Image(systemName: "pause.fill").font(.title3) }
            }
            .disabled(!capturing).opacity(capturing ? 1 : 0.38)
            .accessibilityLabel(isPaused ? Text("Resume recording", tableName: "Recording") : Text("Pause recording", tableName: "Recording"))
            .accessibilityIdentifier("pauseResumeRecording")
            .frame(maxWidth: .infinity)
        }
    }
}

/// The Stop pill's height: the drawn 48 pt, growing with the text.
private enum StopPill { static let height: CGFloat = 48 }

/// A 52 pt outlined circle with its label below, as Android's side controls.
private struct SideControl<Glyph: View>: View {
    let label: Text
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                glyph().frame(width: 52, height: 52)
                    .overlay(Circle().strokeBorder(Color.recordingLine, lineWidth: 1))
                label.font(.footnote).foregroundStyle(Color.recordingSecondary).multilineTextAlignment(.center)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
