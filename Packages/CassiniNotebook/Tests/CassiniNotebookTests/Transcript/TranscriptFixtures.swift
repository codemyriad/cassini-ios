import Foundation
@testable import CassiniNotebook

/// Notes built from words given in milliseconds, as Android's `NoteTranscriptsTest` writes them.
enum TranscriptFixtures {
    struct W {
        var speaker: String?
        var startMs: Int
        var endMs: Int
        var text: String
        init(_ speaker: String?, _ startMs: Int, _ endMs: Int, _ text: String) {
            self.speaker = speaker; self.startMs = startMs; self.endMs = endMs; self.text = text
        }
    }

    /// One passage per run of words with the same speaker, its words timed.
    static func note(_ words: [W], speakers: [NoteSpeaker] = []) -> Note {
        var note = Note(title: "Weekly sync", createdAt: Date(timeIntervalSince1970: 1_791_500_000))
        note.duration = Double(words.map(\.endMs).max() ?? 0) / 1000
        var from = 0
        while from < words.count {
            var to = from + 1
            while to < words.count, words[to].speaker.map({ Data($0.utf8) }) == words[from].speaker.map({ Data($0.utf8) }) { to += 1 }
            let run = words[from..<to]
            let timed = run.map { TimedWord(text: $0.text, start: Double($0.startMs) / 1000, end: Double($0.endMs) / 1000) }
            note.transcript.append(TranscriptSegment(text: run.map(\.text).joined(separator: " "),
                                                     start: timed.first!.start, end: timed.last!.end,
                                                     speaker: speakers.first { $0.byteID == run.first!.speaker.map({ Data($0.utf8) }) }?.name,
                                                     speakerID: run.first!.speaker, words: timed))
            from = to
        }
        note.speakers = speakers.isEmpty ? nil : speakers
        note.status = .ready
        return note
    }

    /// Android's six words of three speakers: Giulia, the placeholder "Speaker 2", Paolo Ferri, then Giulia again.
    static let words: [W] = [
        W("a", 0, 400, "Hello"),
        W("a", 500, 900, "everyone."),
        W("b", 1_000, 1_400, "Welcome"),
        W("c", 2_000, 2_300, "Here"),
        W("a", 3_000, 3_500, "Good,"),
        W("a", 3_500, 3_900, "so"),
    ]

    static let speakers = [
        NoteSpeaker(id: "a", name: "Giulia"),
        NoteSpeaker(id: "b", name: "Speaker 2"),
        NoteSpeaker(id: "c", name: "Paolo Ferri"),
    ]

    static var weeklySync: Note { note(words, speakers: speakers) }

    static func voice(_ name: String) -> SavedVoice { SavedVoice(name: name, samples: []) }

    static func s(_ ms: Int) -> TimeInterval { Double(ms) / 1000 }
}
