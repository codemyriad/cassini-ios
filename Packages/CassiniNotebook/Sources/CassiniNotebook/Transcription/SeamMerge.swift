import CassiniCore
import Foundation

/// Reconciles the words of two overlapping decode windows, ported from the desktop
/// pipeline's overlap dedup (through Android's `SeamMerge`). Decoder timestamps shift by hundreds of milliseconds when
/// the same word is heard with left versus right context, so a hard midpoint splice can
/// duplicate a word or drop both copies. Instead an order-preserving alignment of equal
/// normalized words near the overlap removes only confirmed duplicates; one-sided and
/// lexically different words survive. All times are source-timeline milliseconds, so
/// nothing here depends on the sample rate.
public enum SeamMerge {
    /// Widest accepted shift between two copies; the measured adjacent-decode shift is ~300 ms.
    public static let duplicateToleranceMs: Int64 = 400
    /// A lone repeated word is a duplicate only within this distance.
    public static let singletonToleranceMs: Int64 = 200
    /// Adjacent matches whose shifts agree this closely support each other up to the wider tolerance.
    public static let shiftConsistencyMs: Int64 = 100

    /// Appends `next` to `acc`, removing words both windows decoded inside the overlap
    /// `[windowStartMs, windowStartMs + overlapMs]`. Of two matched copies the one farther
    /// from its own decode boundary, where the recognizer had more context, is kept; a copy
    /// with duration beats a zero-length one. One-sided words can interleave, so the result
    /// is stably re-sorted by start. `midpointOnDisagreement` selects the merged-fallback
    /// policy: when both sides populate the overlap but nothing matches confidently, the
    /// earlier decode owns starts before the overlap midpoint and the later one the rest.
    public static func merge(_ acc: [Word], _ next: [Word], firstWindow: Bool, windowStartMs: Int64, overlapMs: Int64,
                             midpointOnDisagreement: Bool = false) -> [Word] {
        merge(acc, next, firstWindow: firstWindow, windowStartMs: windowStartMs, overlapMs: overlapMs,
              midpointOnDisagreement: midpointOnDisagreement) { $0 }
    }

    /// Joins two decodes of a forced cut that both heard `[overlapStartMs, overlapStartMs + overlapMs]`,
    /// centred on the cut. They agree on most words there, so the join is made at one agreed word, the
    /// one nearest the cut: everything up to it comes from the earlier decode and everything after it
    /// from the later one. Each reading is taken whole on its side, so a word the two decodes time or
    /// split differently is neither doubled nor lost. Without an agreed word the join is the instant
    /// nearest the cut at which neither decode is inside a word.
    public static func splice<T>(_ items: [T], _ more: [T], overlapStartMs: Int64, overlapMs: Int64, word: (T) -> Word) -> [T] {
        if items.isEmpty || more.isEmpty { return items + more }
        let acc = items.map(word)
        let next = more.map(word)
        let overlapEndMs = overlapStartMs + overlapMs
        let cutMs = overlapStartMs + overlapMs / 2
        let aligned = align(acc, next, overlapStartMs: overlapStartMs, overlapEndMs: overlapEndMs, toleranceMs: duplicateToleranceMs)
        // A lone pair further apart than the singleton tolerance is still the best evidence when nothing firmer exists.
        // Known trade-off: two distinct, quickly repeated words ("yes yes") inside the overlap can collapse into one
        // here, in exchange for never doubling a word the decodes timed 220-240 ms apart (measured on the phone).
        let confident = confidentMatches(aligned, acc, next, overlapEndMs: overlapEndMs)
        let agreed = confident.isEmpty ? aligned : confident
        var anchor: Match?
        var nearest = Int64.max
        for match in agreed {
            let distance = abs((midpointMs(acc[match.acc]) + midpointMs(next[match.next])) / 2 - cutMs)
            if distance < nearest { nearest = distance; anchor = match }
        }
        if let anchor {
            // A copy with duration beats a zero-length one, as in merge: a word stamped in padding and clamped to the
            // timeline edge would never highlight, so the later decode's copy replaces it.
            let clamped = acc[anchor.acc].endMs <= acc[anchor.acc].startMs
            let replacement = next[anchor.next].endMs > next[anchor.next].startMs
            return clamped && replacement ? Array(items[..<anchor.acc]) + Array(more[anchor.next...])
                                          : Array(items[...anchor.acc]) + Array(more[(anchor.next + 1)...])
        }
        let both = acc + next
        let inside = { (at: Int64) in both.contains { $0.startMs < at && at < $0.endMs } }
        var joinMs = cutMs
        var joinDistance = Int64.max
        for at in both.flatMap({ [$0.startMs, $0.endMs] }) where at >= overlapStartMs && at <= overlapEndMs && !inside(at) {
            if abs(at - cutMs) < joinDistance { joinDistance = abs(at - cutMs); joinMs = at }
        }
        return zip(items, acc).filter { midpointMs($0.1) < joinMs }.map(\.0) + zip(more, next).filter { midpointMs($0.1) >= joinMs }.map(\.0)
    }

