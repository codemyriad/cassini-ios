import Foundation

extension NoteTranscript {
    private static let quoteWords = 40
    private static let quoteChars = 240

    /// A bounded excerpt of `speakerID`'s first contiguous speech in the displayed transcript, without other speakers
    /// or synthetic overlap labels. Stops at 40 words or 240 UTF-16 units without splitting a grapheme cluster or
    /// UTF-16 surrogate pair.
    public func namingQuote(_ speakerID: String) -> String {
        let target = Data(speakerID.utf8)
        guard !target.isEmpty else { return "" }
        var started = false
        var ended = false
        var hasMoreInRun = false
        var result = ""
        var utf16Count = 0
        var wordCount = 0
        var truncated = false

        outer: for turn in turns {
            let turnKey = turn.speakerID.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            for word in turn.words {
                let wordKey = word.speakerID.flatMap { $0.isEmpty ? nil : Data($0.utf8) } ?? turnKey
                let matches = wordKey == target
                if !started {
                    guard matches else { continue }
                    started = true
                } else if !matches {
                    ended = true
                    break outer
                }
                let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { continue }
                if truncated || wordCount >= Self.quoteWords {
                    hasMoreInRun = true
                    break outer
                }
                let separator = (!result.isEmpty && !TurnModel.Pattern.attachesToPrevious.matches(token)) ? 1 : 0
                let room = Self.quoteChars - utf16Count - separator
                if room <= 0 {
                    truncated = true
                    break outer
                }
                let tokenUTF16 = token.utf16.count
                if tokenUTF16 <= room {
                    if separator == 1 {
                        result.append(" ")
                        utf16Count += 1
                    }
                    result.append(token)
                    utf16Count += tokenUTF16
                    wordCount += 1
                } else {
                    var prefix = ""
                    var prefixUTF16 = 0
                    for character in token {
                        let units = character.utf16.count
                        if prefixUTF16 + units > room { break }
                        prefix.append(character)
                        prefixUTF16 += units
                    }
                    if !prefix.isEmpty {
                        if separator == 1 {
                            result.append(" ")
                            utf16Count += 1
                        }
                        result.append(prefix)
                        utf16Count += prefixUTF16
                        wordCount += 1
                    }
                    truncated = true
                    break outer
                }
            }
        }
        _ = ended
        if truncated || hasMoreInRun {
            result.append("…")
        }
        return result
    }
}
