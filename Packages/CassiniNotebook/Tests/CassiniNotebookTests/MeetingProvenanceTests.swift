import Foundation
import Testing
@testable import CassiniNotebook

struct MeetingProvenanceTests {
    private func note(_ origin: NoteOrigin) -> Note {
        var note = Note(title: "Imported planning", createdAt: Date(timeIntervalSince1970: 1_799_000_000))
        note.origin = origin
        note.status = .ready
        note.transcript = [TranscriptSegment(text: "Planning together", start: 0, end: 2)]
        return note
    }

    private func text(_ language: String = "en") throws -> StatusBadges.Text {
        let root = try #require(Bundle.module.url(forResource: "status-badges", withExtension: nil))
        let data = try Data(contentsOf: root.appendingPathComponent("strings/strings.json"))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(catalog["entries"] as? [[String: Any]])
        let labels = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, String)? in
            guard let id = entry["id"] as? String else { return nil }
            let translated = (entry["l10n"] as? [String: [String: Any]])?[language]?["text"] as? String
            guard let value = language == "en" ? entry["en"] as? String : translated else { return nil }
            return (id, value)
        })
        return { labels[$0]! }
    }

    @Test func persistedOriginsDeriveInLibraryAndSearchWithoutRewritingNotes() throws {
        for origin in NoteOrigin.allCases {
            let original = note(origin)
            let bytes = try JSONEncoder().encode(original)
            let restored = try JSONDecoder().decode(Note.self, from: bytes)
            let expected: MeetingProvenance = switch origin {
            case .recorded, .recovered: .own
            case .imported: .imported
            case .importedDocument: .importedOtherDevice
            }
            #expect(MeetingProvenance.of(restored) == expected)
            let index = LibraryIndex([restored])
            let library = LibraryMapping.row(index.entries[0], context: RowContext())
            let search = LibraryMapping.row(index.entries[0], context: RowContext(), hit: .init(day: .today))
            for row in [library, search] {
                #expect(row.provenance == expected)
                let badge = RowBadge.presentation(row, text: try text())
                if expected == .own { #expect(badge == nil) }
                else { #expect(badge == BadgePresentation(kind: .received, text: "Imported", tint: .outline, glyph: .incoming)) }
            }
        }
    }

    @Test func everyProgressAndProblemStateReplacesImported() throws {
        for origin in [NoteOrigin.imported, .importedDocument] {
            var row = LibraryMapping.row(LibraryIndex([note(origin)]).entries[0], context: RowContext())
            for state in [LibraryRow.Status.audioOnly, .queued, .paused(atMs: 1200), .failed,
                          .unplayable, .unreadable, .newerFormat, .transcribing, .recording] {
                row.status = state
                #expect(RowBadge.presentation(row, text: try text())?.kind != .received)
            }
            for state in [LibraryRow.Status.transcribed(speakers: 0, hasWords: false), .transcribed(speakers: 3, hasWords: true)] {
                row.status = state
                #expect(RowBadge.presentation(row, text: try text())?.kind == .received)
            }
        }
    }

    @Test func otherDeviceNeedsAnImportedTranscriptAndSurvivesLocalChanges() {
        var imported = note(.importedDocument)
        imported.transcript = []
        #expect(MeetingProvenance.of(imported) == .imported)
        imported.versions = [TranscriptVersion(kind: .transcription, segments: [], speakers: [])]
        #expect(MeetingProvenance.of(imported) == .imported)
        // Empty completed transcripts also carry provenance; the currently selected version is irrelevant.
        imported.versions?.append(TranscriptVersion(kind: .imported, segments: [], speakers: []))
        imported.selectedVersionID = imported.versions?.first?.id
        #expect(MeetingProvenance.of(imported) == .importedOtherDevice)
        imported.origin = .imported
        #expect(MeetingProvenance.of(imported) == .imported, "Locally transcribed audio must not claim another device")
    }

    @Test func legacyImportEvidenceIsUsedByExistingDecoder() throws {
        var legacy = note(.imported)
        legacy.originalAudioFilename = "interview.wav"
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(forKey: "origin")
        let decoded = try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(MeetingProvenance.of(decoded) == .imported)
    }

    @Test func allCatalogLanguagesAndMeetingTimeShapesKeepProvenanceWithoutInventedDates() throws {
        for language in ["en", "it", "fr", "es", "pt-BR", "pt-PT"] {
            let text = try text(language)
            for origin in [NoteOrigin.imported, .importedDocument] {
                for time in [MeetingTime.instant(Date()), .local("2026-11-14 09:41"), .unknown] {
                    var imported = note(origin)
                    imported.meetingTime = time
                    let subtitle = try #require(NoteSubtitle.of(imported, mode: .reading, now: Date(), calendar: .current))
                    let key = try #require(subtitle.provenance.subtitleKey)
                    let formatted = subtitle.importedText(template: text(key), day: "Today", time: "09:41", duration: "2:03")
                    #expect(formatted.contains(text("states.badge.received")))
                    #expect(formatted.contains("2:03"))
                    #expect(!formatted.contains("{"))
                    switch time {
                    case .instant: #expect(formatted.hasPrefix("Today, 09:41 · 2:03"))
                    case .local: #expect(formatted.hasPrefix("2026-11-14 09:41 · 2:03"))
                    case .unknown: #expect(formatted.hasPrefix("2:03 · "))
                    }
                }
            }
        }
    }
}
