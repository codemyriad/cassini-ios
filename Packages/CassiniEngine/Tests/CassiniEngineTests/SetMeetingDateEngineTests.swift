import Foundation
import Testing
import CassiniCore
import CassiniNotebook
import CassiniEngineTesting
@testable import CassiniEngine

@MainActor
struct SetMeetingDateEngineTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let cet = TimeZone(secondsFromGMT: 3600)!

    private func gregorian(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    @Test func settingDateMovesUndatedMeetingToItsDayAndRemovesDateUnknown() async throws {
        let now = try #require(CassiniDocument.parseInstant("2026-11-25T12:00:00Z"))
        let yesterday = try #require(CassiniDocument.parseInstant("2026-11-24T13:36:00Z"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("set-date-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = LibraryStore(root: root, reportFailure: { _ in })
        await library.load()

        var undated = Note(title: "Incontro ORA", createdAt: now)
        undated.origin = .imported
        undated.meetingTime = .unknown
        undated.duration = 2172
        try await library.insert(undated)

        var todayNote = Note(title: "Standup", createdAt: now.addingTimeInterval(-600))
        todayNote.meetingTime = .instant(now.addingTimeInterval(-600))
        try await library.insert(todayNote)

        let clock = FakeClock(now: now)
        let model = LibraryScreenModel(ports: LibraryScreenModel.Ports(
            notes: { library.notes },
            loading: { !library.isLoaded },
            unavailable: { library.loadFailure != nil },
            processing: { ProcessingState() },
            phase: { _ in nil },
            install: { nil },
            recording: { .idle },
            finishing: { nil },
            transcribe: { _, _ in .queued(changed: true) },
            startOver: { _ in .queued(changed: true) },
            stop: { _ in },
            dequeue: { _ in },
            update: { id, change in _ = library.update(id, change) },
            trash: { _ in },
            speakerModelsReady: { false },
            clock: clock,
            calendar: gregorian(cet)
        ))
        await model.settle()

        // Initially: Today has Standup, Date unknown has Incontro ORA
        let before = model.content.sections
        #expect(before.map(\.key) == [.today, .undated])
        #expect(before[1].rows.map(\.id) == [undated.id])

        // Open Set date and time dialog via menu action
        await model.perform(.setDateTime, on: undated.id)
        #expect(model.dialog == .setDateTime(undated.id))

        // Save Yesterday at 14:36 CET
        model.setDateTime(undated.id, to: yesterday, timeZone: cet)
        #expect(model.dialog == nil)
        await library.settle()
        await model.settle()

        // Now: Today has Standup, Yesterday has Incontro ORA, Date unknown is gone!
        let after = model.content.sections
        #expect(after.map(\.key) == [.today, .yesterday])
        #expect(after[1].rows.map(\.id) == [undated.id])
        #expect(library.note(undated.id)?.userStartedAt == "2026-11-24T14:36:00+01:00")

        // Search date filter ("Past 7 days") now includes the newly dated meeting
        model.beginSearch()
        model.searchDate = .week
        await model.settle()
        let hitIDs = Set((model.content.results ?? []).map(\.id))
        #expect(hitIDs.contains(undated.id))

        // Changing the date to a year ago moves it out of "Past 7 days"
        let lastYear = try #require(CassiniDocument.parseInstant("2025-05-10T09:00:00Z"))
        model.setDateTime(undated.id, to: lastYear, timeZone: cet)
        await library.settle()
        await model.settle()
        let updatedHitIDs = Set((model.content.results ?? []).map(\.id))
        #expect(!updatedHitIDs.contains(undated.id))
    }

    @Test func noteScreenModelOpensAndSavesSetDateTime() throws {
        let now = try #require(CassiniDocument.parseInstant("2026-11-25T12:00:00Z"))
        let chosen = try #require(CassiniDocument.parseInstant("2026-11-23T13:36:00Z"))
        var note = Note(title: "Imported", createdAt: now)
        note.origin = .imported
        note.meetingTime = .unknown

        let fake = FakeNoteScreen(note: note)
        let model = NoteScreenModel(noteID: note.id, ports: fake.ports)
        model.perform(.setDateTime)
        #expect(model.sheet == .setDateTime)

        model.setDateTime(to: chosen, timeZone: cet)
        #expect(model.sheet == nil)
        #expect(fake.note?.meetingTime == .instant(chosen))
        #expect(fake.note?.userStartedAt == "2026-11-23T14:36:00+01:00")
    }

    @Test func coordinatedImporterCapturesSourceModificationDate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appendingPathComponent("gadget.wav")
        let dst = dir.appendingPathComponent("copy.tmp")
        // Minimal valid WAV header (44 bytes)
        var wav = Data("RIFF".utf8)
        wav.append(contentsOf: [36, 0, 0, 0])
        wav.append(Data("WAVEfmt ".utf8))
        wav.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3E, 0, 0, 0, 0x7D, 0, 0, 2, 0, 16, 0])
        wav.append(Data("data".utf8))
        wav.append(contentsOf: [0, 0, 0, 0])
        try wav.write(to: src)

        let expectedMod = try #require(CassiniDocument.parseInstant("2026-11-23T14:12:00Z"))
        try FileManager.default.setAttributes([.modificationDate: expectedMod], ofItemAtPath: src.path)

        let importer = CoordinatedFileImporter(storage: FakeStorage(availableBytes: 100 * 1024 * 1024))
        let copied = try await importer.copy(from: src, to: dst, maxBytes: 10 * 1024 * 1024, reserveBytes: 1024)
        #expect(copied.modifiedAt == expectedMod)
    }
}
