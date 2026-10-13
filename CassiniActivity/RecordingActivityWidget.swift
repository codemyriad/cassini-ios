import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import CassiniNotebook

/// The recording on the Lock Screen and in the Dynamic Island: its title, the running time (or where it paused), the
/// storage warning, and Pause or Resume and Finish. A tap returns to the Recording screen.
struct RecordingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenRecording(state: context.state, noteID: context.attributes.noteID)
                .activityBackgroundTint(RecordingActivityColors.background)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(RecordingLink.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusDot(isPaused: context.state.isPaused).padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingTime(state: context.state).font(.title3.monospacedDigit()).padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if let warning = context.state.warning { WarningText(warning: warning) }
                        RecordingButtons(isPaused: context.state.isPaused, noteID: context.attributes.noteID)
                    }
                }
            } compactLeading: {
                StatusDot(isPaused: context.state.isPaused)
            } compactTrailing: {
                RecordingTime(state: context.state).monospacedDigit().frame(maxWidth: 64)
            } minimal: {
                StatusDot(isPaused: context.state.isPaused)
            }
            .widgetURL(RecordingLink.url)
            .keylineTint(RecordingActivityColors.live)
        }
    }
}

private struct LockScreenRecording: View {
    let state: RecordingActivityState
    let noteID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatusDot(isPaused: state.isPaused)
                VStack(alignment: .leading, spacing: 2) {
                    (state.isPaused ? Text("Recording paused", tableName: "Recording") : Text("Recording", tableName: "Recording"))
                        .font(.caption.weight(.semibold)).foregroundStyle(RecordingActivityColors.secondary)
                    Text(state.title).font(.headline).lineLimit(1).foregroundStyle(.white)
                }
                Spacer(minLength: 8)
                RecordingTime(state: state).font(.title2.monospacedDigit()).foregroundStyle(.white)
            }
            if let warning = state.warning { WarningText(warning: warning) }
            RecordingButtons(isPaused: state.isPaused, noteID: noteID)
        }
        .padding(16)
    }
}

/// The running time, counted by the system while recording; where it paused otherwise.
private struct RecordingTime: View {
    let state: RecordingActivityState

    var body: some View {
        if let since = state.runningSince, !state.isPaused {
            Text(timerInterval: since...Date.distantFuture, countsDown: false)
        } else {
            Text(TimeText.clock(state.elapsed))
        }
    }
}

private struct StatusDot: View {
    let isPaused: Bool
    var body: some View {
        Group {
            if isPaused {
                Circle().strokeBorder(RecordingActivityColors.secondary, lineWidth: 1.5)
            } else {
                Circle().fill(RecordingActivityColors.live)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

private struct WarningText: View {
    let warning: RecordingWarning
    var body: some View {
        switch warning {
        case .lowStorage(let minutes):
            Text("Storage almost full — about \(minutes) min left", tableName: "Recording")
                .font(.footnote.weight(.medium)).foregroundStyle(RecordingActivityColors.live)
        }
    }
}

private struct RecordingButtons: View {
    let isPaused: Bool
    let noteID: UUID
    var body: some View {
        HStack(spacing: 12) {
            if isPaused {
                Button(intent: ResumeRecordingIntent(noteID: noteID)) {
                    Label { Text("Resume", tableName: "Recording") } icon: { Image(systemName: "play.fill") }
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button(intent: PauseRecordingIntent(noteID: noteID)) {
                    Label { Text("Pause", tableName: "Recording") } icon: { Image(systemName: "pause.fill") }
                        .frame(maxWidth: .infinity)
                }
            }
            Button(intent: FinishRecordingIntent(noteID: noteID)) {
                Label { Text("Finish", tableName: "Recording") } icon: { Image(systemName: "stop.fill") }
                    .frame(maxWidth: .infinity)
            }
            .tint(RecordingActivityColors.finish)
        }
        .buttonStyle(.borderedProminent)
        .tint(RecordingActivityColors.button)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
    }
}
