import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

@Suite struct JobStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_791_452_460)

    private func store() -> JobStore { JobStore(repository: JobRepository(root: root)) }
    private func ids(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

    @Test func aPersistedJobKeepsItsBackendWhenThePreferenceChanges() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = store(), id = UUID()
        try await jobs.enqueue(id, kind: .transcribe, language: "", now: now, recognizer: "whistle")
        try await jobs.transition(id, now: now) { $0.state = .paused }
        let resumed = try await jobs.enqueue(id, kind: .transcribe, language: "", now: now, recognizer: "appleSpeech")
        #expect(resumed.recognizer == "whistle")
        let reopened = store()
        _ = try await reopened.load()
        #expect(await reopened.job(id)?.recognizer == "whistle")
    }

    // ports: JobRepositoryTest#enqueueAddsAtTheBack
    @Test func enqueueAddsAtTheBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = store()
        let (a, b) = { let ids = ids(2); return (ids[0], ids[1]) }()
        #expect(try await jobs.enqueue(a, kind: .transcribe, language: "en-US", now: now).seq == 1)
        #expect(try await jobs.enqueue(b, kind: .transcribe, language: "en-US", now: now).seq == 2)
        let first = try #require(await jobs.job(a))
        #expect(first.state == .queued)
        #expect(first.attempts == 0)
    }

    // ports: JobRepositoryTest#enqueueLeavesQueuedAndRunningJobs
    @Test func enqueueLeavesQueuedAndRunningJobs() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = store()
        let ids = ids(2)
        for id in ids { try await jobs.enqueue(id, kind: .transcribe, language: "", now: now) }
        let queued = try #require(await jobs.job(ids[0]))
        #expect(try await jobs.enqueue(ids[0], kind: .transcribe, language: "", now: now) == queued)
        _ = try await jobs.claimNext(now: now)
        let running = try await jobs.enqueue(ids[0], kind: .transcribeAgain, language: "", now: now)
        #expect(running.state == .running)
        #expect(running.kind == .transcribe)
        #expect(running.seq == 1)
    }

    // ports: JobRepositoryTest#enqueueRequeuesStoppedJobsWithAFreshStart
    @Test func enqueueRequeuesStoppedJobsWithAFreshStart() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = store()
        let ids = ids(4)
        for id in ids { try await jobs.enqueue(id, kind: .transcribe, language: "", now: now) }
        try await jobs.transition(ids[0], now: now) { $0.state = .paused; $0.pauseReason = .memory; $0.attempts = 3 }
        try await jobs.transition(ids[1], now: now) { $0.state = .failed; $0.failure = .modelDownload; $0.attempts = 1 }
        try await jobs.transition(ids[2], now: now) { $0.state = .needsConsent }

        var seqs: [Int] = []
        for id in ids.prefix(3) {
            let queued = try await jobs.enqueue(id, kind: .transcribeAgain, language: "", now: now)
            #expect(await jobs.job(id) == queued)
            #expect(queued.state == .queued)
            #expect(queued.pauseReason == nil)
            #expect(queued.failure == nil)
            #expect(queued.attempts == 0)
            #expect(queued.kind == .transcribeAgain)
            seqs.append(queued.seq)
        }
        #expect(seqs == [5, 6, 7])
        #expect(await jobs.job(ids[3])?.seq == 4)
    }

    // ports: JobRepositoryTest#claimNextIsFifoWithOneRunningJob
    @Test func claimNextIsFifoWithOneRunningJob() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = store()
        let ids = ids(3)
        for id in ids.reversed() { try await jobs.enqueue(id, kind: .transcribe, language: "", now: now) }

        #expect(try await jobs.claimNext(now: now)?.noteID == ids[2])
        #expect(try await jobs.claimNext(now: now) == nil, "one job runs at a time")

        try await jobs.remove(ids[2])
        #expect(try await jobs.claimNext(now: now)?.noteID == ids[1])
        try await jobs.transition(ids[1], now: now) { $0.state = .paused; $0.pauseReason = .user }
        #expect(try await jobs.claimNext(now: now)?.noteID == ids[0])
        try await jobs.transition(ids[0], now: now) { $0.state = .failed; $0.failure = .model }
        #expect(try await jobs.claimNext(now: now) == nil)

        // Resume puts the paused note at the back, and it is the next to run.
        try await jobs.enqueue(ids[1], kind: .transcribe, language: "", now: now)
        #expect(try await jobs.claimNext(now: now)?.noteID == ids[1])
    }

    // ports: JobRepositoryTest#claimNextSkipsTrashedNotes
    @Test func claimNextSkipsTheNotesItIsToldTo() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = store()
        let ids = ids(2)
        for id in ids { try await jobs.enqueue(id, kind: .transcribe, language: "", now: now) }
        #expect(try await jobs.claimNext(now: now, skipping: [ids[0]])?.noteID == ids[1])
    }

    // ports: JobRepositoryTest#concurrentClaimsRunOneJob
    @Test func concurrentClaimsRunOneJob() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = store()
        let ids = ids(8)
        for id in ids { try await jobs.enqueue(id, kind: .transcribe, language: "", now: now) }
        let now = now
        let claimed = await withTaskGroup(of: Job?.self) { group in
            for _ in 0..<16 { group.addTask { try? await jobs.claimNext(now: now) } }
            return await group.reduce(into: [Job]()) { if let job = $1 { $0.append(job) } }
        }
        #expect(claimed.map(\.noteID) == [ids[0]])
        #expect(await jobs.all().filter { $0.state == .running }.count == 1)
    }

    // ports: JobRepositoryTest#transitionsKeepTheirNumbers
    @Test func transitionsKeepTheirNumbersAndSurviveAReload() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = store()
        let id = UUID()
        try await jobs.enqueue(id, kind: .transcribe, language: "it-IT", now: now)
        _ = try await jobs.claimNext(now: now)
        let later = now.addingTimeInterval(60)
        let paused = try #require(try await jobs.transition(id, now: later) {
            $0.state = .paused; $0.pauseReason = .system; $0.doneMs = 56_000; $0.totalMs = 90_000; $0.words = 70
            $0.seq = 99
        })
        #expect(paused.seq == 1, "a transition never moves a job in the queue")
        #expect(paused.updatedAt == later)

        let reloaded = store()
        #expect(try await reloaded.load() == [paused])

        try await jobs.remove(id)
        #expect(await jobs.job(id) == nil)
        #expect(try await jobs.transition(id, now: now) { $0.state = .queued } == nil)
        #expect(try await store().load().isEmpty)
    }

    @Test func aRequeuedJobKeepsTheNumbersOfItsSavedProgress() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = store()
        let id = UUID()
        try await jobs.enqueue(id, kind: .transcribe, language: "it-IT", now: now)
        try await jobs.transition(id, now: now) {
            $0.state = .paused; $0.pauseReason = .user; $0.doneMs = 28_000; $0.totalMs = 60_000; $0.words = 40
        }
        let resumed = try await jobs.enqueue(id, kind: .transcribe, language: nil, now: now)
        #expect(resumed.state == .queued)
        #expect(resumed.doneMs == 28_000 && resumed.totalMs == 60_000 && resumed.words == 40)
        #expect(resumed.language == "it-IT", "a nil language keeps the job's")
    }

    // ports: JobRepositoryTest#trashPortsRequeueAndCancel
    @Test func restoreRequeuesAtTheBackAndRecreatesAMissingJobFromItsSavedProgress() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = store()
        let ids = ids(3)
        try await jobs.enqueue(ids[0], kind: .transcribe, language: "", now: now)
        try await jobs.enqueue(ids[1], kind: .transcribe, language: "", now: now)

        // A queued job that still exists goes to the back.
        #expect(try await jobs.requeueAtBack(ids[0], kind: .transcribe, language: "", checkpoint: .missing, now: now)?.seq == 3)
        // Restore of a note whose job is missing creates it, with the numbers of its saved progress.
        let created = try #require(try await jobs.requeueAtBack(
            ids[2], kind: .transcribeAgain, language: "it-IT",
            checkpoint: .saved(doneMs: 28_000, totalMs: 60_000, words: 3), now: now))
        #expect(created.kind == .transcribeAgain && created.seq == 4)
        #expect(created.doneMs == 28_000 && created.words == 3 && created.language == "it-IT")

        // A running job is left alone.
        #expect(try await jobs.claimNext(now: now)?.noteID == ids[1])
        let running = try await jobs.requeueAtBack(ids[1], kind: .transcribe, language: "", checkpoint: .missing, now: now)
        #expect(running?.state == .running && running?.seq == 2)
    }

    @Test func replaceWritesEveryChangeAtOnceAndIgnoresUnknownJobs() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = store()
        let ids = ids(2)
        for id in ids { try await jobs.enqueue(id, kind: .transcribe, language: "", now: now) }
        var first = try #require(await jobs.job(ids[0])); first.state = .failed; first.failure = .checkpointMismatch
        let stranger = Job(noteID: UUID(), seq: 9, kind: .transcribe, enqueuedAt: now)
        try await jobs.replace([first, stranger])
        #expect(try await store().load() == [first, try #require(await jobs.job(ids[1]))])
    }

    @Test func aNewerQueueFileIsKeptAndTakesNoWrites() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(JobRepository.filename)
        let newer = Data(#"{"version":2,"jobs":[{"from":"a newer Cassini"}]}"#.utf8)
        try newer.write(to: file)
        #expect(throws: JobRepository.Failure.unsupportedVersion(2)) { try JobRepository(root: root).load() }

        let jobs = store()
        await #expect(throws: JobStore.Failure.newerVersion(2)) { try await jobs.load(now: now) }
        #expect(await jobs.isWritable == false)
        await #expect(throws: JobStore.Failure.readOnly) {
            try await jobs.enqueue(UUID(), kind: .transcribe, language: "", now: now)
        }
        #expect(try Data(contentsOf: file) == newer, "the newer file is never overwritten")
    }

    @Test func anUnreadableQueueFileIsMovedAsideAndTheQueueStartsEmpty() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(JobRepository.filename)
        let broken = Data("{\"version\":1,\"jobs\":[{".utf8)
        try broken.write(to: file)

        let jobs = store()
        let failure = await #expect(throws: JobStore.Failure.self) { try await jobs.load(now: now) }
        guard case .unreadable(let movedTo?) = failure else {
            Issue.record("expected the file to be moved aside, got \(String(describing: failure))")
            return
        }
        #expect(movedTo.lastPathComponent.hasPrefix("jobs.json.unreadable-"))
        #expect(try Data(contentsOf: movedTo) == broken)
        #expect(await jobs.isWritable)
        let id = UUID()
        try await jobs.enqueue(id, kind: .transcribe, language: "", now: now)
        #expect(try JobRepository(root: root).load().map(\.noteID) == [id])
        #expect(try Data(contentsOf: movedTo) == broken, "the new queue never touches the unreadable one")
    }

    @Test func aRepairThatCannotBeWrittenStillChangesTheQueueInMemory() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = store()
        let (a, b) = { let ids = ids(2); return (ids[0], ids[1]) }()
        try await jobs.enqueue(a, kind: .transcribe, language: "", now: now)
        try await jobs.enqueue(b, kind: .transcribe, language: "", now: now)
        var running = try #require(try await jobs.claimNext(now: now))
        running.state = .queued
        await jobs.assume([running], removing: [b])
        #expect(await jobs.all().map(\.noteID) == [a])
        #expect(try JobRepository(root: root).load().map(\.state) == [.running, .queued], "nothing was written")
        #expect(try await jobs.claimNext(now: now)?.noteID == a, "the queue goes on")
        #expect(try JobRepository(root: root).load().map(\.noteID) == [a], "the next write saves the repair")
    }
}
