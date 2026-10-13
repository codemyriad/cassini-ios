import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The five steps: done, in progress, not started or skipped.
struct StageTracker: View {
    let step: JobStep
    let speakersSkipped: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(JobStep.allCases, id: \.self) { column in
                let state = state(of: column)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(color(state)).frame(height: 4)
                    Text(ProgressText.step(column)).font(.caption2)
                        .foregroundStyle(state == .inProgress ? Color.ink : Color.muted)
                        .strikethrough(state == .skipped)
                        .lineLimit(2).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ProgressText.stepDescription(column))
                .accessibilityValue(ProgressText.stepState(state))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Stages", tableName: "Processing"))
    }

    private func state(of column: JobStep) -> ProgressText.StepState {
        if column == .speakers, speakersSkipped { return .skipped }
        if column < step { return .done }
        return column == step ? .inProgress : .notStarted
    }

    private func color(_ state: ProgressText.StepState) -> Color {
        switch state {
        case .done: .ember
        case .inProgress: .ember.opacity(0.55)
        case .notStarted, .skipped: .ink.opacity(0.1)
        }
    }
}

/// Time left, Processed, Battery at finish (with a reading) and Words so far.
struct StatGrid: View {
    let progress: RunningProgress

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Spacing.row, verticalSpacing: Spacing.tight) {
            GridRow {
                ProcessingStat(label: Text("Time left", tableName: "Processing"), value: Text(ProgressText.timeLeft(progress.timeLeft)),
                     pending: progress.timeLeft == .calculating)
                ProcessingStat(label: Text("Processed", tableName: "Processing"),
                     value: Text(ProgressText.processed(doneMs: progress.doneMs, totalMs: progress.totalMs)).monospacedDigit())
            }
            GridRow {
                if let battery = ProgressText.battery(progress.battery) {
                    ProcessingStat(label: Text("Battery at finish", tableName: "Processing"), value: Text(battery),
                         pending: progress.battery.isMeasuring)
                }
                ProcessingStat(label: Text("Words so far", tableName: "Processing"), value: Text(progress.words, format: .number))
            }
        }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private extension BatteryLine {
    var isMeasuring: Bool { if case .measuring = self { true } else { false } }
}
