import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The Queued card of the Note screen: shows when the note starts ("2 ahead of this note." with `ahead` queued jobs
/// before it, as Android's `QueuedCard`) and Remove from queue.
struct QueuedCard: View {
    var ahead = 0
    let model: NoteScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Queued", tableName: "Processing").font(.subheadline.weight(.medium)).foregroundStyle(Color.ink)
            Group {
                if ahead > 0 {
                    Text("\(ahead) ahead of this note.", tableName: "Processing",
                         comment: "Queued card: how many queued notes transcribe before this one")
                } else {
                    Text("Starts after the current transcription.", tableName: "Processing")
                }
            }
            .font(.caption).foregroundStyle(Color.muted)
            .accessibilityIdentifier("queuedAhead")
            Button { model.removeFromQueue() } label: {
                Text("Remove from queue", tableName: "Processing").frame(maxWidth: .infinity, minHeight: HitTarget.minimum)
            }
            .buttonStyle(.bordered)
        }
        .padding(Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// Resolves the live `JobPhase` and queue admission state into the figures shown on both the compact status strip and
/// the transcribing details sheet. While a stop saves its checkpoint, the retained last live figures stay visible.
struct TranscribingPresentation: Equatable {
    var progress: RunningProgress
    var stopBusy: Bool

    var percent: Int { min(max(progress.percent ?? 0, 0), 99) }

    static let starting = RunningProgress(
        headline: .starting, percent: nil, step: .reading, speakersSkipped: false, timeLeft: .calculating,
        doneMs: 0, totalMs: 0, battery: .unavailable, words: 0)

    static func of(phase: JobPhase?, runningStateStopping: Bool = false) -> TranscribingPresentation {
        let stopBusy = (phase?.isStopping == true) || runningStateStopping
        let progress: RunningProgress = switch phase {
        case nil, .starting?:
            starting
        case .waitingForPrevious?:
            RunningProgress(headline: .waitingForPrevious, percent: nil, step: .reading, speakersSkipped: false,
                            timeLeft: .calculating, doneMs: 0, totalMs: 0, battery: .unavailable, words: 0)
        case .downloading(let download)?:
            RunningProgress(headline: .starting, percent: nil, step: .reading, speakersSkipped: false,
                            timeLeft: .calculating, doneMs: 0, totalMs: 0, battery: .unavailable, words: 0,
                            download: download)
        case .stopping(let last)?:
            last?.progress ?? starting
        case .transcribing(let running, _)?:
            running
        }
        return TranscribingPresentation(progress: progress, stopBusy: stopBusy)
    }
}

/// The compact Transcribing status strip under the meeting title (L-45): accent spinner, bold "Transcribing · " +
/// compact ETA, disclosure chevron, separate Stop action and thin progress track.
struct TranscribingStatusView: View {
    let noteID: UUID
    let openDetails: () -> Void
    let stop: () -> Void
    @Environment(ProcessingStore.self) private var processing
    @Environment(JobProgress.self) private var progress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentation: TranscribingPresentation {
        let stateStopping = processing.state.isRunning(noteID) && processing.state.running?.phase == .stopping
        return TranscribingPresentation.of(phase: progress.phase(for: noteID), runningStateStopping: stateStopping)
    }

    var body: some View {
        let current = presentation
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    detailsTrigger(current)
                    HStack {
                        Spacer(minLength: 0)
                        stopControl(stopBusy: current.stopBusy)
                    }
                }
            } else {
                HStack(spacing: Spacing.tight) {
                    detailsTrigger(current)
                    stopControl(stopBusy: current.stopBusy)
                }
            }
            TranscribingLinearTrack(fraction: Double(current.percent) / 100, height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcribingStatus")
        .overlay(alignment: .topLeading) {
            UITestStateMarker(
                identifier: "transcribingAudioDone",
                value: ProgressText.audioDone(doneMs: current.progress.doneMs, totalMs: current.progress.totalMs))
        }
    }

    private func detailsTrigger(_ current: TranscribingPresentation) -> some View {
        let heading = MeetingPhase1Copy.transcribingHeading
        let eta = ProgressText.compactEta(current.progress.timeLeft)
        let combined = "\(heading) · \(eta)"
        let roundedPercent = ProgressText.percent((current.percent / 5) * 5)
        return Button(action: openDetails) {
            HStack(spacing: 8) {
                spinner
                Text(statusAttributed(heading: heading, eta: eta))
                    .font(.subheadline)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.muted)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: HitTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: combined))
        .accessibilityValue(Text(verbatim: roundedPercent))
        .accessibilityHint(MeetingPhase1Copy.transcribingDetailsA11y)
        .accessibilityAddTraits([.isButton, .updatesFrequently])
        .accessibilityAction(named: MeetingPhase1Copy.transcribingDetailsA11y, openDetails)
        .accessibilityIdentifier("transcribingDetails")
    }

    private func stopControl(stopBusy: Bool) -> some View {
        Button(action: stop) {
            ZStack {
                Text(MeetingPhase1Copy.stop)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentInk)
                    .opacity(stopBusy ? 0 : 1)
                if stopBusy {
                    spinner
                }
            }
            .padding(.horizontal, 8)
            .frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(stopBusy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MeetingPhase1Copy.stopAndKeepProgress)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("transcribingStop")
    }

    @ViewBuilder private var spinner: some View {
        if reduceMotion {
            Circle().trim(from: 0.15, to: 0.85)
                .stroke(Color.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            ProgressView().tint(.accent).controlSize(.small).dynamicTypeSize(.medium)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
    }

    private func statusAttributed(heading: String, eta: String) -> AttributedString {
        var head = AttributedString(heading)
        head.font = .subheadline.weight(.semibold)
        head.foregroundColor = Color.ink
        var tail = AttributedString(" · \(eta)")
        tail.font = .subheadline
        tail.foregroundColor = Color.muted
        return head + tail
    }
}

/// The native Transcribing details sheet (L-45): live percentage, thick progress bar, vertical 5-step list, 2-column
/// stats, model download banner, low-memory warning, block Stop and keep progress button and background footnote.
struct TranscribingDetailsSheet: View {
    let noteID: UUID
    let stop: () -> Void
    let cancelDownload: () -> Void
    @Environment(ProcessingStore.self) private var processing
    @Environment(JobProgress.self) private var progress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: TranscribingPresentation {
        let stateStopping = processing.state.isRunning(noteID) && processing.state.running?.phase == .stopping
        return TranscribingPresentation.of(phase: progress.phase(for: noteID), runningStateStopping: stateStopping)
    }

    var body: some View {
        let current = presentation
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                    Text(MeetingPhase1Copy.transcribingHeading)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    Text(ProgressText.percent(current.percent))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.muted)
                        .accessibilityIdentifier("transcribingDetailsPercent")
                }
                TranscribingLinearTrack(fraction: Double(current.percent) / 100, height: 6)
                if current.progress.headline == .waitingForPrevious {
                    Text(ProgressText.headline(.waitingForPrevious))
                        .font(.caption)
                        .foregroundStyle(Color.muted)
                }
                StageTracker(step: current.progress.step, speakersSkipped: current.progress.speakersSkipped)
                Rectangle().fill(Color.lineSoft).frame(height: 1).accessibilityHidden(true)
                StatGrid(progress: current.progress)
                if let download = current.progress.download {
                    DownloadRow(download: download, cancel: cancelDownload)
                }
                if current.progress.lowMemory {
                    LowMemoryHint()
                }
                Button(action: stop) {
                    ZStack {
                        Text(MeetingPhase1Copy.stopAndKeepProgress)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ink)
                            .opacity(current.stopBusy ? 0 : 1)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        if current.stopBusy {
                            if reduceMotion {
                                Circle().trim(from: 0.15, to: 0.85)
                                    .stroke(Color.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .frame(width: 16, height: 16)
                            } else {
                                ProgressView().tint(.accent).controlSize(.small).dynamicTypeSize(.medium)
                                    .frame(width: 16, height: 16)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: HitTarget.minimum)
                    .background(Color.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(current.stopBusy)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(MeetingPhase1Copy.stopAndKeepProgress)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("transcribingDetailsStop")
                Footnote()
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.top, Spacing.gutter)
            .padding(.bottom, Spacing.gutter)
            .readableWidth()
        }
        .accessibilityIdentifier("transcribingDetailsSheet")
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.raised)
    }
}

/// Thin or thick determinate progress track on `neutralTint` with `accent` fill.
private struct TranscribingLinearTrack: View {
    let fraction: Double
    let height: CGFloat

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.neutralTint)
                if clamped > 0 {
                    Capsule().fill(Color.accent)
                        .frame(width: max(height, proxy.size.width * clamped))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The job's model download inside the details sheet: DL_DOWNLOADING with the part and Cancel, then DL_CHECKING while
/// the files are checked. Cancel stops the job and keeps the files fetched so far.
private struct DownloadRow: View {
    let download: DownloadProgress
    let cancel: () -> Void

    var body: some View {
        Banner(spec: Notices.downloading(download)) { action in
            if action == .cancel { cancel() }
        }
    }
}

/// The memory check's hint, naming the kind of device it runs on.
private struct LowMemoryHint: View {
    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                Text("This iPad is low on memory. Close other apps if transcription stops.", tableName: "Processing",
                     comment: "The memory hint on the processing card of an iPad")
            } else {
                Text("This phone is low on memory. Close other apps if transcription stops.", tableName: "Processing")
            }
        }
        .font(.caption).foregroundStyle(Color.toneWarn)
    }
}

private struct Footnote: View {
    var body: some View {
        Text("Transcription runs on this device. If iOS stops it in the background, your progress is kept.",
             tableName: "Processing")
            .font(.caption).foregroundStyle(Color.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension ProcessingPhase {
    /// One line for screens that show the running job in brief.
    var message: String {
        switch self {
        case .starting: ProgressText.headline(.starting)
        case .downloading, .preparingSpeakers: ProgressText.downloadingModels
        case .transcribing: ProgressText.headline(.findingWords)
        case .identifyingSpeakers: ProgressText.headline(.findingSpeakers)
        case .matching: ProgressText.headline(.matchingVoices)
        case .saving: ProgressText.headline(.saving)
        case .stopping: ProgressText.stopping
        }
    }
}
