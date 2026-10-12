#if DEBUG
import AVFoundation
import CassiniEngine
import CassiniNotebook

/// UI automation and screenshots only. These notes never appear in an ordinary installation.
enum TestFixtures {
    static let fixtureID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    static let walkID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    static let processingID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    static let queuedID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
    static let pausedID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
    static let failedID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
    /// Where the paused note of the statuses seed stopped: "Paused at 00:12".
    static let pausedDoneMs: Int64 = 12_000
    static let fixtureDuration: TimeInterval = 24
    static let processingDuration: TimeInterval = 48 * 60 + 13

    static let transcribedSegments: [TranscriptSegment] = [
        .init(text: "What if being productive meant paying closer attention, rather than doing more?", start: 0, end: 6, speaker: "Alex", speakerID: "alex"),
        .init(text: "The best ideas usually arrive in the space between things. A walk, a conversation, a moment to pause.", start: 6, end: 14, speaker: "Sam", speakerID: "sam"),
        .init(text: "Let’s protect an hour on Thursday for focused work. No notifications, no meetings. Just room to think.", start: 14, end: 24, speaker: "Alex", speakerID: "alex"),
    ]

    private static let waveform = (0..<96).map { Float(0.15 + abs(sin(Double($0) * 0.73)) * 0.55) }

    /// Writes the notes of `seed` into an empty library.
    static func seed(_ seed: AppEnvironment.Seed, into store: NoteStore, now: Date) async throws {
        guard try store.root.isEmptyDirectory else { return }
        var main = fixture(now: now)
        if seed == .speakers || seed == .voices {
            let sam = try seedVoices(root: store.root, seed: seed)
            if seed == .speakers {
                // Sam is not named yet, and the saved voice "Sam Rivera" may be them: the note asks "Is this Sam Rivera?".
                main.speakers?[1].name = DefaultLabels.placeholder(2)
                main.speakers?[1].match = .suggested(voice: sam, score: 0.78)
                main.refreshSpeakerLabels()
            }
        }
        var notes = [main, walk(now: now)]
        switch seed {
        case .library, .recording, .voices, .speakers:
            break
        case .search:
            notes += [transcribed("Garden plans for the spring", at: now.addingTimeInterval(-3 * 86_400),
                                  "We could move the tomatoes to the sunny corner and leave Thursday free for planting."),
                      transcribed("Notes from the design review", at: now.addingTimeInterval(-9 * 86_400),
                                  "The review agreed to keep the timeline focused and revisit the colours next week.")]
        case .trash:
            var week = transcribed("Old interview draft", at: now.addingTimeInterval(-20 * 86_400), "An earlier take of the interview.")
            week.trashedAt = now.addingTimeInterval(-7 * 86_400)
            var yesterday = transcribed("Duplicate voice memo", at: now.addingTimeInterval(-2 * 86_400), "A second copy of the memo.")
            yesterday.trashedAt = now.addingTimeInterval(-86_400)
            notes += [week, yesterday]
        case .processing:
            notes.append(processingCall(now: now))
        case .statuses:
            notes += statusNotes(now: now)
        }
        let audio = store.directory(for: fixtureID).appendingPathComponent("audio.wav")
        for note in notes {
            try await store.save(note)
            let url = store.audioURL(for: note)
            if note.id == fixtureID { try writeSilence(to: url) } else { try FileManager.default.copyItem(at: audio, to: url) }
        }
        if seed == .statuses { try await seedStatusJobs(into: store, now: now) }
    }

    /// What a seed needs once the app is ready: consent and a running job for `processing`.
    @MainActor static func prepare(_ seed: AppEnvironment.Seed, settings: SettingsStore, processing: ProcessingStore) {
        guard seed == .processing || seed == .statuses else { return }
        settings.recordConsent()
        settings.identifySpeakers = false
        Task {
            await processing.transcribe(processingID, origin: .screen)
            // The frozen job never ends, so this one stays queued behind it.
            if seed == .statuses { await processing.transcribe(queuedID, origin: .screen) }
        }
    }

    private static func processingCall(now: Date) -> Note {
        var call = Note(id: processingID, title: "Weekly planning call", createdAt: now.addingTimeInterval(-20 * 60), audioFilename: "audio.wav")
        call.duration = processingDuration; call.language = "en-US"; call.waveform = waveform
        return call
    }

