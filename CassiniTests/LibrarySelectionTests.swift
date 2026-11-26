import XCTest
import CoreGraphics
import Foundation
import CassiniCore
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import Cassini

/// Regression tests proving Library bulk selection (Select All and two-finger swipe) derives candidates
/// from the current filtered content, reconciles when filters change, discards obsolete row frames,
/// and cannot export or delete hidden notes.
@MainActor final class LibrarySelectionTests: XCTestCase {
    private let wav = Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVEfmt ".utf8) + [UInt8](repeating: 1, count: 100))

    private func seedNote(
        in harness: TestGraph,
        title: String,
        text: String,
        favorite: Bool = false,
        offset: TimeInterval = 0
    ) async throws -> Note {
        let store = try XCTUnwrap(harness.graph.library.noteStore)
        var note = Note(title: title, createdAt: harness.clock.now.addingTimeInterval(offset), audioFilename: "source.wav")
        note.transcript = [.init(text: text, start: 0, end: 2)]
        note.language = "en"
        note.status = .ready
        note.isFavorite = favorite
        try await store.save(note)
        try wav.write(to: store.audioURL(for: note))
        harness.graph.library.adopt(note)
        return note
    }

    func testStarredFilterSelectAllCannotExportOrDeleteUnstarredNotes() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        await harness.graph.start()

        let starred = try await seedNote(in: harness, title: "Starred review", text: "keep me starred", favorite: true, offset: -60)
        let unstarred = try await seedNote(in: harness, title: "Unstarred sync", text: "ordinary sync", favorite: false, offset: -120)

        let model = harness.graph.libraryScreen
        model.favoritesOnly = true
        await model.settle()

        let selectableIDs = LibrarySelection.selectableIDs(from: model.listContent, notes: harness.graph.library.notes)
        XCTAssertEqual(selectableIDs, [starred.id])

        let selected = LibrarySelection.selectAll([], selectableIDs: selectableIDs)
        XCTAssertEqual(selected, [starred.id])

        let exportable = LibrarySelection.exportableIDs(selected: selected, selectableIDs: selectableIDs, notes: harness.graph.library.notes)
        XCTAssertEqual(exportable, [starred.id])
        let archiveURL = try await harness.graph.exports.exportArchive(exportable, progress: { _ in })
        let zip = try ZIPArchive(url: archiveURL)
        XCTAssertEqual(zip.entries.map(\.name), ["Starred review.opus"])

        let deletable = LibrarySelection.deletableIDs(selected: selected, selectableIDs: selectableIDs, notes: harness.graph.library.notes)
        XCTAssertEqual(deletable, [starred.id])
        for id in deletable {
            await model.perform(.moveToTrash, on: id)
        }

