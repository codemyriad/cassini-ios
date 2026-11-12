import Foundation
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// A disk update already in flight need not obey task cancellation. Its entry/release are explicit events.
private actor RecordingFinishWriteGate {
    private var armed = false
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private(set) var seals = 0

    func arm() { armed = true }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func beforeUpdate() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation in
            release = continuation
            entered = true
            entry?.resume(); entry = nil
        }
    }
    func open() { release?.resume(); release = nil }
    func sealed() { seals += 1 }
}

private final class HeldRecordingFinishNotes: RecordingNotes {
    let base: CountingRecordingNotes
    let gate: RecordingFinishWriteGate
    init(_ base: CountingRecordingNotes, gate: RecordingFinishWriteGate) { self.base = base; self.gate = gate }
    func create(_ note: Note) async throws { try await base.create(note) }
    func note(_ id: UUID) async -> Note? { await base.note(id) }
    func captureURL(for note: Note) async -> URL? { await base.captureURL(for: note) }
    func discard(_ id: UUID) async throws { try await base.discard(id) }
    func showUnsaved(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async {
        await base.showUnsaved(id, change)
    }
    func update(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async throws -> Note? {
        await gate.beforeUpdate()
        let before = await base.note(id)
        let after = try await base.update(id, change)
        if before?.audio == .live, after?.audio == .plain { await gate.sealed() }
        return after
    }
}

@MainActor @Suite(.serialized) struct RecordingFinishAdmissionTests {
    /// Wait for the real title task's debounce registration and the real notes update to enter the gate.
    private func holdTitle(_ title: String, in h: RecordingHarness, gate: RecordingFinishWriteGate) async {
        let sleeping = AsyncStream<Void>.makeStream()
        let debounce = RecordingHarness.debounce
        h.clock.onSleep = { duration in
            if duration == debounce { sleeping.continuation.yield(()) }
        }
        defer { h.clock.onSleep = nil; sleeping.continuation.finish() }
        await gate.arm()
        h.controller.setTitle(title)
        var sleeps = sleeping.stream.makeAsyncIterator()
        _ = await sleeps.next()
        h.clock.advance(by: RecordingHarness.debounce)
        await gate.waitUntilEntered()
    }

    @Test func finishAdmitsOnceBeforeYieldWhileTheTitleWriteIsHeld() async throws {
        let gate = RecordingFinishWriteGate()
        let h = try RecordingHarness(recordingNotes: { HeldRecordingFinishNotes($0, gate: gate) })
        defer { h.audio.set(held: false); h.tearDown() }
        #expect(h.controller.start())
        await h.controller.operations?.value
        let active = try h.active
        h.capture.elapsed = 2
        await holdTitle("Draft title", in: h, gate: gate)
        h.audio.set(held: true)

        h.controller.finish(title: "  Final title  ")
        // No yield: the click itself must admit the finish, before any disk/capture/compression work.
        #expect(h.controller.state == .finishing(noteID: active.noteID))
        h.controller.finish(title: "Wrong duplicate")
        h.controller.setTitle("Too late")
        #expect(!h.controller.start())
        #expect(h.capture.stops == 0)
        #expect(await gate.seals == 0)

        await gate.open()
        await h.controller.operations?.value
        #expect(h.controller.state == .ended(noteID: active.noteID, outcome: .saved(.transcribe)))
        let sealed = try #require(await h.note(active.noteID))
        #expect(sealed.title == "Final title" && sealed.audio == .plain && sealed.duration == 2)
        #expect(sealed.status == .queued)
        #expect(h.capture.stops == 1 && h.handoff.handedOff.isEmpty)
        #expect(await gate.seals == 1)
        #expect(h.controller.finalizing.contains(active.noteID))
        #expect(FileManager.default.fileExists(atPath: h.store.directory(for: active.noteID).appendingPathComponent("capture.caf").path))

        h.audio.set(held: false)
        await h.controller.settle()
        let ready = try #require(await h.note(active.noteID))
        #expect(ready.title == "Final title" && ready.audio == .plain)
        #expect(ready.audioFilename == "audio.m4a")
        #expect(FileManager.default.fileExists(atPath: h.store.directory(for: active.noteID).appendingPathComponent(ready.audioFilename).path))
        #expect(h.handoff.handedOff == [active.noteID])
        #expect(h.capture.stops == 1 && !h.controller.finalizing.contains(active.noteID))
        #expect(await gate.seals == 1)
    }

    @Test func recordingScreenShowsSavingInTheFinishTurnWhileTheTitleWriteIsHeld() async throws {
        let gate = RecordingFinishWriteGate()
        let s = try RecordingScreenModelTests.Screen(recordingNotes: { HeldRecordingFinishNotes($0, gate: gate) })
        defer { s.h.tearDown() }
        await s.model.enter()
        await s.h.controller.operations?.value
        let active = try s.h.active
        await holdTitle("  Weekly sync  ", in: s.h, gate: gate)

        s.model.finish()
        #expect(s.model.phase == .stopping)
        #expect(s.h.controller.state == .finishing(noteID: active.noteID))
        #expect(s.model.title == "  Weekly sync  ")
        s.model.finish()
        s.model.pauseOrResume()
        #expect(s.h.capture.stops == 0)

        await gate.open()
        await s.h.controller.settle()
        #expect(s.h.capture.stops == 1)
        #expect(await s.h.note(active.noteID)?.title == "Weekly sync")
        #expect(s.h.handoff.handedOff == [active.noteID])
        #expect(await gate.seals == 1)
    }

    @Test func aFailedStartAfterFinishAdmissionDiscardsWithoutStoppingOrSealingTwice() async throws {
        let gate = RecordingFinishWriteGate()
        let h = try RecordingHarness(recordingNotes: { HeldRecordingFinishNotes($0, gate: gate) })
        defer { h.tearDown() }
        await gate.arm()
        #expect(h.controller.start())
        await gate.waitUntilEntered() // Initial position-zero write: capture is active but start is still serializing.
        let active = try h.active
        h.controller.finish()
        #expect(h.controller.state == .finishing(noteID: active.noteID))
        h.notes.failUpdates = true
        await gate.open()
        await h.controller.settle()
        #expect(h.controller.state == .ended(noteID: nil, outcome: .couldNotStart))
        #expect(h.capture.stops == 1)
        #expect(await h.store.all().isEmpty)
        #expect(await gate.seals == 0)
        #expect(h.handoff.handedOff.isEmpty)
    }

    @Test func anEarlierMicrophoneFailureCannotBecomeAUserTranscriptionRequest() async throws {
        let h = try RecordingHarness()
        defer { h.tearDown() }
        #expect(h.controller.start())
        await h.controller.operations?.value
        let active = try h.active
        h.controller.handle(.failed)
        #expect(h.controller.state == .finishing(noteID: active.noteID))
        h.controller.finish()
        await h.controller.settle()
        #expect(h.controller.state == .ended(noteID: active.noteID, outcome: .microphoneFailed))
        #expect(h.capture.stops == 1 && h.handoff.handedOff.isEmpty)
        #expect(await h.note(active.noteID)?.status == .audioOnly)
    }
}
