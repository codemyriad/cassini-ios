import Foundation
import CassiniNotebook

/// Live voice matching while a Parakeet run decodes (Android's `TranscriptionJob.matchLive`): after a window, each
/// speaker with at least 4 s of clips and 10 s more than at its last try gets a CAM++ print of its clips, and the prints
/// of the speakers still open for live matching (no confirmed match, no user label, not merged away) are matched with
/// the saved voices. The voices are read again after the prints, so a person forgotten meanwhile is not matched. The
/// result goes through `DraftNames.applyLive`, which checks the current names again, so a "Not Luca" answered
/// meanwhile is never undone. Rejected voices and voices confirmed for another speaker are excluded.
///
/// iOS only: an automatic match is a suggestion while "Name strong matches automatically" is off. Every call runs on
/// the inference thread (`WindowSpeakers`).
public final class LiveMatching: @unchecked Sendable {
    public static let minSeconds = 4.0
    public static let stepSeconds = 10.0

    private let noteID: UUID
    private let drafts: DraftNamesStore
    private let voices: @Sendable () -> [SavedVoice]
    private let autoName: Bool
    private var prints: [String: SpeakerPrint] = [:]
    private var attempts: [String: Double] = [:]

    /// `voices` are the saved voices as they are now, none once Forget everyone moved the generation on since the job
    /// began.
    public init(noteID: UUID, drafts: DraftNamesStore, voices: @escaping @Sendable () -> [SavedVoice], autoName: Bool) {
        self.noteID = noteID; self.drafts = drafts; self.voices = voices; self.autoName = autoName
    }

    /// One round over the clips so far. Throws only what `active` throws (a cancellation) and the prints' failures.
    func round(windows: [String: [PrintWindow]], clips: any PcmSource, engines: any SpeakerEngines,
               active: () throws -> Void) throws {
        let names = drafts.current(noteID)
        let merged = names.merged(windows)
        prints = prints.filter { merged[$0.key] != nil }
        let pending = merged.filter { names.openForLive($0.key) && due($0.key, $0.value, rate: clips.sampleRate) }
        guard !pending.isEmpty, !voices().isEmpty else { return }
        for (id, print) in try CheckedPrints.check(engines.prints(clips, windows: pending, active: active)) {
            attempts[id] = print.seconds
            prints[id] = SpeakerPrint(speakerID: id, model: VoiceprintModel.sha256, vector: print.vector,
                                      speechSeconds: print.seconds)
        }
        let open = prints.filter { names.openForLive($0.key) }
        let people = voices()
        let matches = VoiceMatcher.match(prints: open.keys.sorted().compactMap { open[$0] }, voices: people,
                                         excluded: names.excluded(open.keys))
        let live = matches.mapValues { LiveMatch($0.voiceID, $0.score, $0.automatic && autoName ? .auto : .suggested) }
        let voiceNames = Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        drafts.mutate(noteID) { $0.applyLive(live, names: voiceNames) }
    }

    private func due(_ id: String, _ windows: [PrintWindow], rate: Int) -> Bool {
        let seconds = Double(windows.reduce(0) { $0 + $1.endSample - $1.startSample }) / Double(rate)
        let attempted = attempts[id] ?? 0
        return seconds >= Self.minSeconds && (attempted == 0 || seconds >= attempted + Self.stepSeconds)
    }
}
