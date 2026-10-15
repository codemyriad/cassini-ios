import CassiniCore
import Foundation

extension JobFailure: Error {}

/// Recognizer tokens to words: `Transcript.fromTokens` and `timedWordsFromTokens` of CassiniCore (Android's 0.1.0
/// rules), with Android's failure: a token list the words cannot be built from is `TIMINGS`.
public enum TokenWords {
    /// SentencePiece pieces carry seconds, including TDT durations. No guessed alignment.
    public static func fromTokens(_ tokens: [String], timestamps: [Float], durations: [Float]) throws(JobFailure) -> Transcript {
        Transcript(try timedWordsFromTokens(tokens, timestamps: timestamps, durations: durations).map(\.word))
    }

    /// `fromTokens` words with their extension cap: the end of the word's last piece, punctuation
    /// included. Only a word with a speech-bearing piece gets one; a mark alone has no audio of its
    /// own, and its timestamp is the next onset, so a cap would walk it over the next word.
    public static func timedWordsFromTokens(_ tokens: [String], timestamps: [Float], durations: [Float]) throws(JobFailure) -> [DecodedWord] {
        do {
            return try Transcript.timedWordsFromTokens(tokens, timestamps: timestamps, durations: durations)
        } catch {
            throw .timings
        }
    }
}
