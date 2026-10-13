import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The Transcribing card of the Note screen: the headline over the audio it works on and the percentage, the bar, the
/// five-step stepper, the stats (time left, processed audio, battery at finish, words so far), Stop and keep progress
/// and a footnote. A queued note shows when it starts ("2 ahead of this note." with `ahead` queued jobs before it, as
/// Android's QueuedCard) and Remove from queue instead.
struct ProcessingCard: View {
    let note: Note
    /// The queued jobs before this note's, the running one not counted.
    var ahead = 0
    let model: NoteScreenModel
    @Environment(ProcessingStore.self) private var processing
    @Environment(JobProgress.self) private var progress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if note.status == .queued && !processing.state.isRunning(note.id) {
                queued
            } else {
                running(progress.phase(for: note.id) ?? .starting)
            }
        }
        .padding(Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var queued: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Queued", tableName: "Processing").font(.subheadline.weight(.medium))
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
    }

    @ViewBuilder private func running(_ phase: JobPhase) -> some View {
        switch phase {
        case .transcribing(let running, _):
            ProgressCardContent(progress: running, stop: model.stopJob, cancelDownload: model.cancelJobDownload)
        case .downloading(let download):
            Header(headline: ProgressText.downloadingModels, range: nil, percent: download?.percent)
            ProgressView(value: download.map { Double($0.percent) / 100 }).tint(.ember)
            if let download { DownloadRow(download: download, cancel: model.cancelJobDownload) }
            stopButton
            footnote
        case .stopping:
            Header(headline: ProgressText.stopping, range: nil, percent: nil)
            ProgressView().tint(.ember)
        case .starting, .waitingForPrevious:
            Header(headline: ProgressText.headline(phase == .starting ? .starting : .waitingForPrevious), range: nil,
                   percent: nil)
            ProgressView(value: Optional<Double>.none).tint(.ember)
            stopButton
            footnote
        }
    }

    private var stopButton: some View { StopButton(action: model.stopJob) }
    private var footnote: some View { Footnote() }
}

/// The card while the pipeline runs.
private struct ProgressCardContent: View {
    let progress: RunningProgress
    let stop: () -> Void
    let cancelDownload: () -> Void

    var body: some View {
        let range = progress.rangeStartMs != 0 || progress.rangeEndMs != 0
            ? ProgressText.range(startMs: progress.rangeStartMs, endMs: progress.rangeEndMs) : nil
        Header(headline: ProgressText.headline(progress.headline), range: range, percent: progress.percent)
        ProgressView(value: progress.percent.map { Double($0) / 100 }).tint(.ember)
            .accessibilityHidden(true)
        StageTracker(step: progress.step, speakersSkipped: progress.speakersSkipped)
        if let download = progress.download {
            DownloadRow(download: download, cancel: cancelDownload)
        } else {
            StatGrid(progress: progress)
        }
        if progress.lowMemory {
            LowMemoryHint()
        }
        StopButton(action: stop)
        Footnote()
    }
}

/// The job's model download inside the card (Android's): DL_DOWNLOADING with the part and Cancel, then DL_CHECKING
/// while the files are checked. Cancel stops the job and keeps the files fetched so far.
private struct DownloadRow: View {
    let download: DownloadProgress
    let cancel: () -> Void

    var body: some View {
        Banner(spec: Notices.downloading(download)) { action in
            if action == .cancel { cancel() }
        }
    }
}

/// The memory check's hint (Android's copy), naming the kind of device it runs on.
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

/// The headline over the window range, and the percentage. VoiceOver hears the headline and the percentage in steps of
/// 5, when the headline changes or a step is crossed.
private struct Header: View {
    let headline: String
    let range: String?
    let percent: Int?
    /// The percent grows with Dynamic Type from its 40 pt and 22 pt.
    @ScaledMetric(relativeTo: .largeTitle) private var percentSize: CGFloat = 40
    @ScaledMetric(relativeTo: .title2) private var signSize: CGFloat = 22

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.subheadline.weight(.medium)).foregroundStyle(Color.muted)
                if let range { Text(range).font(.caption.monospacedDigit()).foregroundStyle(Color.muted) }
            }
            Spacer(minLength: Spacing.tight)
            if let percent {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(percent, format: .number).font(.system(size: percentSize, weight: .semibold, design: .rounded))
                    Text(verbatim: "%").font(.system(size: signSize, weight: .semibold, design: .rounded))
                }
                .monospacedDigit().foregroundStyle(Color.ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(announcement)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("progressHeadline")
        .onChange(of: announcement) { _, text in AccessibilityNotification.Announcement(text).post() }
    }

    private var announcement: String {
        guard let percent else { return headline }
        return "\(headline), \(ProgressText.percent(percent / 5 * 5))"
    }
}

private struct StopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Stop and keep progress", tableName: "Processing").frame(maxWidth: .infinity, minHeight: HitTarget.minimum)
        }
        .buttonStyle(.bordered)
        .tint(.ink)
    }
}

private struct Footnote: View {
    var body: some View {
        Text("Transcription runs on this device. If iOS stops it in the background, your progress is kept.",
             tableName: "Processing")
            .font(.caption).foregroundStyle(Color.muted)
            // The card is laid out beside the draft's list; the note wraps rather than being cut.
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
