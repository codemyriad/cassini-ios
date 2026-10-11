import SwiftUI
import AVFoundation
import CassiniNotebook
import CassiniInference
import CassiniAudio

@MainActor @Observable final class AppStore {
    private(set) var notes: [Note] = []
    private(set) var isImporting = false
    private(set) var isStartingRecording = false
    private(set) var isFinishingRecording = false
    private(set) var finalizingID: UUID?
    private(set) var processingID: UUID?
    private(set) var processingMessage = ""
    private(set) var processingProgress: Double?
    var errorMessage: String?
    var notice: String?
    var showingRecorder = false
    var selectedNote: UUID?
    let recorder = Recorder()
    let player = Player()
    let repository: NoteRepository?
    private let speech = SpeechService()
    private let speakerAnalyzer = SpeakerAnalyzer()
    var voiceLibrary: VoiceLibrary?
    var savedVoices: [SavedVoice] = []
    var voiceGeneration = 0
    private var speakerOnlyJobs: Set<UUID> = []
    private var processingTask: Task<Void, Never>?
    private var queue: [UUID] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let preferences: UserDefaults = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return UserDefaults(suiteName: "app.codemyriad.cassini.ui-tests") ?? .standard
        }
        #endif
        return .standard
    }()

    var speakerModelIdentity: String? {
        get { preferences.string(forKey: "speakerModelIdentity") }
        set { preferences.set(newValue, forKey: "speakerModelIdentity") }
    }
    var speakerModelsInstalled: Bool { SpeakerAnalyzer.modelsAvailable }
    var speakerDownloadsAllowed: Bool {
        get { preferences.bool(forKey: "speakerDownloadsAllowed") }
        set { preferences.set(newValue, forKey: "speakerDownloadsAllowed") }
    }
    var automaticallyNameVoices: Bool {
        get { preferences.bool(forKey: "automaticallyNameVoices") }
        set { preferences.set(newValue, forKey: "automaticallyNameVoices") }
    }
    var identifySpeakers: Bool {
        get { preferences.object(forKey: "identifySpeakers") as? Bool ?? true }
        set { preferences.set(newValue, forKey: "identifySpeakers") }
    }

    var language: String {
        get { preferences.string(forKey: "speechLanguage") ?? Locale.current.identifier }
        set { preferences.set(newValue, forKey: "speechLanguage") }
    }
    var downloadsAllowed: Bool {
        get { preferences.bool(forKey: "modelDownloadsAllowed") }
        set { preferences.set(newValue, forKey: "modelDownloadsAllowed") }
    }
    var autoTranscribe: Bool {
        get { preferences.object(forKey: "autoTranscribe") as? Bool ?? true }
        set { preferences.set(newValue, forKey: "autoTranscribe") }
    }

    init(rootURL: URL? = nil) {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var folder = rootURL ?? support.appendingPathComponent("Cassini", isDirectory: true)
            #if DEBUG
            let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            if testing {
                folder = support.appendingPathComponent("CassiniUITests", isDirectory: true)
                if ProcessInfo.processInfo.arguments.contains("--reset-test-data") {
                    try? FileManager.default.removeItem(at: folder)
                    preferences.removePersistentDomain(forName: "app.codemyriad.cassini.ui-tests")
                }
            }
            #endif
            let repo = try NoteRepository(root: folder)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
            #if DEBUG
            if testing, ProcessInfo.processInfo.arguments.contains("--seed-test-data"), try repo.load().notes.isEmpty {
                try TestFixtures.seed(repo)
            }
            #endif
            let loaded = try repo.load()
            repository = repo
            notes = loaded.notes
            for index in notes.indices { notes[index].migrateSpeakers() }
            do { voiceLibrary = try VoiceLibrary(root: folder); savedVoices = voiceLibrary?.voices ?? [] }
            catch { notice = "Saved voices could not be read. Their files have been preserved. Recordings remain available." }
            if loaded.unreadableCount > 0 { notice = "\(loaded.unreadableCount) recording documents could not be read. Their files have been preserved." }
        } catch {
            repository = nil
            errorMessage = "Could not open your library: \(error.localizedDescription)"
        }
        player.onPositionSaved = { [weak self] id, position in self?.update(id) { $0.playbackPosition = position } }
        recorder.onUnexpectedStop = { [weak self] in Task { await self?.finishRecording() } }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--open-fixture") { selectedNote = notes.first?.id }
        #endif
    }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }
    func audioURL(_ note: Note) -> URL? { repository?.audioURL(for: note) }
    @discardableResult func update(_ id: UUID, _ mutation: (inout Note) -> Void) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }), let repository else { return false }
        var copy = notes[index]; mutation(&copy)
        do { try repository.save(copy); notes[index] = copy; return true }
        catch { errorMessage = "Could not save changes: \(error.localizedDescription)"; return false }
    }
    private func insert(_ note: Note) throws {
        guard let repository else { throw CocoaError(.fileWriteUnknown) }
        try repository.save(note); notes.insert(note, at: 0)
    }
    func recoverInterruptedWork() async {
        purgeExpiredTrash()
        for note in notes where note.status == .recording || note.status == .transcribing || note.status == .queued {
            if note.status == .recording, let url = audioURL(note) {
                do {
                    let info = try await AudioInspection.inspect(url)
                    update(note.id) { $0.duration = info.duration; $0.waveform = info.waveform; $0.status = .audioOnly }
                    notice = "Recovered an interrupted recording. Your audio is ready to play."
                } catch {
                    update(note.id) { $0.status = .failed; $0.failureMessage = "This recording was interrupted before its audio file was finalized. The original file has been preserved." }
                }
            } else {
                update(note.id) { $0.status = $0.transcript.isEmpty ? .audioOnly : .ready; $0.failureMessage = "Transcription was interrupted. Tap Transcribe to start again." }
            }
        }
    }
    func startRecording() async {
        if recorder.isActive { showingRecorder = true; return }
        guard !isStartingRecording, !isFinishingRecording, let repository else { return }
        isStartingRecording = true; defer { isStartingRecording = false }
        player.stop()
        var note = Note(title: "Recording · \(Date.now.formatted(date: .abbreviated, time: .shortened))", audioFilename: "capture.caf")
        note.status = .recording; note.language = language
        do {
            try insert(note)
            try await recorder.start(note: note, url: repository.audioURL(for: note))
            showingRecorder = true
        } catch {
            do { try repository.delete(note.id); notes.removeAll { $0.id == note.id } }
            catch { update(note.id) { $0.status = .failed; $0.failureMessage = "Recording did not start." } }
            errorMessage = error.localizedDescription
        }
    }
    func finishRecording() async {
        guard !isFinishingRecording, let id = recorder.noteID, let note = note(id), let url = audioURL(note) else { return }
        isFinishingRecording = true; finalizingID = id
        defer { isFinishingRecording = false; finalizingID = nil }
        let duration = recorder.finish()
        showingRecorder = false
        // Seal metadata before doing optional waveform work.
        guard update(id, { $0.duration = duration; $0.status = .audioOnly }) else { return }
        selectedNote = id
        do {
            let info = try await AudioInspection.inspect(url)
            update(id) { $0.duration = info.duration; $0.waveform = info.waveform }
            let compressed = url.deletingLastPathComponent().appendingPathComponent("audio.m4a")
            do {
                try await AudioArchive.compress(source: url, destination: compressed)
                if update(id, { $0.audioFilename = "audio.m4a" }) { try? FileManager.default.removeItem(at: url) }
            } catch {
                // The original CAF remains the authoritative recording on any export failure.
                try? FileManager.default.removeItem(at: compressed)
                notice = "Your recording is saved in its original quality. Compression could not finish."
            }
            finalizingID = nil
            if autoTranscribe && downloadsAllowed { enqueue(id) }
        } catch { update(id) { $0.failureMessage = error.localizedDescription } }
    }
    func importAudio(_ url: URL) async {
        guard !isImporting, let repository else { return }
        isImporting = true; defer { isImporting = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        let safeExtension = !ext.isEmpty && ext.count < 8 && ext.allSatisfy { $0.isLetter || $0.isNumber } ? ext : "audio"
        var note = Note(title: url.deletingPathExtension().lastPathComponent, audioFilename: "audio.\(safeExtension)")
        note.language = language
        let folder = repository.directory(for: note.id)
        do {
            try Recorder.checkStorage(at: repository.root)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = repository.audioURL(for: note)
            try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: url, to: destination) }.value
            let portable = await Task.detached(priority: .userInitiated) { PortableTranscript.read(from: destination) }.value
            if let portable {
                note.title = portable.title; note.language = portable.language
                note.duration = portable.duration; note.transcript = portable.segments; note.status = .ready
                note.speakers = portable.speakers; note.versions = portable.versions; note.selectedVersionID = portable.selectedVersionID
            }
            if ["opus", "ogg"].contains(ext) {
                let decoded = folder.appendingPathComponent("playback.caf")
                do {
                    try await Task.detached(priority: .userInitiated) { try OpusAudio.decode(destination, to: decoded) }.value
                    note.originalAudioFilename = note.audioFilename; note.audioFilename = "playback.caf"
                } catch {
                    try? FileManager.default.removeItem(at: decoded)
                    if portable == nil { throw error }
                }
            }
            do {
                let info = try await AudioInspection.inspect(repository.audioURL(for: note))
                note.duration = info.duration; note.waveform = info.waveform
            } catch {
                guard portable != nil else { throw error }
                note.playbackUnavailable = "This device cannot play the imported Opus container. Its verified transcript is available, and the original Cassini document is preserved for sharing."
            }
            try insert(note); selectedNote = note.id
            if portable == nil && autoTranscribe && downloadsAllowed { enqueue(note.id) }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            errorMessage = "Could not import audio: \(error.localizedDescription)"
        }
    }
    func enqueue(_ id: UUID, speakersOnly: Bool = false) {
        guard let note = note(id), note.trashedAt == nil, note.status != .recording, note.playbackUnavailable == nil,
              processingID != id, finalizingID != id, !queue.contains(id), audioURL(note) != nil else { return }
        guard update(id, { $0.status = .queued; $0.failureMessage = nil; $0.language = language }) else { return }
        if speakersOnly { speakerOnlyJobs.insert(id) }
        queue.append(id); processNext()
    }
    private func processNext() {
        guard processingTask == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let note = note(id), let url = audioURL(note), note.trashedAt == nil else { processNext(); return }
        processingID = id; processingProgress = nil; processingMessage = "Preparing…"
        guard update(id, { $0.status = .transcribing }) else { processingID = nil; processNext(); return }
        let allowDownload = downloadsAllowed
        let onlySpeakers = speakerOnlyJobs.remove(id) != nil
        let analyzeSpeakers = onlySpeakers || (identifySpeakers && (speakerDownloadsAllowed || speakerModelsInstalled))
        let allowSpeakerDownload = speakerDownloadsAllowed
        let generation = voiceGeneration
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish transcription") { [weak self] in
            Task { @MainActor in self?.suspendTranscriptions() }
        }
        processingTask = Task {
            do {
                if !onlySpeakers {
                    let transcript = try await speech.transcribe(url: url, locale: note.language, allowDownload: allowDownload) { [self] message, progress in
                        guard processingID == id else { return }
                        processingMessage = message; processingProgress = progress
                    }
                    try Task.checkCancellation()
                    guard update(id, {
                        $0.saveCurrentVersion(name: "Previous transcript")
                        $0.transcript = transcript; $0.speakers = []; $0.selectedVersionID = nil
                        $0.saveCurrentVersion(name: "On-device transcription")
                        $0.failureMessage = nil
                    }) else { throw CocoaError(.fileWriteUnknown) }
                }
                if analyzeSpeakers {
                    do {
                        let analysis = try await speakerAnalyzer.analyze(url, allowDownload: allowSpeakerDownload) { [weak self] message, progress in
                            Task { @MainActor in
                                guard self?.processingID == id else { return }
                                self?.processingMessage = message; self?.processingProgress = progress
                            }
                        }
                        try Task.checkCancellation()
                        try applySpeakerAnalysis(analysis, to: id, allowEvidence: generation == voiceGeneration)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        update(id) { $0.speakerAnalysisMessage = "Speaker analysis could not finish: \(error.localizedDescription). Your transcript is saved. You can retry from Speakers." }
                    }
                }
                try Task.checkCancellation()
                update(id) { $0.status = .ready; $0.failureMessage = nil }
            } catch is CancellationError {
                // Cancellation state was saved when the user or OS requested it.
            } catch {
                if !Task.isCancelled { update(id) { $0.status = .failed; $0.failureMessage = error.localizedDescription } }
            }
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
            processingID = nil; processingTask = nil; processingProgress = nil
            processNext()
        }
    }
    func cancelTranscription(_ id: UUID, reason: String? = nil) {
        queue.removeAll { $0 == id }; speakerOnlyJobs.remove(id)
        if processingID == id { processingTask?.cancel() }
        update(id) { $0.status = $0.transcript.isEmpty ? .audioOnly : .ready; $0.failureMessage = reason }
    }
    private func suspendTranscriptions() {
        let reason = "Transcription paused when iOS suspended the app. Keep Cassini open and try again."
        let pending = queue
        for id in pending { cancelTranscription(id, reason: reason) }
        if let processingID { cancelTranscription(processingID, reason: reason) }
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
        }
    }
    func trash(_ id: UUID) {
        guard recorder.noteID != id else { return }
        if note(id)?.status == .queued || processingID == id { cancelTranscription(id) }
        if player.noteID == id { player.stop() }
        if update(id, { $0.trashedAt = Date() }) { selectedNote = nil }
    }
    func restore(_ id: UUID) { update(id) { $0.trashedAt = nil } }
    func deletePermanently(_ id: UUID) {
        guard note(id)?.trashedAt != nil, let repository else { return }
        guard let voiceLibrary else { errorMessage = "Saved voice storage could not be read. Restore access before permanent deletion so voice samples can be removed safely."; return }
        do {
            try voiceLibrary.removeEvidence(noteID: id)
            savedVoices = voiceLibrary.voices
            try repository.delete(id); notes.removeAll { $0.id == id }
        }
        catch { errorMessage = "Could not delete recording: \(error.localizedDescription)" }
    }
    func addBookmark(_ id: UUID, at time: Double) {
        update(id) { note in
            guard !note.bookmarks.contains(where: { abs($0.time - time) < 1 }) else { return }
            note.bookmarks.append(Bookmark(time: min(time, max(note.duration, time)), label: "Moment at \(TimeText.clock(time))"))
            note.bookmarks.sort { $0.time < $1.time }
        }
    }
    func loadPlayer(_ note: Note) {
        guard !recorder.isActive, note.playbackUnavailable == nil, let url = audioURL(note) else { return }
        do { try player.load(note, url: url) } catch { errorMessage = error.localizedDescription }
    }
    func togglePlayback() {
        do { if player.isPlaying { player.pause() } else { try player.play() } }
        catch { errorMessage = error.localizedDescription }
    }
}
