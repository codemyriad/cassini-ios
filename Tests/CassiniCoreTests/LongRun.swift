@testable import CassiniCore

/**
 * The words of a synthetic long transcription, shaped like a real job's: a diarization speaker id, about
 * [wordsPerHour] words an hour, a new speaker each 23 words, and real word lengths in Italian and English.
 */
struct LongRun {
    static let hourMs: Int64 = 3_600_000
    static let prefix = "diar_0f8e2c3a_6b7d_4e1f_9a2b_3c4d5e6f7a8b_"
    static let speakers = 4
    static let turnWords = 23
    static let text = ("Allora, partiamo dal punto principale della riunione di oggi. The quarterly numbers look better than " +
        "expected, ma dobbiamo ancora verificare le consegne di giovedì e il budget del progetto. " +
        "Can everyone confirm their availability for next week? Perfetto, grazie mille a tutti.").split(separator: " ").map(String.init)

    var wordsPerHour = 9_500

    /** The words that end at or before [endMs], in time order. */
    func words(_ endMs: Int64) -> [Word] {
        let gap = Self.hourMs / Int64(wordsPerHour)
        return (0..<Int(endMs / gap)).map { i -> Word in
            let start = Int64(i) * gap
            return Word("\(Self.prefix)\(1 + (i / Self.turnWords) % Self.speakers)", start, start + gap * 4 / 5, Self.text[i % Self.text.count])
        }.filter { $0.endMs <= endMs }
    }
}