    /// A note for each Library row status but Recording: transcribing and queued (from `prepare`), paused, failed,
    /// can't play, can't read transcript, newer format, no speech, plus the transcribed and audio-only notes of the
    /// library seed.
    private static func statusNotes(now: Date) -> [Note] {
        func audio(_ id: UUID = UUID(), _ title: String, hoursAgo: Double) -> Note {
            var note = Note(id: id, title: title, createdAt: now.addingTimeInterval(-hoursAgo * 3600), audioFilename: "audio.wav")
            note.duration = fixtureDuration; note.language = "en-US"; note.waveform = waveform
            return note
        }
        var queued = audio(queuedID, "Interview with the printer", hoursAgo: 0.5)
        queued.status = .audioOnly
        var paused = audio(pausedID, "Paused standup", hoursAgo: 3)
        paused.status = .audioOnly
        var failed = audio(failedID, "Hallway conversation", hoursAgo: 4)
        failed.status = .failed; failed.failure = .audio
        var unplayable = audio(UUID(), "Interrupted capture", hoursAgo: 5)
        unplayable.audio = .unplayable(.interrupted)
        var unreadable = transcribed("Damaged document", at: now.addingTimeInterval(-6 * 3600), "Some words that were read.")
        unreadable.origin = .importedDocument; unreadable.document = DocumentInfo(state: .unreadable)
        var newer = transcribed("Document from a newer Cassini", at: now.addingTimeInterval(-7 * 3600), "Words from the future.")
        newer.origin = .importedDocument; newer.document = DocumentInfo(state: .unknownFormat)
        var silent = audio(UUID(), "Quiet room", hoursAgo: 8)
        silent.status = .ready
        return [processingCall(now: now), queued, paused, failed, unplayable, unreadable, newer, silent]
    }

    /// The paused job (with the saved progress it resumes from) and the failed one of the statuses seed.
    private static func seedStatusJobs(into store: NoteStore, now: Date) async throws {
        let audio = store.directory(for: pausedID).appendingPathComponent("audio.wav")
        try CheckpointFiles(notes: store).save(CheckpointState(
            source: "audio.wav", signature: CheckpointState.signature(of: audio), language: "en-US", segments: [],
            doneMs: pausedDoneMs, totalMs: Int64(fixtureDuration * 1000), elapsedMs: 1_000), for: pausedID)
        try JobRepository(root: store.root).save([
            Job(noteID: pausedID, seq: 1, kind: .transcribe, state: .paused, pauseReason: .user, doneMs: pausedDoneMs,
                totalMs: Int64(fixtureDuration * 1000), language: "en-US", enqueuedAt: now),
            Job(noteID: failedID, seq: 2, kind: .transcribe, state: .failed, failure: .audio, language: "en-US", enqueuedAt: now),
        ])
    }

    private static func fixture(now: Date) -> Note {
        var note = Note(id: fixtureID, title: "A quieter kind of productivity", createdAt: now.addingTimeInterval(-2 * 3600), audioFilename: "audio.wav")
        note.duration = fixtureDuration; note.status = .ready; note.language = "en-US"; note.isFavorite = true
        note.transcript = transcribedSegments
        note.speakers = [NoteSpeaker(id: "alex", name: "Alex"), NoteSpeaker(id: "sam", name: "Sam")]
        note.bookmarks = [.init(time: 14, label: "Make room for focused work")]
        note.waveform = waveform
        return note
    }

    private static func walk(now: Date) -> Note {
        var note = Note(id: walkID, title: "Thoughts from the morning walk", createdAt: now.addingTimeInterval(-86_400), audioFilename: "audio.wav")
        note.duration = fixtureDuration; note.status = .audioOnly; note.language = "en-US"; note.waveform = waveform
        return note
    }

    private static func transcribed(_ title: String, at date: Date, _ text: String) -> Note {
        var note = Note(title: title, createdAt: date, audioFilename: "audio.wav")
        note.duration = fixtureDuration; note.status = .ready; note.language = "en-US"; note.waveform = waveform
        note.transcript = [.init(text: text, start: 0, end: fixtureDuration)]
        return note
    }

    /// Saved voices with samples. Returns Sam's voice, which the speakers seed offers as a match.
    private static func seedVoices(root: URL, seed: AppEnvironment.Seed) throws -> UUID {
        let library = try VoiceLibrary(root: root)
        func print(_ speaker: String, _ vector: [Float]) -> SpeakerPrint {
            SpeakerPrint(speakerID: speaker, model: "fake-model", vector: vector, speechSeconds: 12)
        }
        let sam = print("sam", [0, 1, 0]), alex = print("alex", [1, 0, 0])
        try library.savePrints([alex, sam], noteID: fixtureID)
        var voices = [SavedVoice(name: "Sam Rivera", samples: [.init(noteID: walkID, print: sam)])]
        if seed == .voices {
            voices.append(SavedVoice(name: "Alex Moreau", samples: [.init(noteID: fixtureID, print: alex), .init(noteID: walkID, print: alex)]))
            voices.append(SavedVoice(name: "Giulia Conti", samples: [.init(noteID: walkID, print: print("giulia", [0, 0, 1]))]))
        }
        try library.save(voices)
        return voices[0].id
    }

    private static func writeSilence(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        memset(buffer.floatChannelData![0], 0, 16_000 * MemoryLayout<Float>.size)
        for _ in 0..<Int(fixtureDuration) { try file.write(from: buffer) }
    }
}

private extension URL {
    var isEmptyDirectory: Bool {
        get throws { try FileManager.default.contentsOfDirectory(atPath: path).filter { UUID(uuidString: $0) != nil }.isEmpty }
    }
}
#endif
