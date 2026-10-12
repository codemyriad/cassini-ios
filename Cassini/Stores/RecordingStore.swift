import Foundation
import Observation
import CassiniAudio
import CassiniEngine
import CassiniNotebook

/// One recording at a time: its note is created before capture starts, and finishing seals, compresses and queues it.
@MainActor @Observable final class RecordingStore {
    static let levelCount = 64
    /// How often free space is checked while recording, in seconds of capture.
    static let storageCheckInterval: TimeInterval = 10

    private(set) var state: RecordingState = .idle
    /// Recent input levels, oldest first.
    private(set) var levels = Array(repeating: Float(0.05), count: levelCount)
    /// Why Resume did not work.
    private(set) var resumeFailure: String?

    @ObservationIgnored private let capture: any AudioCapture
    @ObservationIgnored private let audio: any AudioProcessing
    @ObservationIgnored private let storage: any StorageProbe
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let processing: ProcessingStore
    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let router: Router
    @ObservationIgnored private let errors: ErrorPresenter
    @ObservationIgnored private let notices: NoticesStore
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var checkedStorageAt: TimeInterval = 0

    init(capture: any AudioCapture, audio: any AudioProcessing, storage: any StorageProbe, library: LibraryStore,
         processing: ProcessingStore, playback: PlaybackStore, settings: SettingsStore, router: Router,
         errors: ErrorPresenter, notices: NoticesStore, clock: any AppClock, locale: Locale, timeZone: TimeZone) {
        self.capture = capture; self.audio = audio; self.storage = storage; self.library = library
        self.processing = processing; self.playback = playback; self.settings = settings; self.router = router
        self.errors = errors; self.notices = notices; self.clock = clock; self.locale = locale; self.timeZone = timeZone
        let stream = capture.events
        events = Task { [weak self] in
            for await event in stream { await self?.handle(event) }
        }
    }

    var isBusy: Bool {
        switch state {
        case .starting, .finishing: true
        default: false
        }
    }

    /// The note whose audio is still being sealed and compressed.
    var finishingNoteID: UUID? {
        if case .finishing(let id) = state { id } else { nil }
    }

    /// Starts a recording, or returns to the one in progress.
    func start() async {
        if state.isActive { router.presentRecording(); return }
        guard state == .idle, let root = library.root else { return }
        state = .starting
        playback.setBlocked(true)
        let now = clock.now
        let title = NoteTitles.recordingDefault(at: now, locale: locale, timeZone: timeZone)
        var note = Note(title: title, createdAt: now, audioFilename: "capture.caf")
        note.status = .recording; note.audio = .live; note.language = settings.speechLanguage
        do {
            guard storage.availableBytes(at: root) >= Limits.minRecordingFreeBytes else { throw AudioError.storageLow }
            try await library.insert(note)
            guard let url = library.audioURL(note) else { throw AudioError.startFailed }
            let format = try await capture.start(url: url)
            levels = Array(repeating: 0.05, count: Self.levelCount)
            resumeFailure = nil; checkedStorageAt = 0
            state = .active(ActiveRecording(noteID: note.id, title: title, defaultTitle: title, format: format))
            router.presentRecording()
        } catch {
            await discard(note)
            state = .idle
            playback.setBlocked(false)
            errors.present(error.localizedDescription, offersSettings: (error as? AudioError) == .microphoneDenied)
        }
    }

    func pause() {
        guard var recording = state.activeRecording else { return }
        capture.pause()
        recording.pause = .user
        state = .active(recording)
    }

    func resume() {
        guard var recording = state.activeRecording else { return }
        do {
            try capture.resume()
            recording.pause = nil; resumeFailure = nil
            state = .active(recording)
        } catch {
            resumeFailure = error.localizedDescription
        }
    }

    /// Saves a typed title, cut to the title limit; a blank one is ignored.
    func rename(_ title: String) {
        guard var recording = state.activeRecording, let fitted = NoteTitles.fit(title) else { return }
        recording.title = fitted
        state = .active(recording)
        library.update(recording.noteID) { $0.title = fitted }
    }