        XCTAssertNotNil(harness.graph.library.note(starred.id)?.trashedAt)
        XCTAssertNil(harness.graph.library.note(unstarred.id)?.trashedAt, "Unstarred note hidden by Starred filter must not be trashed")
    }

    func testSearchFilterSelectAllCannotExportOrDeleteNonMatchingNotes() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        await harness.graph.start()

        let matching = try await seedNote(in: harness, title: "Quarterly budget", text: "budget discussion", offset: -60)
        let hidden = try await seedNote(in: harness, title: "Design critique", text: "typography review", offset: -120)

        let model = harness.graph.libraryScreen
        model.beginSearch()
        model.query = "budget"
        await model.settle()

        let selectableIDs = LibrarySelection.selectableIDs(from: model.listContent, notes: harness.graph.library.notes)
        XCTAssertEqual(selectableIDs, [matching.id])

        let selected = LibrarySelection.selectAll([], selectableIDs: selectableIDs)
        let exportable = LibrarySelection.exportableIDs(selected: selected, selectableIDs: selectableIDs, notes: harness.graph.library.notes)
        XCTAssertEqual(exportable, [matching.id])
        let archiveURL = try await harness.graph.exports.exportArchive(exportable, progress: { _ in })
        let zip = try ZIPArchive(url: archiveURL)
        XCTAssertEqual(zip.entries.map(\.name), ["Quarterly budget.opus"])

        let deletable = LibrarySelection.deletableIDs(selected: selected, selectableIDs: selectableIDs, notes: harness.graph.library.notes)
        XCTAssertEqual(deletable, [matching.id])
        for id in deletable {
            await model.perform(.moveToTrash, on: id)
        }

        XCTAssertNotNil(harness.graph.library.note(matching.id)?.trashedAt)
        XCTAssertNil(harness.graph.library.note(hidden.id)?.trashedAt, "Non-matching note hidden by Search must not be trashed")
    }

    func testSelectionReconcilesAndBlocksHiddenTargetsWhenFiltersChange() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        await harness.graph.start()

        let starred = try await seedNote(in: harness, title: "Starred meeting", text: "alpha", favorite: true, offset: -60)
        let unstarred = try await seedNote(in: harness, title: "Plain meeting", text: "beta", favorite: false, offset: -120)

        let model = harness.graph.libraryScreen
        await model.settle()

        let allSelectableIDs = LibrarySelection.selectableIDs(from: model.listContent, notes: harness.graph.library.notes)
        let selectedBeforeFilter = LibrarySelection.selectAll([], selectableIDs: allSelectableIDs)
        XCTAssertEqual(selectedBeforeFilter, [starred.id, unstarred.id])

        model.favoritesOnly = true
        await model.settle()

        let filteredSelectableIDs = LibrarySelection.selectableIDs(from: model.listContent, notes: harness.graph.library.notes)
        let filteredSelectable = Set(filteredSelectableIDs)
        XCTAssertEqual(filteredSelectable, [starred.id])

        let reconciled = LibrarySelection.reconcile(selectedBeforeFilter, selectable: filteredSelectable)
        XCTAssertEqual(reconciled, [starred.id])

        // Even before state reconciliation settles, export/delete helpers reject IDs outside selectableIDs.
        XCTAssertEqual(
            LibrarySelection.exportableIDs(selected: selectedBeforeFilter, selectableIDs: filteredSelectableIDs, notes: harness.graph.library.notes),
            [starred.id]
        )
        XCTAssertEqual(
            LibrarySelection.deletableIDs(selected: selectedBeforeFilter, selectableIDs: filteredSelectableIDs, notes: harness.graph.library.notes),
            [starred.id]
        )
    }

    func testTwoFingerSelectionDiscardsObsoleteFramesAndCannotSelectExportOrDeleteHiddenNotes() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        await harness.graph.start()

        let visibleNote = try await seedNote(in: harness, title: "Visible starred", text: "visible", favorite: true, offset: -60)
        let hiddenNote = try await seedNote(in: harness, title: "Hidden unstarred", text: "hidden", favorite: false, offset: -120)

        let visibleRect = CGRect(x: 0, y: 0, width: 320, height: 80)
        let hiddenFormerRect = CGRect(x: 0, y: 100, width: 320, height: 80)
        let cachedFramesBeforeFilter: [UUID: CGRect] = [
            visibleNote.id: visibleRect,
            hiddenNote.id: hiddenFormerRect
        ]

        let model = harness.graph.libraryScreen
        model.favoritesOnly = true
        await model.settle()

        let selectableIDs = LibrarySelection.selectableIDs(from: model.listContent, notes: harness.graph.library.notes)
        let selectable = Set(selectableIDs)
        XCTAssertEqual(selectable, [visibleNote.id])

        // Pruning drops the hidden note's obsolete cached frame.
        let prunedFrames = LibrarySelection.pruneFrames(cachedFramesBeforeFilter, selectable: selectable)
        XCTAssertEqual(prunedFrames, [visibleNote.id: visibleRect])
        XCTAssertNil(prunedFrames[hiddenNote.id])

        // Even if stale frames still contain the hidden row's former rect, two-finger hit-testing ignores it.
        var touched: Set<UUID> = []
        let overlay = TwoFingerSelectOverlay(
            frames: cachedFramesBeforeFilter,
            selectable: selectable,
            onBegin: {},
            onTouchRow: { id in touched.insert(id) }
        )
        let coordinator = overlay.makeCoordinator()
        coordinator.hit(at: CGPoint(x: 160, y: 140)) // former position of hiddenNote
        XCTAssertTrue(touched.isEmpty, "Two-finger swipe over a hidden note's former frame must not select it")

        coordinator.hit(at: CGPoint(x: 160, y: 40)) // position of visibleNote
        XCTAssertEqual(touched, [visibleNote.id])

        // Export and delete from that two-finger selection only touch the visible note.
        let exportable = LibrarySelection.exportableIDs(selected: touched, selectableIDs: selectableIDs, notes: harness.graph.library.notes)
        XCTAssertEqual(exportable, [visibleNote.id])
        let deletable = LibrarySelection.deletableIDs(selected: touched, selectableIDs: selectableIDs, notes: harness.graph.library.notes)
        XCTAssertEqual(deletable, [visibleNote.id])
        for id in deletable {
            await model.perform(.moveToTrash, on: id)
        }
        XCTAssertNotNil(harness.graph.library.note(visibleNote.id)?.trashedAt)
        XCTAssertNil(harness.graph.library.note(hiddenNote.id)?.trashedAt)
    }

    func testLiveRecordingIsExcludedFromSelectableIDs() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        await harness.graph.start()

        let normal = try await seedNote(in: harness, title: "Finished meeting", text: "done", offset: -60)
        var live = Note(title: "Live meeting", createdAt: harness.clock.now)
        live.audio = .live
        let store = try XCTUnwrap(harness.graph.library.noteStore)
        try await store.save(live)
        harness.graph.library.adopt(live)

        let model = harness.graph.libraryScreen
        await model.settle()

        let selectableIDs = LibrarySelection.selectableIDs(from: model.listContent, notes: harness.graph.library.notes)
        XCTAssertEqual(selectableIDs, [normal.id])
        XCTAssertFalse(selectableIDs.contains(live.id))
    }
}
