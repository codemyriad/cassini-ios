import Foundation

extension TurnModel {
    // portable.ts: groupTranscriptSegmentsAsReadable, then mergeSmallReadableSegments.
    static func readableBlocks(_ input: [Word]) -> [Block] {
        var grouped: [Block] = []
        var current: Block?
        for (index, rawWord) in input.enumerated() {
            var word = rawWord
            word.startMs = rawWord.startMs.isFinite ? rawWord.startMs.rounded(.towardZero) : 0
            word.endMs = rawWord.endMs.isFinite ? rawWord.endMs.rounded(.towardZero) : word.startMs
            if word.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { word.speaker = nil }
            let item = TimedWord(index: index, word: word)
            if var block = current {
                let gap = max(0, word.startMs - block.endMs)
                let duration = max(0, word.endMs - block.startMs)
                let targetReached = block.words.count >= 96 || block.endMs - block.startMs >= 45_000
                let boundary = Pattern.sentenceEnd.matches(block.text.trimmingCharacters(in: .whitespacesAndNewlines)) || gap >= 2200
                if block.speaker != word.speaker || gap > 4200 || duration > 90_000 || block.words.count + 1 > 140 || (targetReached && boundary) {
                    grouped.append(block)
                    current = Block(id: index, speaker: word.speaker, startMs: word.startMs,
                                    endMs: word.endMs, text: word.text, words: [item])
                } else {
                    // The text of every word joined, extended by the new word rather than joined again from the
                    // first word: the same text, without a rejoin per word (quadratic in the block's words). A block
                    // of one word still holds that word as given, untrimmed.
                    if block.words.count == 1 { block.text = joinedText([block.text]) }
                    block.words.append(item)
                    block.endMs = word.endMs
                    appendJoined(word.text, to: &block.text)
                    current = block
                }
            } else {
                current = Block(id: index, speaker: word.speaker, startMs: word.startMs,
                                endMs: word.endMs, text: word.text, words: [item])
            }
        }
        if let current { grouped.append(current) }

        var merged: [Block] = []
        for block in grouped {
            guard var previous = merged.last else { merged.append(block); continue }
            let previousCount = textWordCount(previous.text)
            let currentCount = textWordCount(block.text)
            let small = previousCount < 18 || currentCount < 18 || max(0, previous.endMs - previous.startMs) < 8000 || max(0, block.endMs - block.startMs) < 8000
            if previous.speaker == block.speaker,
               max(0, block.startMs - previous.endMs) <= 4200,
               previousCount + currentCount <= 140,
               max(0, block.endMs - previous.startMs) <= 90_000, small {
                previous.endMs = block.endMs
                previous.text = joinedText([previous.text, block.text])
                previous.words += block.words
                merged[merged.count - 1] = previous
            } else {
                merged.append(block)
            }
        }
        return merged
    }

    static func joinedText(_ parts: [String]) -> String {
        var result = ""
        for part in parts { appendJoined(part, to: &result) }
        return result
    }

    /// Extends `joined`, the `joinedText` of some parts, to the `joinedText` of those parts and `part`.
    static func appendJoined(_ part: String, to joined: inout String) {
        let part = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !part.isEmpty else { return }
        if !joined.isEmpty && !Pattern.attachesToPrevious.matches(part) { joined += " " }
        joined += part
    }

    static func textWordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// A regular expression compiled once. `String.range(of:options: .regularExpression)` took about 2.3 µs a call on
    /// iOS 18.2 (0.7 µs on iOS 27; Debug builds in the simulator), against 0.6 µs for a compiled one. The expressions
    /// are the same, but a compiled one matches code point by code point, as portable.ts's JavaScript does, where
    /// that search on macOS 27 matched whole characters: punctuation followed by a combining mark (",\u{301}") now
    /// attaches to the previous word, and a word piece made of combining marks and letters (Thai "\u{E49}\u{E33}")
    /// now counts as word-like. The model gives the patterns anchored at the end trimmed text only: a compiled `$`
    /// also matches before a final line break, where that search did not.
    struct Pattern: @unchecked Sendable { // NSRegularExpression is immutable and safe to share between threads.
        let regex: NSRegularExpression

        init(_ pattern: String) {
            do { regex = try NSRegularExpression(pattern: pattern) } catch { preconditionFailure("\(pattern): \(error)") }
        }

        func matches(_ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        /// A paragraph may end after this text.
        static let sentenceEnd = Pattern(#"[.!?]["')\]]*$"#)
        /// A word that follows the previous one without a space.
        static let attachesToPrevious = Pattern(#"^[,.;:!?)]"#)
        static let wordLike = Pattern(#"[\p{L}\p{N}]"#)
        /// A punctuated word whose end timing may be inflated.
        static let punctuationTail = Pattern(#"[.?!,;:…。．！？；：，、।॥؛؟][)\]}"'’”»›」』〉》]*$"#)
    }

    static func isWordLike(_ text: String) -> Bool { Pattern.wordLike.matches(text) }

    struct Candidate {
        var indices: [Int]
        var start: Double
        var end: Double
    }

    static func candidates(_ words: [TimedWord]) -> [Candidate] {
        var result: [Candidate] = []
        var index = 0
        while index < words.count {
            guard isWordLike(words[index].word.text) else { index += 1; continue }
            var end = index + 1
            while end < words.count && !isWordLike(words[end].word.text) { end += 1 }
            let text = words[index..<end].map { $0.word.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if Pattern.punctuationTail.matches(text) {
                let timed = (index..<end).filter {
                    let word = words[$0].word
                    return word.startMs.isFinite && word.endMs.isFinite && word.endMs >= word.startMs
                }
                if let start = timed.map({ words[$0].word.startMs }).min(), let finish = timed.map({ words[$0].word.endMs }).max() {
                    result.append(Candidate(indices: timed, start: start, end: finish))
                }
            }
            index = end
        }
        return result
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    // overlap.ts: repairTurnFinalWordInflation, on already grouped RAW blocks.
    // Display tokens in this words-only projection derive from these canonical words;
    // bounding them by their sources leaves this same union of audible intervals.
    static func repairTiming(_ blocks: [Block]) -> [Block] {
        var durations: [String: [Double]] = [:]
        var all: [Double] = []
        for block in blocks {
            let excluded = Set(candidates(block.words).flatMap(\.indices))
            let key = block.speaker ?? "Unknown speaker"
            if durations[key] == nil { durations[key] = [] }
            for (index, item) in block.words.enumerated() where !excluded.contains(index) {
                let word = item.word
                let duration = word.endMs - word.startMs
                if word.startMs.isFinite && word.endMs.isFinite && duration > 0 && isWordLike(word.text) {
                    durations[key, default: []].append(duration)
                    all.append(duration)
                }
            }
        }
        let meetingMedian = all.count >= 8 ? median(all) : 250
        let fallbackBudget = max(1000, 4 * meetingMedian)
        let budgets = durations.mapValues { max(1000, 4 * ($0.count >= 8 ? median($0) : meetingMedian)) }
        return blocks.map { original in
            var block = original
            let budget = budgets[block.speaker ?? "Unknown speaker"] ?? fallbackBudget
            var changed = false
            for candidate in candidates(block.words) where candidate.end - candidate.start > budget {
                for index in candidate.indices {
                    let word = block.words[index].word
                    let end = max(word.startMs, min(word.endMs, candidate.start + budget))
                    if end != word.endMs {
                        block.words[index].word.endMs = end
                        changed = true
                    }
                }
            }
            if changed, let end = block.words.map({ $0.word.endMs }).max() {
                block.endMs = max(block.startMs, min(block.endMs, end))
            }
            return block
        }
    }
}
