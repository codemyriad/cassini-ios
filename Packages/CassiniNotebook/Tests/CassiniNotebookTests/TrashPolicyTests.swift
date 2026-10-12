import Foundation
import Testing
@testable import CassiniNotebook

/// `TrashPolicy` and the Recently Deleted cards, in Rome's time zone as Android's tests.
struct TrashPolicyTests {
    private let rome: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }()

    /// A local time in Rome, "2026-10-09T15:00" or with seconds.
    private func at(_ text: String) -> Date {
        let parts = text.split(whereSeparator: { "-T:".contains($0) }).map { Int($0)! }
        return rome.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3],
                                              minute: parts[4], second: parts.count > 5 ? parts[5] : 0))!
    }

    private func daysLeft(_ deleted: String, _ now: String) -> Int {
        TrashPolicy.daysLeft(since: at(deleted), now: at(now), calendar: rome)
    }

    private func expired(_ deleted: String, _ now: String) -> Bool {
        TrashPolicy.isExpired(since: at(deleted), now: at(now), calendar: rome)
    }

    // ports: TrashPolicyTest#board09
    @Test func aNoteDeletedOnTheSecondHas23DaysLeftOnTheNinth() {
        #expect(daysLeft("2026-10-02T18:20", "2026-10-09T15:00") == 23)
        #expect(TrashDay(at("2026-10-02T18:20"), now: at("2026-10-09T15:00"), calendar: rome)
                == .date(at("2026-10-02T00:00"), withYear: false))
    }

    // ports: TrashPolicyTest#sameDayAndYesterday
    @Test func sameDayAndYesterday() {
        #expect(daysLeft("2026-10-09T00:00", "2026-10-09T23:59") == 30)
        #expect(daysLeft("2026-10-08T23:59", "2026-10-09T00:00") == 29)
        #expect(!expired("2026-10-09T00:00", "2026-10-09T23:59"))
    }

    // ports: TrashPolicyTest#day30IsExpired
    @Test func day30IsExpired() {
        #expect(daysLeft("2026-10-02T23:59", "2026-10-31T23:59") == 1)
        #expect(!expired("2026-10-02T23:59", "2026-10-31T23:59"))
        #expect(daysLeft("2026-10-02T23:59", "2026-11-01T00:00") == 0)
        #expect(expired("2026-10-02T23:59", "2026-11-01T00:00"))
        #expect(daysLeft("2026-10-02T00:00", "2027-01-01T00:00") == 0)
    }

    // ports: TrashPolicyTest#calendarDaysAcrossDst
    @Test func calendarDaysAcrossDst() {
        // 29 Mar 2026 has 23 hours: 22.5 hours later is already the next day.
        #expect(daysLeft("2026-03-28T23:30", "2026-03-29T23:00") == 29)
        // 25 Oct 2026 has 25 hours: 48 h 40 min later is still only the next day.
        #expect(daysLeft("2026-10-24T00:10", "2026-10-25T23:50") == 29)
        // Deleted in summer time, expired at local midnight in winter time.
        #expect(!expired("2026-10-02T12:00", "2026-10-31T23:59:59"))
        #expect(expired("2026-10-02T12:00", "2026-11-01T00:00"))
    }

    // ports: TrashPolicyTest#aClockSetBackAddsNoDays
    @Test func aClockSetBackAddsNoDays() {
        #expect(daysLeft("2026-10-12T10:00", "2026-10-09T10:00") == 30)
    }

    // ports: TrashPolicyTest#purgeCutoffMatchesIsExpired
    @Test func purgeCutoffMatchesIsExpired() {
        let moments = ["2026-11-01T12:00", "2026-11-01T00:00", "2026-03-29T03:30", "2026-10-25T02:30", "2027-01-01T00:00"]
        for text in moments {
            let now = at(text)
            let cutoff = TrashPolicy.purgeCutoff(now: now, calendar: rome)
            let probes = (-3...3).flatMap { offset in
                [cutoff.addingTimeInterval(Double(offset) / 1000), cutoff.addingTimeInterval(Double(offset) * 3600)]
            } + (0...40).map { now.addingTimeInterval(-Double($0) * 86_400) }
            for deleted in probes {
                #expect(TrashPolicy.isExpired(since: deleted, now: now, calendar: rome) == (deleted < cutoff),
                        "\(text) \(deleted)")
            }
        }
        // On 1 Nov the notes deleted up to the end of 2 Oct expire.
        #expect(TrashPolicy.purgeCutoff(now: at("2026-11-01T12:00"), calendar: rome) == at("2026-10-03T00:00"))
    }

    @Test func theUndoSnackbarWaitsLongerWhileVoiceOverRuns() {
        #expect(TrashPolicy.undoDuration(voiceOverRunning: false) == .seconds(10))
        #expect(TrashPolicy.undoDuration(voiceOverRunning: true) == .seconds(30))
    }

    // ports: TrashViewModelTest#purgesOnOpenThenShowsTheCardsOldestDeletionFirstWithTheDaysLeft (the cards)
    @Test func theCardsAreOldestDeletionFirstWithTheirDayAndDaysLeft() {
        let now = at("2026-10-09T12:00")
        func note(_ title: String, deleted: String?, duration: TimeInterval = 0) -> Note {
            var note = Note(title: title)
            note.duration = duration
            note.trashedAt = deleted.map(at)
            return note
        }
        let today = note("Today's", deleted: "2026-10-09T01:00", duration: 0.005)
        let old = note("Test recording", deleted: "2026-10-02T18:00", duration: 60)
        let yesterday = note("Standup", deleted: "2026-10-08T23:00")
        let lastYear = note("Last winter", deleted: "2025-12-30T10:00")
        let items = TrashLabels.items([today, note("Live", deleted: nil), old, yesterday, lastYear], now: now, calendar: rome)
        #expect(items.map(\.title) == ["Last winter", "Test recording", "Standup", "Today's"])
        #expect(items.map(\.deletedOn) == [.date(at("2025-12-30T00:00"), withYear: true),
                                          .date(at("2026-10-02T00:00"), withYear: false), .yesterday, .today])
        #expect(items.map(\.daysLeft) == [0, 23, 29, 30])
        #expect(items[1].duration == 60)
    }

    @Test func notesDeletedAtTheSameMomentAreOrderedById() {
        let deleted = at("2026-10-02T18:00")
        var first = Note(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "First")
        var second = Note(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Second")
        first.trashedAt = deleted; second.trashedAt = deleted
        #expect(TrashLabels.items([second, first], now: deleted, calendar: rome).map(\.title) == ["First", "Second"])
    }
}