    public static func splice(_ acc: [Word], _ next: [Word], overlapStartMs: Int64, overlapMs: Int64) -> [Word] {
        splice(acc, next, overlapStartMs: overlapStartMs, overlapMs: overlapMs) { $0 }
    }

    /// The same merge over items that carry a word, such as decoder words with their extension cap.
    public static func merge<T>(_ items: [T], _ more: [T], firstWindow: Bool, windowStartMs: Int64, overlapMs: Int64,
                                midpointOnDisagreement: Bool = false, word: (T) -> Word) -> [T] {
        if firstWindow || items.isEmpty { return items + more }
        if more.isEmpty { return items }
        let acc = items.map(word)
        let next = more.map(word)
        let overlapEndMs = windowStartMs + overlapMs
        let matches = confidentMatches(align(acc, next, overlapStartMs: windowStartMs, overlapEndMs: overlapEndMs,
                                             toleranceMs: duplicateToleranceMs), acc, next, overlapEndMs: overlapEndMs)
        if midpointOnDisagreement && matches.isEmpty &&
            hasWordInOverlap(acc, overlapStartMs: windowStartMs, overlapEndMs: overlapEndMs) &&
            hasWordInOverlap(next, overlapStartMs: windowStartMs, overlapEndMs: overlapEndMs) {
            // One owner per instant: the earlier decode keeps starts before the overlap midpoint, the later one the rest.
            let cutMs = windowStartMs + overlapMs / 2
            var kept = items.count
            while kept > 0 && acc[kept - 1].startMs >= cutMs { kept -= 1 }
            return Array(items[..<kept]) + zip(more, next).filter { $0.1.startMs >= cutMs }.map(\.0)
        }
        var dropAcc = [Bool](repeating: false, count: acc.count)
        var dropNext = [Bool](repeating: false, count: next.count)
        for match in matches {
            let old = acc[match.acc]
            let new = next[match.next]
            let oldHasDuration = old.endMs > old.startMs
            let newHasDuration = new.endMs > new.startMs
            if oldHasDuration != newHasDuration {
                if newHasDuration { dropAcc[match.acc] = true } else { dropNext[match.next] = true }
                continue
            }
            let oldContext = max(0, overlapEndMs - midpointMs(old))
            let newContext = max(0, midpointMs(new) - windowStartMs)
            if newContext > oldContext { dropAcc[match.acc] = true } else { dropNext[match.next] = true }
        }
        var merged: [(item: T, start: Int64)] = []
        for (i, item) in items.enumerated() where !dropAcc[i] { merged.append((item, acc[i].startMs)) }
        for (i, item) in more.enumerated() where !dropNext[i] { merged.append((item, next[i].startMs)) }
        // A stable sort by start: equal starts keep their source order.
        return merged.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element.item)
    }

    /// True when `words` positively populate the overlap; touching a boundary does not count.
    public static func hasWordInOverlap(_ words: [Word], overlapStartMs: Int64, overlapEndMs: Int64) -> Bool {
        words.contains { word in
            if word.endMs < word.startMs || normalize(word.text).isEmpty { return false }
            if word.endMs == word.startMs { return word.startMs >= overlapStartMs && word.startMs <= overlapEndMs }
            return word.endMs > overlapStartMs && word.startMs < overlapEndMs
        }
    }

    public struct Match: Hashable, Sendable {
        public var acc: Int
        public var next: Int
        public init(_ acc: Int, _ next: Int) { self.acc = acc; self.next = next }
    }

    private struct Ref {
        let index: Int
        /// The normalized text as code points: Swift's String equality is canonical, Kotlin's and Go's are not.
        let normal: [UInt32]
        let timestamp: Int64
    }

    private struct Cell {
        var matches = 0
        var distance: Int64 = 0
        var step: Character = "\0"
    }

    /// Maximum-count alignment of equal normalized words, ties broken by the smaller total
    /// start distance; on a full tie a match beats a skip, and skipping `acc` beats skipping `next`.
    public static func align(_ acc: [Word], _ next: [Word], overlapStartMs: Int64, overlapEndMs: Int64, toleranceMs: Int64) -> [Match] {
        let left = refs(acc, overlapStartMs: overlapStartMs, overlapEndMs: overlapEndMs, toleranceMs: toleranceMs)
        let right = refs(next, overlapStartMs: overlapStartMs, overlapEndMs: overlapEndMs, toleranceMs: toleranceMs)
        if left.isEmpty || right.isEmpty { return [] }
        var dp = [[Cell]](repeating: [Cell](repeating: Cell(), count: right.count + 1), count: left.count + 1)
        for i in stride(from: 1, through: left.count, by: 1) { dp[i][0] = dp[i - 1][0]; dp[i][0].step = "l" }
        for j in stride(from: 1, through: right.count, by: 1) { dp[0][j] = dp[0][j - 1]; dp[0][j].step = "r" }
        for i in 1...left.count {
            for j in 1...right.count {
                var best = dp[i - 1][j]
                best.step = "l"
                if better(dp[i][j - 1], best) { best = dp[i][j - 1]; best.step = "r" }
                let distance = abs(left[i - 1].timestamp - right[j - 1].timestamp)
                if left[i - 1].normal == right[j - 1].normal && distance <= toleranceMs {
                    let diagonal = dp[i - 1][j - 1]
                    let matched = Cell(matches: diagonal.matches + 1, distance: diagonal.distance + distance, step: "m")
                    if betterOrEqual(matched, best) { best = matched }
                }
                dp[i][j] = best
            }
        }
        var matches: [Match] = []
        var i = left.count
        var j = right.count
        while i > 0 || j > 0 {
            switch dp[i][j].step {
            case "m": matches.append(Match(left[i - 1].index, right[j - 1].index)); i -= 1; j -= 1
            case "l": i -= 1
            case "r": j -= 1
            default: i = 0; j = 0
            }
        }
        return matches.reversed()
    }

    private static func refs(_ words: [Word], overlapStartMs: Int64, overlapEndMs: Int64, toleranceMs: Int64) -> [Ref] {
        words.enumerated().compactMap { i, word in
            if word.endMs < word.startMs || word.endMs < overlapStartMs - toleranceMs || word.startMs > overlapEndMs + toleranceMs {
                return nil
            }
            let normal = normalize(word.text)
            return normal.isEmpty ? nil : Ref(index: i, normal: normal.unicodeScalars.map(\.value), timestamp: word.startMs)
        }
    }

    /// Narrows the permissive alignment so two distinct, rapidly repeated words are not
    /// collapsed merely because they share text. A lone pair must start within
    /// `singletonToleranceMs`; the wider shift is accepted only for an adjacent run with a
    /// consistent shift, or when replacing a zero-length token clamped at the overlap end.
    public static func confidentMatches(_ matches: [Match], _ acc: [Word], _ next: [Word], overlapEndMs: Int64) -> [Match] {
        if matches.isEmpty { return [] }
        var keep = matches.map { match in
            let old = acc[match.acc]
            return abs(old.startMs - next[match.next].startMs) <= singletonToleranceMs ||
                (old.startMs == overlapEndMs && old.endMs == overlapEndMs)
        }
        for i in 0..<(matches.count - 1) {
            let left = matches[i]
            let right = matches[i + 1]
            if right.acc != left.acc + 1 || right.next != left.next + 1 { continue }
            let leftShift = next[left.next].startMs - acc[left.acc].startMs
            let rightShift = next[right.next].startMs - acc[right.acc].startMs
            if abs(leftShift - rightShift) <= shiftConsistencyMs { keep[i] = true; keep[i + 1] = true }
        }
        return zip(matches, keep).filter(\.1).map(\.0)
    }

    /// Comparison key for an overlap word: per-code-point simple lowercase (Go's
    /// `unicode.ToLower`, not locale or context-sensitive lowercasing), curly single quotes
    /// folded to `'`, edge spaces and bracketing punctuation trimmed, then trailing dots, so
    /// "morning." equals "morning," while "C++", "we'", ".NET" and "3.14" keep their marks.
    /// Empty when no letter or number remains. Works on Unicode scalars throughout, never on graphemes.
    public static func normalize(_ text: String) -> String {
        var scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            scalar.value == 0x2018 || scalar.value == 0x2019 ? "'" : simpleLowercase(scalar)
        }[...]
        while let first = scalars.first, trimmed(first) { scalars.removeFirst() }
        while let last = scalars.last, trimmed(last) { scalars.removeLast() }
        while scalars.last == "." { scalars.removeLast() }
        guard scalars.contains(where: { isLetter($0) || isNumber($0) }) else { return "" }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    /// The simple (one-to-one) lowercase mapping of Java's `Character.toLowerCase(int)` and Go's `unicode.ToLower`.
    /// Swift exposes only the full mapping; the one unconditional full mapping longer than a scalar is U+0130 (İ to
    /// "i̇"), whose simple mapping is its first scalar.
    private static func simpleLowercase(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let mapping = scalar.properties.lowercaseMapping.unicodeScalars
        guard let first = mapping.first else { return scalar }
        return mapping.count == 1 || scalar.value == 0x130 ? first : scalar
    }

    private static let trimmedPunctuation: Set<Unicode.Scalar> = Set(",!?;:\"\u{201C}\u{201D}()[]{}<>".unicodeScalars)

    private static func trimmed(_ scalar: Unicode.Scalar) -> Bool { goIsSpace(scalar) || trimmedPunctuation.contains(scalar) }

    /// Go's `unicode.IsSpace` (the White_Space property): unlike Java it includes NBSP and excludes U+001C..U+001F.
    private static func goIsSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    /// Java's `Character.isLetter`: general category L.
    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    /// Go's `unicode.IsNumber` is category N, which also covers Nl and No (`²`, `½`), not only digits.
    private static func isNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    public static func midpointMs(_ word: Word) -> Int64 {
        word.endMs <= word.startMs ? word.startMs : word.startMs + (word.endMs - word.startMs) / 2
    }

    private static func better(_ candidate: Cell, _ current: Cell) -> Bool {
        candidate.matches > current.matches || (candidate.matches == current.matches && candidate.distance < current.distance)
    }

    private static func betterOrEqual(_ candidate: Cell, _ current: Cell) -> Bool {
        candidate.matches > current.matches || (candidate.matches == current.matches && candidate.distance <= current.distance)
    }
}
