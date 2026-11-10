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
    static let longID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let silentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let reviewID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let fixtureDuration: TimeInterval = 24
    static let processingDuration: TimeInterval = 48 * 60 + 13
    /// The audio the processing seed's job transcribes between two results, 1.2 s apart: its card shows 1–2 minutes
    /// left for the 18 minutes of audio still to go.
    static let processingPace: TimeInterval = 10
    /// Where the recording seed's capture starts under `--capture-held`; it holds 7 s later, at 24:07.
    static let heldCaptureStart: TimeInterval = 24 * 60
    /// A waveform's worth (56 bars) of levels that rise and fall like speech, with two short pauses.
    static let speechLevels: [Float] = (0..<WaveformBars.count).map { bar in
        let x = Double(bar)
        if (18...20).contains(bar) || (39...40).contains(bar) { return 0.04 }
        return Float(0.25 + 0.35 * abs(sin(x * 0.55)) * (0.6 + 0.4 * abs(sin(x * 0.13 + 1))) + 0.15 * abs(sin(x * 1.7)))
    }

    static let transcribedSegments: [TranscriptSegment] = [
        .init(text: "What if being productive meant paying closer attention, rather than doing more?", start: 0, end: 6, speaker: "Alex", speakerID: "alex"),
        .init(text: "The best ideas usually arrive in the space between things. A walk, a conversation, a moment to pause.", start: 6, end: 14, speaker: "Sam", speakerID: "sam"),
        .init(text: "Let’s protect an hour on Thursday for focused work. No notifications, no meetings. Just room to think.", start: 14, end: 24, speaker: "Alex", speakerID: "alex"),
    ]

    /// The speaker analysis of the recording seed: two voices taking turns as in `transcribedSegments`.
    static let recordingAnalysis = SpeakerAnalysis(
        turns: [SpeakerTurn(speakerID: "s1", start: 0, end: 6), SpeakerTurn(speakerID: "s2", start: 6, end: 14),
                SpeakerTurn(speakerID: "s1", start: 14, end: 24)],
        prints: [SpeakerPrint(speakerID: "s1", model: VoiceprintModel.sha256, vector: [1, 0, 0], speechSeconds: 16),
                 SpeakerPrint(speakerID: "s2", model: VoiceprintModel.sha256, vector: [0, 1, 0], speechSeconds: 8)])

    /// What the processing seed's frozen job has finalized by 62 %: the start of a planning call.
    static let processingDraft: [TranscriptSegment] = [
        (0, "Morning, everyone. Three things on the agenda today: the launch date, the onboarding copy and hiring."),
        (9, "Let’s start with the launch. Engineering thinks the last two weeks of November are realistic."),
        (17, "That leaves a week of buffer before the holidays, which I’d rather keep than spend."),
    ].map { start, text in timedSegment(text, start: start, end: start + 8.5) }

    /// The draft of `--draft-growing`: 120 sentences of 3 s, each its own words.
    static let growingDraft: [TranscriptSegment] = (0..<120).map { index in
        let start = Double(index) * 3
        let texts = "Sentence \(index + 1) of the running draft keeps arriving.".split(separator: " ").map(String.init)
        let words = texts.enumerated().map { offset, text in
            TimedWord(text: (offset == 0 ? "" : " ") + text, start: start + Double(offset) * 0.3,
                      end: start + Double(offset) * 0.3 + 0.25)
        }
        return TranscriptSegment(text: texts.joined(separator: " "), start: start, end: start + 3, words: words)
    }

    /// A passage whose words share its span evenly, as Apple's results carry their own times; its speaker is
    /// `speaker`'s.
    private static func timedSegment(_ text: String, start: TimeInterval, end: TimeInterval,
                                     _ speaker: TranscriptSegment? = nil) -> TranscriptSegment {
        let texts = text.split(separator: " ").map(String.init)
        let step = (end - start) / Double(texts.count)
        let words = texts.enumerated().map { offset, word in
            TimedWord(text: (offset == 0 ? "" : " ") + word, start: start + Double(offset) * step,
                      end: start + Double(offset + 1) * step)
        }
        return TranscriptSegment(text: text, start: start, end: end, speaker: speaker?.speaker,
                                 speakerID: speaker?.speakerID, words: words)
    }

    private static let waveform = (0..<96).map { Float(0.15 + abs(sin(Double($0) * 0.73)) * 0.55) }

    /// Writes the notes of `seed` into an empty library. `recognizer` is the device's: a seeded job and its saved
    /// progress are that recognizer's, so they resume where the system has no Apple speech; Apple speech's job is a
    /// legacy one, without an identity.
    static func seed(_ seed: AppEnvironment.Seed, into store: NoteStore, now: Date,
                     recognizer: SpeechRecognizer = .appleSpeech) async throws {
        guard try store.root.isEmptyDirectory else { return }
        var main = fixture(now: now)
        var notes: [Note] = []
        switch seed {
        case .speakers:
            // Sam is not named yet, and the saved voice "Sam Rivera" may be them: the note asks "Is this Sam Rivera?".
            let sam = try seedSuggestedVoice(root: store.root)
            main.speakers?[1].name = DefaultLabels.placeholder(2)
            main.speakers?[1].match = .suggested(voice: sam, score: 0.78)
            main.refreshSpeakerLabels()
        case .voices:
            notes = try seedSavedVoices(root: store.root, main: &main, now: now)
        case .reading:
            main.transcript = transcribedSegments.map { timedSegment($0.text, start: $0.start, end: $0.end, $0) }
        default:
            break
        }
        notes = [main, walk(now: now)] + notes
        switch seed {
        case .library, .recording, .voices, .speakers:
            break
        case .search, .reading:
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
        case .long:
            var silent = Note(id: silentID, title: "Silent memo", createdAt: now.addingTimeInterval(-4 * 3600), audioFilename: "audio.wav")
            silent.duration = fixtureDuration; silent.status = .ready; silent.language = "en-US"; silent.waveform = waveform
            notes += [long(now: now), silent]
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
        if seed == .statuses { try await seedStatusJobs(into: store, now: now, recognizer: recognizer) }
    }

    /// What a seed needs once the app is ready: consent and a running job for `processing`, whose speaker step is
    /// ahead of it, and for `statuses`, whose job has none.
    @MainActor static func prepare(_ seed: AppEnvironment.Seed, settings: SettingsStore, processing: ProcessingStore) {
        guard seed == .processing || seed == .statuses else { return }
        settings.recordConsent()
        settings.identifySpeakers = seed == .processing
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
    private static func seedStatusJobs(into store: NoteStore, now: Date, recognizer: SpeechRecognizer) async throws {
        let audio = store.directory(for: pausedID).appendingPathComponent("audio.wav")
        try CheckpointFiles(notes: store).save(CheckpointState(
            source: "audio.wav", signature: CheckpointState.signature(of: audio), model: recognizer.checkpointModel(language: "en-US"), segments: [],
            doneMs: pausedDoneMs, totalMs: Int64(fixtureDuration * 1000), elapsedMs: 1_000), for: pausedID)
        try JobRepository(root: store.root).save([
            Job(noteID: pausedID, seq: 1, kind: .transcribe, state: .paused, pauseReason: .user, doneMs: pausedDoneMs,
                totalMs: Int64(fixtureDuration * 1000), language: "en-US", enqueuedAt: now,
                recognizer: recognizer == .appleSpeech ? nil : recognizer.rawValue),
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

    /// Three hours of two speakers in 60 passages; only the last one says "lighthouse".
    private static func long(now: Date) -> Note {
        var note = Note(id: longID, title: "Three hour workshop", createdAt: now.addingTimeInterval(-3 * 3600), audioFilename: "audio.wav")
        note.duration = 3 * 3600; note.status = .ready; note.language = "en-US"; note.waveform = waveform
        note.speakers = [NoteSpeaker(id: "alex", name: "Alex"), NoteSpeaker(id: "sam", name: "Sam")]
        note.transcript = (0..<60).map { index in
            let speaker = note.speakers![index % 2]
            let text = index == 59 ? "We end the day at the lighthouse." : "Passage \(index + 1) goes over the plan for the next quarter in some detail, one point at a time."
            return TranscriptSegment(text: text, start: Double(index) * 180, end: Double(index + 1) * 180,
                                     speaker: speaker.name, speakerID: speaker.id)
        }
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

    /// The saved voice "Sam Rivera", with a sample from the morning walk. Returns its id.
    private static func seedSuggestedVoice(root: URL) throws -> UUID {
        let library = try VoiceLibrary(root: root)
        let sam = voicePrint("sam", [0, 1, 0], seconds: 12), alex = voicePrint("alex", [1, 0, 0], seconds: 12)
        try library.savePrints([alex, sam], noteID: fixtureID)
        let voice = SavedVoice(name: "Sam Rivera", samples: [.init(noteID: walkID, print: sam)])
        try library.save([voice])
        return voice.id
    }

    /// Three saved voices, each confirmed in the notes it was named in: Alex Moreau and Sam Rivera in `main`, which
    /// takes their full names, and Alex Moreau and Giulia Conti in the design review this returns.
    private static func seedSavedVoices(root: URL, main: inout Note, now: Date) throws -> [Note] {
        let library = try VoiceLibrary(root: root)
        var review = Note(id: reviewID, title: "Notes from the design review", createdAt: now.addingTimeInterval(-9 * 86_400),
                          audioFilename: "audio.wav")
        review.duration = fixtureDuration; review.status = .ready; review.language = "en-US"; review.waveform = waveform
        review.transcript = [
            .init(text: "The review agreed to keep the timeline focused.", start: 0, end: 12, speakerID: "giulia"),
            .init(text: "And we revisit the colours next week.", start: 12, end: 24, speakerID: "alex"),
        ]
        let alexHere = voicePrint("alex", [1, 0, 0], seconds: 96), samHere = voicePrint("sam", [0, 1, 0], seconds: 74)
        let alexThere = voicePrint("alex", [1, 0, 0], seconds: 41), giulia = voicePrint("giulia", [0, 0, 1], seconds: 88)
        try library.savePrints([alexHere, samHere], noteID: fixtureID)
        try library.savePrints([giulia, alexThere], noteID: reviewID)
        let voices = [
            SavedVoice(name: "Alex Moreau", samples: [.init(noteID: fixtureID, print: alexHere), .init(noteID: reviewID, print: alexThere)]),
            SavedVoice(name: "Sam Rivera", samples: [.init(noteID: fixtureID, print: samHere)]),
            SavedVoice(name: "Giulia Conti", samples: [.init(noteID: reviewID, print: giulia)]),
        ]
        try library.save(voices)
        main.speakers = [NoteSpeaker(id: "alex", name: "Alex Moreau", match: .confirmed(voice: voices[0].id, score: 0.91)),
                         NoteSpeaker(id: "sam", name: "Sam Rivera", match: .confirmed(voice: voices[1].id, score: 0.88))]
        main.refreshSpeakerLabels()
        review.speakers = [NoteSpeaker(id: "giulia", name: "Giulia Conti", match: .confirmed(voice: voices[2].id, score: 0.9)),
                           NoteSpeaker(id: "alex", name: "Alex Moreau", match: .confirmed(voice: voices[0].id, score: 0.86))]
        review.refreshSpeakerLabels()
        return [review]
    }

    private static func voicePrint(_ speaker: String, _ vector: [Float], seconds: Double) -> SpeakerPrint {
        SpeakerPrint(speakerID: speaker, model: VoiceprintModel.sha256, vector: vector, speechSeconds: seconds)
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
