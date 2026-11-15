import Foundation
import Observation
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// Same port wiring as the app's LibraryRecordingNotes, over the real mirror and persistence actor.
@MainActor private final class MirroredRecordingNotes: RecordingNotes {
    let library: LibraryStore
    var afterCreate: (@MainActor () async -> Void)?
    var beforeTimestamp: (@MainActor () async -> Void)?
    init(library: LibraryStore) { self.library = library }
    func create(_ note: Note) async throws {
        try await library.insert(note)
        await afterCreate?()
        afterCreate = nil
    }
    func note(_ id: UUID) async -> Note? { library.note(id) }
    func captureURL(for note: Note) async -> URL? { library.audioURL(note) }
    func update(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async throws -> Note? {
        let check = beforeTimestamp
        beforeTimestamp = nil
        await check?()
        return await library.commit(id, change)
    }
    func discard(_ id: UUID) async throws { try await library.delete(id) }
    func showUnsaved(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async {
        library.showUnsaved(id, change)
    }
}

@MainActor @Suite struct LibraryRecordingLifecycleTests {
    @Observable final class QueueFacts { var processing = ProcessingState() }

    enum Finish: CaseIterable { case automatic, manual, missingModels, declined }

    @Test(arguments: Finish.allCases)
    func finishedCapturePublishesThroughTheMirrorAndLibraryModel(finish: Finish) async throws {
        var adapter: MirroredRecordingNotes!
        let h = try RecordingHarness(consented: finish == .automatic, recordingNotes: { notes in
            let library = LibraryStore(noteStore: notes.store, reportFailure: { Issue.record("Unexpected save error: \($0)") })
            let port = MirroredRecordingNotes(library: library)
            adapter = port
            return port
        })
        defer { h.tearDown() }
        let notes = try #require(adapter)
        let library = notes.library
        await library.load()
        h.settings.autoTranscribe = finish != .manual
        if finish == .declined { h.settings.recordDeclined() }
        let screen = RecordingScreenModel(controller: h.controller, ports: .init(
            permission: FakeMicrophonePermission(), modelsMissing: { true }, askNotificationsOnce: {}))
        let context = QueueFacts()
        let model = LibraryScreenModel(ports: .init(
            notes: { library.notes }, loading: { !library.isLoaded }, unavailable: { library.loadFailure != nil },
            processing: { context.processing }, phase: { _ in nil }, install: { nil },
            recording: { h.controller.state }, finishing: { h.controller.finalizing.first },
            transcribe: { _, _ in .queued(changed: false) }, startOver: { _ in .queued(changed: false) },
            stop: { _ in }, dequeue: { _ in }, update: { id, change in library.update(id, change) },
            trash: { _ in }, speakerModelsReady: { true },
            setRecordingTitle: { h.controller.setTitle($0) }, clock: h.clock, calendar: Calendar(identifier: .gregorian)))
        #expect(model.content.sections.isEmpty)
        var effects: [RecordingEffect] = []
        screen.onEffect = { effects.append($0) }
        var sawStarting = false, sawActiveBeforeTimestamp = false
        notes.afterCreate = {
            await model.settle()
            #expect(h.controller.state == .starting)
            #expect(model.content.sections.flatMap(\.rows).first?.status == .audioOnly)
            sawStarting = true
        }
        notes.beforeTimestamp = {
            await model.settle()
            #expect(h.controller.state.isActive)
            #expect(library.notes.first?.meetingTime == .unknown)
            #expect(model.content.sections.flatMap(\.rows).first?.status == .recording)
            sawActiveBeforeTimestamp = true
        }
        await screen.enter()
        await h.controller.operations?.value
        #expect(sawStarting && sawActiveBeforeTimestamp)
        await model.settle()
        let id = try h.active.noteID
        func row() throws -> LibraryRow { try #require(model.content.sections.flatMap(\.rows).first { $0.id == id }) }
        #expect(try row().status == .recording)
        #expect(library.note(id)?.meetingTime != .unknown)
        let activeRevision = model.presentationRevision
        let activeKey = try row().renderKey
        h.capture.elapsed = 12
        _ = h.controller.tick()
        await model.settle()
        #expect(try row().duration == 12)
        #expect(try row().renderKey == activeKey)
        #expect(model.presentationRevision > activeRevision)
        screen.minimise()
        #expect(effects.last == .close)
        #expect(try row().isRecording)
        #expect(model.rename(id, to: "  Renamed while recording  "))
        #expect(h.controller.state.activeRecording?.title == "Renamed while recording")
        await model.settle()
        let renamedKey = try row().renderKey
        #expect(renamedKey != activeKey)
        await screen.enter()
        screen.finish()
        #expect(h.controller.state == .finishing(noteID: id))
        await h.controller.operations?.value
        await h.controller.settle()
        await library.settle()
        await model.settle()
        #expect(h.controller.state == .idle)
        #expect(library.note(id)?.title == "Renamed while recording")
        #expect(await h.store.note(id)?.title == "Renamed while recording")
        #expect(library.note(id)?.audio == .plain)
        #expect(await h.store.note(id)?.audio == .plain)
        #expect(try !row().isRecording)
        #expect(try row().renderKey != renamedKey)
        #expect(try row().status == .audioOnly)
        if finish == .missingModels {
            try await h.waitFor("consent navigation", advancingClock: false) { effects.last == .openNote(id, modelDownload: true) }
        } else {
            #expect(effects.last == .openNote(id, modelDownload: false))
        }
        #expect(library.note(id)?.status == (finish == .automatic ? .queued : .audioOnly))
        if finish == .automatic {
            #expect(h.handoff.handedOff == [id])
            // The queue owns the badge after handoff; its changes must publish without another note write.
            context.processing.jobs[id] = Job(noteID: id, seq: 1, kind: .transcribe, state: .queued,
                                              language: "en", enqueuedAt: h.clock.now, updatedAt: h.clock.now)
            await model.settle()
            #expect(try row().status == .queued)
            context.processing.jobs[id]?.state = .running
            await model.settle()
            #expect(try row().status == .transcribing)
            context.processing.jobs[id] = nil
            _ = await library.commit(id) { $0.status = .ready }
            await model.settle()
            #expect(try row().status == .transcribed(speakers: 0, hasWords: false))
            _ = await library.commit(id) {
                $0.transcript = [.init(text: "Hello", start: 0, end: 1, speakerID: "s1")]
            }
            await model.settle()
            #expect(try row().status == .transcribed(speakers: 1, hasWords: true))
        }
        // A later disk refresh must never resurrect the live capture's projection.
        await library.refresh()
        await model.settle()
        #expect(try row().status != .recording)
    }
}
