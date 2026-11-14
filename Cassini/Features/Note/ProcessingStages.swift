import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The five vertical steps in the transcribing details sheet: done, in progress, not started or skipped.
struct StageTracker: View {
    let step: JobStep
    let speakersSkipped: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(JobStep.allCases, id: \.self) { column in
                let state = state(of: column)
                HStack(spacing: 10) {
                    glyph(state).accessibilityHidden(true)
                    Text(ProgressText.step(column))
                        .font(state == .inProgress ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(state == .done || state == .inProgress ? Color.ink : Color.faint)
                        .strikethrough(state == .skipped)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ProgressText.stepDescription(column))
                .accessibilityValue(ProgressText.stepState(state))
            }
        }
    }

    private func state(of column: JobStep) -> ProgressText.StepState {
        if column == .speakers, speakersSkipped { return .skipped }
        if column < step { return .done }
        return column == step ? .inProgress : .notStarted
    }

    @ViewBuilder private func glyph(_ state: ProgressText.StepState) -> some View {
        switch state {
        case .inProgress:
            if reduceMotion {
                Circle().trim(from: 0.15, to: 0.85)
                    .stroke(Color.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 18, height: 18)
            } else {
                ProgressView().tint(.accent).controlSize(.small).dynamicTypeSize(.medium)
                    .frame(width: 18, height: 18)
            }
        case .done:
            ZStack {
                Circle().fill(Color.accentStrong).frame(width: 18, height: 18)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.onAccent)
            }
        case .notStarted, .skipped:
            Circle().strokeBorder(Color.line, lineWidth: 2).frame(width: 18, height: 18)
        }
    }
}

/// Time left, Audio done, Words so far and Battery at finish (with a reading) in the transcribing details sheet.
struct StatGrid: View {
    let progress: RunningProgress
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let battery = ProgressText.battery(progress.battery)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.row) {
                timeLeftCell
                audioDoneCell
                wordsCell
                if let battery { batteryCell(battery) }
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: Spacing.row, verticalSpacing: Spacing.row) {
                GridRow {
                    timeLeftCell
                    audioDoneCell
                }
                GridRow {
                    wordsCell
                    if let battery { batteryCell(battery) }
                }
            }
        }
    }

    private var timeLeftCell: some View {
        ProcessingStat(label: Text(MeetingPhase1Copy.statTimeLeft),
                       value: Text(ProgressText.timeLeft(progress.timeLeft)),
                       pending: progress.timeLeft == .calculating)
            .accessibilityIdentifier("timeLeftStat")
    }

    private var audioDoneCell: some View {
        ProcessingStat(label: Text(MeetingPhase1Copy.statAudioDone),
                       value: Text(ProgressText.audioDone(doneMs: progress.doneMs, totalMs: progress.totalMs)).monospacedDigit())
            .accessibilityIdentifier("audioDoneStat")
    }

    private var wordsCell: some View {
        ProcessingStat(label: Text(MeetingPhase1Copy.statWordsSoFar),
                       value: Text(progress.words, format: .number))
            .accessibilityIdentifier("wordsSoFarStat")
    }

    private func batteryCell(_ battery: String) -> some View {
        ProcessingStat(label: Text(MeetingPhase1Copy.statBatteryAtFinish),
                       value: Text(battery),
                       pending: progress.battery.isMeasuring)
            .accessibilityIdentifier("batteryStat")
    }
}

struct ProcessingStat: View {
    let label: Text
    let value: Text
    var pending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            label.font(.caption).foregroundStyle(Color.muted)
            value.font(.subheadline.weight(.medium)).foregroundStyle(pending ? Color.muted : Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private extension BatteryLine {
    var isMeasuring: Bool { if case .measuring = self { true } else { false } }
}
