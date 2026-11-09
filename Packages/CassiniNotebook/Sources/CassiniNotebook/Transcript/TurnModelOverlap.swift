import Foundation

extension TurnModel {
    struct Interval {
        var start: Double
        var end: Double
    }

    static func mergeIntervals(_ intervals: [Interval]) -> [Interval] {
        var result: [Interval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let previous = result.last, interval.start <= previous.end {
                result[result.count - 1].end = max(previous.end, interval.end)
            } else {
                result.append(interval)
            }
        }
        return result
    }

    static func audibleBounds(_ block: Block) -> Interval? {
        let spans = block.spans
        guard let first = spans.first, let last = spans.last,
              first.start.isFinite, last.end.isFinite, last.end > first.start else { return nil }
        return Interval(start: first.start, end: last.end)
    }

    static func duration(_ spans: [Interval]) -> Double { spans.reduce(0) { $0 + $1.end - $1.start } }

    static func intersectionDuration(_ left: [Interval], _ right: [Interval]) -> Double {
        var leftIndex = 0
        var rightIndex = 0
        var result: Double = 0
        while leftIndex < left.count && rightIndex < right.count {
            let a = left[leftIndex]
            let b = right[rightIndex]
            result += max(0, min(a.end, b.end) - max(a.start, b.start))
            if a.end <= b.end { leftIndex += 1 } else { rightIndex += 1 }
        }
        return result
    }

    struct Run {
        var speaker: String?
        var blocks: [Block]
        var startMs: Double
        var endMs: Double
        var attested: Bool
        var lastPosition: Int

        var spans: [Interval] { mergeIntervals(blocks.flatMap(\.spans)) }
        var key: String { speaker ?? "Unknown speaker" }
    }

    static func turnRuns(_ blocks: [Block]) -> [Run] {
        var runs: [Run] = []
        var open: [String: Int] = [:]
        for (position, block) in blocks.enumerated() {
            let key = block.speaker ?? "Unknown speaker"
            let bounds = audibleBounds(block)
            if let runIndex = open[key], let bounds, runs[runIndex].attested,
               abs(bounds.start - runs[runIndex].endMs) <= 400,
               seamHasContinuity(runs[runIndex], next: block, position: position, ordered: blocks) {
                runs[runIndex].blocks.append(block)
                runs[runIndex].endMs = max(runs[runIndex].endMs, bounds.end)
                runs[runIndex].lastPosition = position
            } else {
                open[key] = runs.count
                runs.append(Run(speaker: block.speaker, blocks: [block], startMs: bounds?.start ?? block.startMs,
                                endMs: bounds?.end ?? block.endMs, attested: bounds != nil, lastPosition: position))
            }
        }
        return runs
    }

    static func nearlyTouch(_ left: [Interval], _ right: [Interval]) -> Bool {
        left.contains { a in right.contains { b in max(a.start, b.start) - min(a.end, b.end) <= 20 } }
    }

    static func seamHasContinuity(_ run: Run, next: Block, position: Int, ordered: [Block]) -> Bool {
        if position == run.lastPosition + 1 { return true }
        guard let previous = run.blocks.last else { return false }
        var sawInterveningSpeech = false
        for index in (run.lastPosition + 1)..<position {
            let between = ordered[index]
            if (between.speaker ?? "Unknown speaker") == run.key { continue }
            let spans = between.spans
            if spans.isEmpty { continue }
            sawInterveningSpeech = true
            if nearlyTouch(spans, previous.spans) || nearlyTouch(spans, next.spans) { return true }
        }
        return !sawInterveningSpeech
    }

    struct Seam {
        var beforeID: Int
        var beforeEnd: Double
        var afterStart: Double
    }

    static func seamAround(_ host: Run, start: Double) -> Seam? {
        var beforeIndex: Int?
        for (index, block) in host.blocks.enumerated() {
            if let bounds = audibleBounds(block), bounds.start < start { beforeIndex = index }
        }
        guard let beforeIndex, beforeIndex + 1 < host.blocks.count,
              let before = audibleBounds(host.blocks[beforeIndex]),
              let after = audibleBounds(host.blocks[beforeIndex + 1]) else { return nil }
        return Seam(beforeID: host.blocks[beforeIndex].id, beforeEnd: before.end, afterStart: after.start)
    }

    struct Nest {
        var host: Int
        var beforeID: Int
    }

    static func nestedRuns(_ runs: [Run]) -> [Int: Nest] {
        var candidates: [Int: Nest] = [:]
        for (runIndex, run) in runs.enumerated() {
            guard run.attested, duration(run.spans) <= 2000 else { continue }
            var best: Nest?
            var bestBeforeEnd = -Double.infinity
            var bestSpan: Double = -1
            for (hostIndex, host) in runs.enumerated() {
                guard hostIndex != runIndex, host.attested, host.key != run.key, run.endMs <= host.endMs,
                      let seam = seamAround(host, start: run.startMs) else { continue }
                let startsInside = host.blocks.filter { block in
                    guard let bounds = audibleBounds(block) else { return false }
                    return bounds.start > run.startMs && bounds.start <= run.endMs
                }.count
                guard startsInside <= 1, run.startMs - seam.beforeEnd <= 500,
                      seam.afterStart - run.endMs <= 500 else { continue }
                let span = host.endMs - host.startMs
                if seam.beforeEnd > bestBeforeEnd || (seam.beforeEnd == bestBeforeEnd && span > bestSpan) {
                    best = Nest(host: hostIndex, beforeID: seam.beforeID)
                    bestBeforeEnd = seam.beforeEnd
                    bestSpan = span
                }
            }
            if let best { candidates[runIndex] = best }
        }
        // A candidate host cannot itself be nested: exactly one level of chips.
        return candidates.filter { candidates[$0.value.host] == nil }
    }

    struct Collision {
        var left: Int
        var right: Int
        var duration: Double
    }

    static func competingSpeakers(_ runs: [Run], nested: [Int: Nest]) -> [Int: [String]] {
        var collisions: [Collision] = []
        let spans = runs.map(\.spans)
        for left in runs.indices {
            for right in runs.indices where right > left && runs[left].key != runs[right].key {
                let overlap = intersectionDuration(spans[left], spans[right])
                if overlap >= 150 {
                    collisions.append(Collision(left: left, right: right, duration: overlap))
                }
            }
        }
        // Viewer stable sort: largest collision, then first block's canonical id.
        collisions = collisions.enumerated().sorted { a, b in
            if a.element.duration != b.element.duration { return a.element.duration > b.element.duration }
            let aID = runs[a.element.left].blocks[0].id
            let bID = runs[b.element.left].blocks[0].id
            return aID == bID ? a.offset < b.offset : aID < bID
        }.map(\.element)
        var result: [Int: [String]] = [:]
        for collision in collisions {
            if nested[collision.right]?.host == collision.left || nested[collision.left]?.host == collision.right { continue }
            let pairs = [(collision.left, runs[collision.right].key), (collision.right, runs[collision.left].key)]
            for (index, speaker) in pairs where !(result[index] ?? []).contains(speaker) {
                result[index, default: []].append(speaker)
            }
        }
        return result
    }
}
