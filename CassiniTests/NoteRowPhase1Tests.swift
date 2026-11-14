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

    func testVoiceOverAgreesWithVisiblePillsInAllSixLocales() throws {
        let statuses: [LibraryRow.Status] = [.recording, .transcribing, .queued, .paused(atMs: 768_000),
            .failed, .unplayable, .unreadable, .newerFormat, .audioOnly,
            .transcribed(speakers: 1, hasWords: true), .transcribed(speakers: 0, hasWords: false)]
        for language in ["en", "it", "fr", "es", "pt-BR", "pt-PT"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: language)
            let format = LibraryFormat(calendar: calendar)
            for status in statuses {
                var value = row(status: status)
                value.duration = 768
                let label = format.rowLabel(value, day: .today)
                let visible: String
                if case .transcribed = status {
                    visible = LibraryPhase1Copy.template("phone.row.transcribed.a11y", language: language)
                } else {
                    visible = RowBadge.presentation(value, text: { StatusBadgeCopy.template($0, language: language) })?.text
                        ?? PhoneStatusBadgeView(status: status).text(language: language)
                }
                XCTAssertTrue(label.contains(visible.lowercased(with: format.locale)), "\(language): \(label) / \(visible)")
                if case .recording = status { XCTAssertTrue(label.contains("12:48"), language) }
                if case .transcribing = status {
                    // Current local jobs expose an interval, so the visible pill uses the shared no-ETA fallback.
                    // Speak that exact badge, including its ellipsis, rather than the legacy bare status.
                    XCTAssertEqual(visible, StatusBadgeCopy.template("states.badge.transcribing.noEta", language: language))
                }
                if case .transcribed(let count, let hasWords) = status {
                    let pill = hasWords ? LibraryPhase1Copy.speakerCount(count, language: language)
                        : LibraryPhase1Copy.template("phone.row.noSpeech", language: language)
                    XCTAssertTrue(label.contains(pill.lowercased(with: format.locale)), "\(language): \(label) / \(pill)")
                }
            }
        }
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
