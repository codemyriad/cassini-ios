import Foundation

public struct SpeakerTurn: Hashable, Sendable {
    public var speakerID: String
    public var start: Double
    public var end: Double
    public init(speakerID: String, start: Double, end: Double) { self.speakerID = speakerID; self.start = start; self.end = end }
}

public enum SpeakerAttribution {
    public static func isolatedSeconds(speakerID: String, turns: [SpeakerTurn]) -> Double {
        var events: [(time: Double, own: Int, other: Int)] = []
        for turn in turns where turn.start.isFinite && turn.end.isFinite && turn.end > turn.start {
            let own = turn.speakerID == speakerID
            events.append((turn.start, own ? 1 : 0, own ? 0 : 1))
            events.append((turn.end, own ? -1 : 0, own ? 0 : -1))
        }
        events.sort { $0.time < $1.time }
        var own = 0, other = 0; var previous = events.first?.time ?? 0; var duration = 0.0
        for event in events {
            if own > 0 && other == 0 { duration += max(0, event.time - previous) }
            own += event.own; other += event.other; previous = event.time
        }
        return duration
    }

    /// Maximum overlapping speech wins. An uncovered word remains unattributed; no invented timing.
    public static func assign(_ transcript: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        let valid = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        func speaker(start: Double, end: Double) -> String? {
            var scores: [String: Double] = [:]
            for turn in valid {
                let overlap = max(0, min(end, turn.end) - max(start, turn.start))
                if overlap > 0 { scores[turn.speakerID, default: 0] += overlap }
            }
            return scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.first?.key
        }
        return transcript.flatMap { segment -> [TranscriptSegment] in
            guard !segment.words.isEmpty else {
                var copy = segment; copy.speakerID = speaker(start: segment.start, end: segment.end); copy.speaker = nil
                return [copy]
            }
            var result: [TranscriptSegment] = []
            for word in segment.words {
                let id = speaker(start: word.start, end: word.end)
                if let last = result.indices.last, result[last].speakerID == id {
                    result[last].words.append(word); result[last].text += word.text; result[last].end = max(result[last].end, word.end)
                } else {
                    result.append(TranscriptSegment(text: word.text, start: word.start, end: word.end, speakerID: id, words: [word]))
                }
            }
            return result.map { var s = $0; s.text = s.text.trimmingCharacters(in: .whitespacesAndNewlines); return s }
        }
    }
}

extension Note {
    /// Upgrade legacy passage labels without conflating unlabeled passages or changing their text.
    public mutating func migrateSpeakers() {
        var catalog = speakers ?? []
        var legacy: [String: String] = [:]
        for index in transcript.indices {
            if let id = transcript[index].speakerID {
                if !catalog.contains(where: { $0.id == id }) { catalog.append(NoteSpeaker(id: id, name: transcript[index].speaker ?? "Speaker \(catalog.count + 1)")) }
            } else if let name = transcript[index].speaker, !name.isEmpty {
                let id = legacy[name] ?? "legacy_\(UUID().uuidString)"
                legacy[name] = id
                transcript[index].speakerID = id
                if !catalog.contains(where: { $0.id == id }) { catalog.append(NoteSpeaker(id: id, name: name)) }
            }
        }
        speakers = catalog; refreshSpeakerLabels()
    }
    public mutating func refreshSpeakerLabels() {
        for index in transcript.indices {
            if let id = transcript[index].speakerID { transcript[index].speaker = speakers?.first { $0.id == id }?.name }
        }
    }
    /// Keeps the transcript and speakers as a version, unless the selected version already holds them. A caller whose
    /// change may run again passes the version's `id` and `date`, so that the rerun makes the same version.
    public mutating func saveCurrentVersion(name: String, id versionID: UUID = UUID(), date: Date = Date()) {
        guard !transcript.isEmpty else { return }
        var history = versions ?? []
        if let id = selectedVersionID, let current = history.first(where: { $0.id == id }),
           current.segments == transcript, current.speakers == speakers ?? [] { return }
        var version = TranscriptVersion(name: name, segments: transcript, speakers: speakers ?? [])
        version.id = versionID; version.createdAt = date
        history.append(version); selectedVersionID = version.id
        versions = history
    }
    public mutating func selectVersion(_ id: UUID) {
        saveCurrentVersion(name: "Previous transcript")
        guard let version = versions?.first(where: { $0.id == id }) else { return }
        transcript = version.segments; speakers = version.speakers; selectedVersionID = id
    }
    public mutating func renameSpeaker(_ id: String, name: String) {
        guard let index = speakers?.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !trimmed.isEmpty else { return }
        speakers?[index].name = trimmed; refreshSpeakerLabels()
    }
    public mutating func mergeSpeaker(_ source: String, into target: String) {
        guard source != target, speakers?.contains(where: { $0.id == source }) == true,
              speakers?.contains(where: { $0.id == target }) == true else { return }
        saveCurrentVersion(name: "Before speaker merge")
        for index in transcript.indices where transcript[index].speakerID == source { transcript[index].speakerID = target }
        speakers?.removeAll { $0.id == source }; refreshSpeakerLabels()
        selectedVersionID = nil; saveCurrentVersion(name: "Merged speakers")
    }
}
