import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// Own capture adapter: samples never enter recordings, the Library or exported meeting files.
@MainActor @Observable final class VoiceEnrollmentAdapter {
    private let makeCapture: @MainActor () -> any AudioCapture
    private var capture: (any AudioCapture)?
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
    private(set) var failure: String?
    private(set) var print: SpeakerPrint?

    init(makeCapture: @escaping @MainActor () -> any AudioCapture, analyzer: any SpeakerAnalyzing, settings: SettingsStore,
         playback: PlaybackStore, recording: RecordingStore, root: URL) {
        self.makeCapture = makeCapture; self.analyzer = analyzer; self.settings = settings
        self.playback = playback; self.recordingStore = recording
        // Samples are temporary and always outside backup, even while the user is still deciding.
        folder = root
    }

    func start() async throws {
        guard !busy, !recording, recordingStore.state.noteID == nil else { return }
        busy = true
        defer { busy = false }
        print = nil; tooShort = false; failure = nil
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
        let capture = makeCapture()
        self.capture = capture
        do { _ = try await capture.start(url: location) }
        catch {
            self.capture = nil
            await removeSample()
            throw error
        }
        recording = true
        events = Task {
            for await event in capture.events {
                guard !Task.isCancelled, recording, self.capture === capture else { return }
                switch event {
                case .level:
                    if capture.elapsed >= 45 {
                        // This watcher now becomes the analysis task. Do not cancel it from finish().
                        events = nil
                        do { try await finish() }
                        catch { failure = error.localizedDescription }
                        return
                    }
                default:
                    // Interrupted / failed samples cannot be saved accidentally.
                    events = nil
                    await cancel(); return
                }
            }
        }
    }

    func finish() async throws {
        guard recording, !busy, let url, let capture else { return }
        busy = true
        defer { busy = false }
        events?.cancel(); events = nil
        recording = false
        self.capture = nil
        do {
            let result = try await capture.stop()
            let analyzed = try await VoiceEnrollment.analyze(url: url, duration: result.duration, analyzer: analyzer)
            try Task.checkCancellation()
            // Dismissing the sheet while analysis is suspended must not resurrect the discarded sample.
            guard self.url == url else { return }
            print = analyzed
        }
        catch VoiceEnrollment.Invalid.tooShort { tooShort = true }
        catch VoiceEnrollment.Invalid.ambiguous { tooShort = true }
        catch {
            await removeSample()
            throw error
        }
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
        let capture = self.capture
        self.capture = nil
        recording = false; print = nil
        if let capture { _ = try? await capture.stop() }
        await removeSample()
    }

    private func removeSample() async {
        guard let old = url else { return }
        url = nil
        _ = await Task.detached { try? FileManager.default.removeItem(at: old) }.value
    }
}
