import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The activity area at the top of the Library: the recording card and standalone model-install progress.
struct LibraryActivity: View {
    @Environment(LibraryScreenModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        if let card = model.recordingCard {
            RecordingCard(card: card) { router.presentRecording() }
        }
        if let banner = model.progress, banner.noteID == nil {
            ProgressBannerCard(banner: banner) { model.openProgress() }
        }
    }
}

/// "Recording · Standup" with the elapsed time and "Tap to return".
struct RecordingCard: View {
    let card: LibraryMapping.RecordingCard
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: card.paused ? "pause.circle" : "waveform.circle.fill").font(.title).foregroundStyle(Color.recordingAccent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LibraryCopy.recordingCard(card.title, paused: card.paused)).font(.headline).lineLimit(1)
                    Text(LibraryCopy.tapToReturn).font(.caption).foregroundStyle(Color.recordingSecondary)
                }
                Spacer(minLength: 8)
                Text(TimeText.clock(card.elapsed)).font(.body.monospacedDigit())
            }
            .foregroundStyle(Color.recordingText).padding(18)
            .background(Color.recordingBackground, in: RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(LibraryCopy.returnToRecording)
        .accessibilityIdentifier("activeRecordingCard")
    }
}

/// "Transcribing <title>" with the percent, a 4 pt bar and line 2 (time left, a download, "· N more in queue"). A tap
/// opens the running note, or Settings for a download on its own. VoiceOver hears it when its stage changes and at
/// each 5 % step, not at every update.
struct ProgressBannerCard: View {
    let banner: ProgressBanner
    let open: () -> Void

    var body: some View {
        let title = LibraryCopy.progressTitle(banner)
        let line = LibraryCopy.progressLine(banner)
        let step = banner.announcement.step
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let percent = banner.percent { Text(ProgressText.percent(percent)).font(.subheadline.monospacedDigit()) }
                }
                if let fraction = banner.fraction {
                    GeometryReader { proxy in
                        Capsule().fill(Tone.info.color.opacity(0.18))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Tone.info.color).frame(width: proxy.size.width * min(1, max(0, fraction)))
                            }
                    }.frame(height: 4)
                }
                Text(line).font(.caption).foregroundStyle(Color.muted)
            }
            .foregroundStyle(Color.ink).padding(.horizontal, 16).padding(.vertical, 14)
            .background(Tone.info.background, in: RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel([title, step.map(ProgressText.percent), line].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(banner.noteID == nil ? LibraryCopy.openSettings : LibraryCopy.openNote)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("progressBanner")
        .onChange(of: banner.announcement) { _, _ in
            AccessibilityNotification.Announcement([title, step.map(ProgressText.percent), line].compactMap { $0 }
                .joined(separator: ", ")).post()
        }
    }
}

/// Import audio and Record, pinned to the bottom of the Library. While a recording runs, Record reads
/// "Recording · 24:07" and returns to it. When both do not fit side by side (a narrow window, large text), Import
/// collapses to a round icon (Android `CaptureBar`). When the library cannot be opened both are off, and say why.
struct CaptureBar: View {
    @Environment(RecordingStore.self) private var recording
    let unavailable: Bool
    let importAudio: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { importButton(collapsed: false); recordButton }
            HStack(spacing: 12) { importButton(collapsed: true); recordButton }
        }
        .disabled(unavailable)
        // Pinned over the list, the bar stops growing at AX1 and shows the Large Content Viewer instead.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1).accessibilityShowsLargeContentViewer()
        .padding(.horizontal, Spacing.gutter).padding(.vertical, 14)
        .readableWidth()
        // Opaque, so its buttons keep their contrast over the list scrolling under it.
        .background(Color.paper).overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("captureBar")
    }

    private func importButton(collapsed: Bool) -> some View {
        Button(action: importAudio) {
            if collapsed {
                Label(LibraryCopy.importAudio, systemImage: "square.and.arrow.down")
                    .labelStyle(.iconOnly).font(.title3.weight(.semibold))
                    .frame(width: 52, height: 52)
                    .background(Color.ink.opacity(0.06), in: Circle())
            } else {
                Label(LibraryCopy.importAudio, systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold)).fixedSize().frame(minWidth: 88, minHeight: 52)
            }
        }
        .accessibilityHint(unavailable ? LibraryCopy.unavailableTitle : BulkTransferCopy.filter)
        .accessibilityIdentifier("importButton")
    }

    private var recordButton: some View {
        let active = recording.state.activeRecording
        return Button { Task { await recording.start() } } label: {
            if let active {
                Label(LibraryCopy.recordingButton(TimeText.clock(active.elapsed)), systemImage: "waveform").fixedSize()
            } else {
                Label(LibraryCopy.record, systemImage: "mic.fill").fixedSize()
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(recording.isBusy)
        .accessibilityLabel(active == nil ? LibraryCopy.recordDescription : LibraryCopy.returnToRecording)
        .accessibilityHint(unavailable ? LibraryCopy.unavailableTitle : "")
        .accessibilityIdentifier("recordButton")
    }
}
