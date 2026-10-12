import Foundation
import Testing
import CassiniNotebook

@Suite struct NoteTitlesTests {
    // ports: NoteRepositoryTest#invalidTitlesAreRefused
    @Test func invalidTitlesAreRefused() {
        #expect(NoteTitles.clean("   ") == nil)
        #expect(NoteTitles.clean(String(repeating: "x", count: NoteTitles.maxLength + 1)) == nil)
        #expect(NoteTitles.clean(" " + String(repeating: "x", count: NoteTitles.maxLength) + "\n") == String(repeating: "x", count: NoteTitles.maxLength))
    }

    @Test func fittedTitlesAreCutAndTrimmed() {
        #expect(NoteTitles.fit(nil) == nil)
        #expect(NoteTitles.fit(" \n ") == nil)
        #expect(NoteTitles.fit("  Meeting  ") == "Meeting")
        #expect(NoteTitles.fit(String(repeating: "y", count: 250))?.count == NoteTitles.maxLength)
        #expect(NoteTitles.fit(String(repeating: "z", count: 199) + " tail") == String(repeating: "z", count: 199))
    }

    @Test func theRecordingDefaultIsLocaleStable() {
        let date = Date(timeIntervalSince1970: 1_791_366_060)
        let title = NoteTitles.recordingDefault(at: date, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(title.hasPrefix("Recording · "))
        #expect(title.contains("2026"))
    }
}