    func addBookmark(at time: TimeInterval) {
        guard let id = state.noteID else { return }
        let bookmark = UUID()
        library.update(id) { $0.addBookmark(at: time, id: bookmark) }
    }

    /// Stops the capture, seals the note, opens it, then compresses the audio and queues the transcription.
    func finish() async {
        guard let recording = state.activeRecording else { return }
        let id = recording.noteID
        state = .finishing(noteID: id)
        processing.beginFinalizing(id)
        defer {
            processing.endFinalizing(id)
            state = .idle
        }
        let duration = (try? await capture.stop().duration) ?? capture.elapsed
        playback.setBlocked(false)
        router.dismissRecording()
        // Seal the metadata before the optional waveform and compression work.
        guard let note = await library.commit(id, { $0.duration = duration; $0.status = .audioOnly; $0.audio = .plain }),
              let url = library.audioURL(note) else { return }
        router.openNote(id)
        do {
            let summary = try await audio.inspect(url)
            library.update(id) { $0.duration = summary.duration; $0.waveform = summary.waveform }
        } catch {
            library.update(id) { $0.failure = .audio }
            return
        }
        let compressed = url.deletingLastPathComponent().appendingPathComponent("audio.m4a")
        do {
            try await audio.compress(url, to: compressed)
            if await library.commit(id, { $0.audioFilename = "audio.m4a" }) != nil { try? FileManager.default.removeItem(at: url) }
        } catch {
            // The original CAF stays the recording when compression fails.
            try? FileManager.default.removeItem(at: compressed)
            notices.post("Your recording is saved in its original quality. Compression could not finish.")
        }
        processing.endFinalizing(id)
        if settings.autoTranscribe && settings.downloadsAllowed { processing.request(id) }
    }

    /// At launch: a note that was still recording when Cassini closed gets the duration of what was written.
    func recoverInterrupted() async {
        for note in library.notes where note.isRecording || note.status == .recording {
            guard state.noteID != note.id, let url = library.audioURL(note) else { continue }
            do {
                let summary = try await audio.inspect(url)
                library.update(note.id) {
                    $0.duration = summary.duration; $0.waveform = summary.waveform; $0.status = .audioOnly; $0.audio = .plain
                }
                notices.post("Recovered an interrupted recording. Your audio is ready to play.")
            } catch {
                library.update(note.id) { $0.status = .failed; $0.failure = .audio; $0.audio = .unplayable(.interrupted) }
            }
        }
    }

    private func handle(_ event: CaptureEvent) async {
        guard var recording = state.activeRecording else { return }
        switch event {
        case .level(let level):
            guard recording.pause == nil else { return }
            levels.append(level)
            levels.removeFirst(max(0, levels.count - Self.levelCount))
            recording.elapsed = capture.elapsed
            state = .active(recording)
            await checkStorage(at: recording.elapsed)
        case .interrupted:
            recording.pause = .otherApp
            state = .active(recording)
        case .routeLost:
            recording.pause = .routeLost
            state = .active(recording)
        case .failed, .mediaReset:
            notices.post("Recording stopped because of an audio error. Your saved audio has been kept.")
            await finish()
        }
    }

    private func checkStorage(at elapsed: TimeInterval) async {
        guard elapsed - checkedStorageAt >= Self.storageCheckInterval, let root = library.root else { return }
        checkedStorageAt = elapsed
        guard storage.availableBytes(at: root) < Limits.minRecordingFreeBytes else { return }
        notices.post(AudioError.storageLow.localizedDescription)
        await finish()
    }

    /// Removes a note whose capture never started.
    private func discard(_ note: Note) async {
        do { try await library.delete(note.id) }
        catch { library.update(note.id) { $0.status = .failed; $0.failure = .audio; $0.audio = .unplayable(.interrupted) } }
    }
}
