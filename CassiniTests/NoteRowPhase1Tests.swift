import SwiftUI
import UIKit
import XCTest
import CassiniNotebook
@testable import Cassini

@MainActor final class NoteRowPhase1Tests: XCTestCase {
    private func row(status: LibraryRow.Status = .transcribed(speakers: 1, hasWords: true),
                     preview: Highlighted? = nil, search: Bool = false) -> LibraryRow {
        var note = Note(title: "English planning", createdAt: Date(timeIntervalSince1970: 1_791_452_460))
        note.status = .ready; note.duration = 48
        note.transcript = [TranscriptSegment(text: "English meeting context", start: 0, end: 2, speakerID: "a")]
        var row = LibraryMapping.row(LibraryIndex([note]).entries[0], context: RowContext())
        row.status = status; row.preview = preview; row.day = search ? .today : nil
        return row
    }

    private func size<V: View>(_ view: V, width: CGFloat = 300) -> CGSize {
        let host = UIHostingController(rootView: view)
        host.loadViewIfNeeded()
        return host.sizeThatFits(in: CGSize(width: width, height: 1_000))
    }

    func testFinishedRowHasNoVisualStatusChipButStillSpeaksTranscribed() {
        let value = row()
        XCTAssertLessThan(size(RowChip(row: value)).height, 1)
        let queued = row(status: .queued)
        XCTAssertGreaterThanOrEqual(size(RowChip(row: queued)).height, 21.5)
        let format = LibraryFormat(calendar: Calendar(identifier: .gregorian))
        XCTAssertTrue(format.rowLabel(value, day: .today).contains(LibraryCopy.status(value.status).lowercased()))
        XCTAssertEqual(value.status.suffix, .speakers)
        XCTAssertEqual(LibraryPhase1Copy.speakerCount(1, language: "en"), "1 speaker")
    }

    func testActualRowHidesTheOrdinaryPreviewAndKeepsTheSearchSnippet() {
        let snippet = Highlighted("English matching context continues across the two-line search excerpt.", ranges: [8..<16])
        let ordinary = row(preview: snippet)
        let noPreview = row()
        let result = row(preview: snippet, search: true)
        let normalSize = size(NoteRow(row: ordinary, day: .today, perform: { _ in }).fixedSize(horizontal: false, vertical: true))
        let emptySize = size(NoteRow(row: noPreview, day: .today, perform: { _ in }).fixedSize(horizontal: false, vertical: true))
        let searchSize = size(NoteRow(row: result, day: .today, perform: { _ in }).fixedSize(horizontal: false, vertical: true))
        XCTAssertEqual(normalSize.height, emptySize.height, accuracy: 0.5)
        XCTAssertGreaterThan(searchSize.height, normalSize.height + 10)
        XCTAssertEqual(ordinary.preview, snippet, "The visual cut does not remove existing spoken context")
    }

    func testNeutralMetadataPillHasStandardHeightAndWrapsAtAccessibleSizes() {
        let pill = RowMetadataPill(text: Text(verbatim: LibraryPhase1Copy.speakerCount(1)), systemImage: "person.2.fill")
        let standard = size(pill.dynamicTypeSize(.large))
        XCTAssertEqual(standard.height, 22, accuracy: 0.5)
        let larger = size(pill.dynamicTypeSize(.accessibility5), width: 140)
        XCTAssertLessThanOrEqual(larger.width, 140.5)
        XCTAssertGreaterThan(larger.height, standard.height)
        let empty = RowMetadataPill(text: Text(verbatim: LibraryPhase1Copy.noSpeech))
        XCTAssertEqual(size(empty.dynamicTypeSize(.large)).height, 22, accuracy: 0.5)
    }
}
