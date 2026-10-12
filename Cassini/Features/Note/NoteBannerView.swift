import SwiftUI
import CassiniNotebook

/// One banner of the Note screen: its title and body in its tone, its actions (the first filled), and Dismiss. Stands
/// in for WP9's banner catalogue on this screen.
struct NoteBannerView: View {
    let banner: NoteBanner
    let act: (NoteBanner.Action) -> Void
    let dismiss: () -> Void

    var body: some View {
        let copy = NoteBannerCopy(banner)
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.title).font(.subheadline.weight(.semibold))
                    if let body = copy.body { Text(body).font(.subheadline) }
                }
                .accessibilityElement(children: .combine)
                if !banner.actions.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(Array(banner.actions.enumerated()), id: \.element) { index, action in
                            Button(NoteBannerCopy.action(action)) { act(action) }
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: HitTarget.minimum)
                                .modifier(BannerButtonStyle(filled: index == 0))
                                .accessibilityIdentifier("banner-\(banner.id)-\(action)")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.footnote.weight(.semibold))
                    .frame(width: HitTarget.minimum, height: HitTarget.minimum)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NoteCopy.dismiss)
        }
        .foregroundStyle(Color.ink)
        .padding(.leading, 16).padding(.vertical, 10).padding(.trailing, 4)
        .background(copy.tone.background, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(copy.tone.color).frame(width: 3).padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("banner-\(banner.id)")
    }
}

private struct BannerButtonStyle: ViewModifier {
    let filled: Bool
    func body(content: Content) -> some View {
        if filled { content.buttonStyle(.borderedProminent).tint(.ink) } else { content.buttonStyle(.bordered).tint(.ink) }
    }
}

/// The words and tone of each banner (Android's TRUST_*, PLAIN_AUDIO, UNPLAYABLE and TX_* copy).
@MainActor struct NoteBannerCopy {
    let title: String
    let body: String?
    let tone: Tone

    init(_ banner: NoteBanner) {
        switch banner.kind {
        case .trustVerified, .trustNotVerified, .trustAudioChanged, .trustUnreadable, .trustNewerFormat:
            let trust = Self.trust(banner.kind)
            let (title, body) = DocumentTrustNotice.copy(trust)
            self.init(title, body, trust.tone)
        case .plainAudio:
            self.init(String(localized: "Plain audio", table: "Note"),
                      banner.tooLong ? JobFailure.long.transcriptionMessage : String(localized: "No transcript yet.", table: "Note"),
                      .plain)
        case .unplayable:
            self.init(String(localized: "This recording can’t be played", table: "Note"),
                      String(localized: "Cassini closed before the recording was saved. You can still save the file.", table: "Note"),
                      .error)
        case .paused:
            let done = TimeText.clock(Double(banner.doneMs) / 1000), total = TimeText.clock(Double(banner.totalMs) / 1000)
            self.init(String(localized: "Paused at \(done) of \(total)", table: "Note"),
                      banner.bySystem ? Self.pausedBySystem
                          : String(localized: "Pick up where you left off. The draft so far is kept.", table: "Note"),
                      .warn)
        case .pausedEarly:
            self.init(String(localized: "Paused before any words were found", table: "Note"),
                      banner.bySystem ? Self.pausedBySystem : String(localized: "Resume to start transcribing.", table: "Note"),
                      .warn)
        case .queueHeld:
            self.init(String(localized: "Transcription paused · \(banner.count) waiting", table: "Note"),
                      String(localized: "Continue when you’re ready.", table: "Note"), .warn)
        case .oneVoice:
            self.init(String(localized: "All words shown as one voice", table: "Note"),
                      String(localized: "Speakers couldn’t be told apart in this recording.", table: "Note"), .warn)
        case .checkpointMismatch:
            self.init(String(localized: "Saved progress no longer matches", table: "Note"),
                      String(localized: "The recording or models changed. Your recording is kept.", table: "Note"), .error)
        case .memory:
            self.init(String(localized: "Not enough memory", table: "Note"),
                      String(localized: "Close other apps or try a shorter clip.", table: "Note"), .error)
        case .failed:
            let kept = String(localized: "Your recording is kept.", table: "Note")
            self.init(String(localized: "Couldn’t transcribe", table: "Note"),
                      banner.failure.map { "\($0.transcriptionMessage) \(kept)" } ?? kept, .error)
        case .noSpeakers:
            self.init(JobFailure.empty.speakerAnalysisMessage, nil, .plain)
        case .playbackFailed:
            self.init(String(localized: "This audio can’t be played", table: "Playback"), nil, .error)
        }
    }

    private init(_ title: String, _ body: String?, _ tone: Tone) { self.title = title; self.body = body; self.tone = tone }

    private static let pausedBySystem = String(
        localized: "iOS ended the time Cassini had in the background. Resume to continue where it stopped.", table: "Note")

    private static func trust(_ kind: NoteBanner.Kind) -> DocumentTrust {
        switch kind {
        case .trustNotVerified: .notVerified
        case .trustAudioChanged: .audioChanged
        case .trustUnreadable: .unreadable
        case .trustNewerFormat: .newerFormat
        default: .verified
        }
    }

    static func action(_ action: NoteBanner.Action) -> String {
        switch action {
        case .playAnyway: NoteCopy.playAnyway
        case .transcribe: NoteCopy.transcribe
        case .transcribeAgain: NoteCopy.transcribeAgain
        case .resume: NoteCopy.resume
        case .startOver: NoteCopy.startOver
        case .tryAgain: NoteCopy.tryAgain
        case .continueQueue: NoteCopy.continueQueue
        }
    }
}
