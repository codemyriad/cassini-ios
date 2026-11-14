import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// Own capture adapter: samples never enter recordings, the Library or exported meeting files.
@MainActor @Observable final class VoiceEnrollmentAdapter {
    private let capture: any AudioCapture
    private let analyzer: any SpeakerAnalyzing
    private let settings: SettingsStore
    private let playback: PlaybackStore
    private let recordingStore: RecordingStore
    private let folder: URL
    private var generation = 0
    private var url: URL?
    private var events: Task<Void, Never>?
    private(set) var recording = false
    private(set) var busy = false
    private(set) var tooShort = false
    private(set) var print: SpeakerPrint?

    init(capture: any AudioCapture, analyzer: any SpeakerAnalyzing, settings: SettingsStore,
         playback: PlaybackStore, recording: RecordingStore, root: URL) {
        self.capture = capture; self.analyzer = analyzer; self.settings = settings
        self.playback = playback; self.recordingStore = recording
        // Samples are temporary and always outside backup, even while the user is still deciding.
        folder = root
    }

    func start() async throws {
        guard !busy, !recording, recordingStore.state.noteID == nil else { return }
        busy = true
        defer { busy = false }
        print = nil; tooShort = false
        playback.stop()
        generation = settings.voicesGeneration
        let folder = folder
        let location = try await Task.detached {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var directory = folder
            var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try directory.setResourceValues(flags)
            return folder.appendingPathComponent("sample-\(UUID().uuidString).caf")
        }.value
        await removeSample()
        url = location
        _ = try await capture.start(url: location)
        recording = true
        events = Task {
            for await event in capture.events {
                switch event {
                case .level:
                    if capture.elapsed >= 45 { try? await finish(); return }
                default:
                    // Interrupted / failed samples cannot be saved accidentally.
                    await cancel(); return
                }
            }
        }
    }

    func finish() async throws {
        guard recording, !busy, let url else { return }
        busy = true
        defer { busy = false }
        events?.cancel(); events = nil
        recording = false
        let result = try await capture.stop()
        do { print = try await VoiceEnrollment.analyze(url: url, duration: result.duration, analyzer: analyzer) }
        catch VoiceEnrollment.Invalid.tooShort { tooShort = true }
        catch VoiceEnrollment.Invalid.ambiguous { tooShort = true }
    }

    func save(name: String, voices: VoicesStore) async throws {
        guard let print, let url, !busy else { return }
        busy = true
        defer { busy = false }
        try await voices.enroll(name: name, print: print, audio: url, generation: generation)
        self.print = nil
        await removeSample()
    }

    func cancel() async {
        events?.cancel(); events = nil
        if recording { _ = try? await capture.stop() }
        recording = false; print = nil
        await removeSample()
    }

    private func removeSample() async {
        guard let old = url else { return }
        url = nil
        _ = await Task.detached { try? FileManager.default.removeItem(at: old) }.value
    }
}
