import Foundation

/// Ids and a date made before a change that adds transcript versions, so that running the change again on a newer
/// note (see `NoteEdit`) adds the same versions.
public struct VersionStamp: Hashable, Sendable {
    public var before: UUID
    public var after: UUID
    public var date: Date
    public init(before: UUID = UUID(), after: UUID = UUID(), date: Date) {
        self.before = before; self.after = after; self.date = date
    }
}

extension Note {
    /// Upgrade legacy passage labels without conflating unlabeled passages or changing their text.
    public mutating func migrateSpeakers() {
        var catalog = speakers ?? []
        var legacy: [String: String] = [:]
        for index in transcript.indices {
            if let id = transcript[index].speakerID {
                if !catalog.contains(where: { $0.id == id }) {
                    catalog.append(NoteSpeaker(id: id, name: transcript[index].speaker ?? DefaultLabels.placeholder(catalog.count + 1)))
                }
            } else if let name = transcript[index].speaker, !name.isEmpty {
                let id = legacy[name] ?? "legacy_\(UUID().uuidString)"
                legacy[name] = id
                transcript[index].speakerID = id
                if !catalog.contains(where: { $0.id == id }) { catalog.append(NoteSpeaker(id: id, name: name)) }
            }
        }
        speakers = catalog
        refreshSpeakerLabels()
    }

    /// Writes each speaker's name onto its passages.
    public mutating func refreshSpeakerLabels() {
        for index in transcript.indices {
            if let id = transcript[index].speakerID { transcript[index].speaker = speakers?.first { $0.id == id }?.name }
        }
    }

    public func speaker(_ id: String) -> NoteSpeaker? { speakers?.first { $0.id == id } }

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

    /// The version numbers a merge shows: the one shown now and the one it adds ("This adds version 3; version 2
    /// stays available"). Versions are numbered from 1 in the order they were kept.
    public var mergeVersionNumbers: (shown: Int, added: Int) {
        let history = versions ?? []
        if let id = selectedVersionID, let index = history.firstIndex(where: { $0.id == id }),
           history[index].segments == transcript, history[index].speakers == speakers ?? [] {
            return (index + 1, history.count + 1)
        }
        return (history.count + 1, history.count + 2)
    }

    /// How many versions the note has: the kept ones, and the transcript shown when no kept version holds it. The
    /// version chip and Document info both count this way.
    public var versionCount: Int {
        guard !transcript.isEmpty || !(versions ?? []).isEmpty else { return 0 }
        return max(versions?.count ?? 0, mergeVersionNumbers.shown)
    }

    /// Names a speaker, trimmed and cut to `Limits.nameMaxLength`; a blank name changes nothing.
    public mutating func renameSpeaker(_ id: String, name: String) {
        guard let index = speakers?.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Limits.nameMaxLength))
        guard !trimmed.isEmpty else { return }
        speakers?[index].name = trimmed; refreshSpeakerLabels()
    }

    /// Shows everything `source` said as `target`, keeping the transcript before the merge as a version. The merged
    /// version links `target` to its voice only as an automatic match: a confirmed sample belongs to the version it
    /// was confirmed in, so taking it back later never takes it back twice.
    public mutating func mergeSpeaker(_ source: String, into target: String, stamp: VersionStamp = VersionStamp(date: Date())) {
        guard source != target, speaker(source) != nil, let targetIndex = speakers?.firstIndex(where: { $0.id == target })
        else { return }
        saveCurrentVersion(name: "Before speaker merge", id: stamp.before, date: stamp.date)
        for index in transcript.indices where transcript[index].speakerID == source { transcript[index].speakerID = target }
        if case .confirmed(let voice, let score) = speakers?[targetIndex].match {
            speakers?[targetIndex].match = .auto(voice: voice, score: score)
        }
        speakers?.removeAll { $0.id == source }
        refreshSpeakerLabels()
        selectedVersionID = nil
        saveCurrentVersion(name: Self.mergedVersionName, id: stamp.after, date: stamp.date)
    }

    public mutating func addSpeaker(id: String, name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Limits.nameMaxLength))
        guard !trimmed.isEmpty, speaker(id) == nil else { return }
        speakers = (speakers ?? []) + [NoteSpeaker(id: id, name: trimmed)]
    }
}
