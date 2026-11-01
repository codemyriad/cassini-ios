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
    /// change may run again passes the version's `id` and `date`, so that the rerun makes the same version. The
    /// transcript counts as an edited copy of the selected version, so the new version keeps that version's merge
    /// (`speakerMerges`, `derivedFrom`) and re-attribution (`attributedFrom`) for the export's provenance. The version
    /// keeps the note's `language`, the language of the words it holds.
    public mutating func saveCurrentVersion(_ kind: TranscriptVersionKind, id versionID: UUID = UUID(), date: Date = Date()) {
        saveCurrentVersion(kind, id: versionID, date: date, editedFrom: selectedVersionID)
    }

    /// `saveCurrentVersion(_:id:date:)` for a transcript that is an edited copy of version `base`.
    mutating func saveCurrentVersion(_ kind: TranscriptVersionKind, id versionID: UUID, date: Date, editedFrom base: UUID?) {
        guard !transcript.isEmpty else { return }
        guard shownVersionIndex == nil else { return }
        var history = versions ?? []
        var version = TranscriptVersion(kind: kind, segments: transcript, speakers: speakers ?? [], language: language)
        version.id = versionID; version.createdAt = date
        if let source = base.flatMap({ id in history.first { $0.id == id } }) {
            version.speakerMerges = source.speakerMerges
            version.derivedFrom = source.derivedFrom
            version.attributedFrom = source.attributedFrom
        }
        history.append(version); selectedVersionID = version.id
        versions = history
    }

    public mutating func selectVersion(_ id: UUID) {
        saveCurrentVersion(.previous)
        guard let version = versions?.first(where: { $0.id == id }) else { return }
        transcript = version.segments; speakers = version.speakers; language = version.language; selectedVersionID = id
    }

    /// The version numbers a merge shows: the one shown now and the one it adds ("This adds version 3; version 2
    /// stays available"). Versions are numbered from 1 in the order they were kept.
    public var mergeVersionNumbers: (shown: Int, added: Int) {
        let count = versions?.count ?? 0
        if let index = shownVersionIndex { return (index + 1, count + 1) }
        return (count + 1, count + 2)
    }

    /// The index of the selected version when it holds the transcript and speakers shown.
    var shownVersionIndex: Int? {
        guard let id = selectedVersionID, let index = versions?.firstIndex(where: { $0.id == id }),
              let version = versions?[index], version.segments == transcript, version.speakers == speakers ?? []
        else { return nil }
        return index
    }

    /// Runs a change to the shown speakers that adds no version (naming, a match, a rejection, a new speaker). When
    /// the selected version held the shown transcript, it takes the change too, so it still holds it: the change
    /// neither counts as another version nor breaks a run of passage edits. Android keeps speakers on the shown
    /// variant the same way.
    mutating func changeShownSpeakers(_ change: (inout Note) -> Void) {
        let shown = shownVersionIndex
        change(&self)
        guard let shown else { return }
        versions?[shown].segments = transcript
        versions?[shown].speakers = speakers ?? []
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
        changeShownSpeakers { note in
            note.speakers?[index].name = trimmed; note.refreshSpeakerLabels()
        }
    }

    /// Shows everything `source` said as `target`, keeping the transcript before the merge as a version. The merged
    /// version links `target` to its voice only as an automatic match: a confirmed sample belongs to the version it
    /// was confirmed in, so taking it back later never takes it back twice. The merged version records the alias and
    /// the version it was made from, for the export's provenance.
    public mutating func mergeSpeaker(_ source: String, into target: String, stamp: VersionStamp = VersionStamp(date: Date())) {
        guard source != target, speaker(source) != nil, let targetIndex = speakers?.firstIndex(where: { $0.id == target })
        else { return }
        let mergedFrom = shownVersionIndex.flatMap { versions?[$0].id } ?? stamp.before
        saveCurrentVersion(.beforeSpeakerMerge, id: stamp.before, date: stamp.date)
        for index in transcript.indices where transcript[index].speakerID == source { transcript[index].speakerID = target }
        if case .confirmed(let voice, let score) = speakers?[targetIndex].match {
            speakers?[targetIndex].match = .auto(voice: voice, score: score)
        }
        speakers?.removeAll { $0.id == source }
        refreshSpeakerLabels()
        selectedVersionID = nil
        saveCurrentVersion(.mergedSpeakers, id: stamp.after, date: stamp.date)
        if let merged = versions?.firstIndex(where: { $0.id == stamp.after }) {
            versions?[merged].speakerMerges = [source: target]
            versions?[merged].derivedFrom = mergedFrom
        }
    }

    public mutating func addSpeaker(id: String, name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Limits.nameMaxLength))
        guard !trimmed.isEmpty, speaker(id) == nil else { return }
        changeShownSpeakers { $0.speakers = ($0.speakers ?? []) + [NoteSpeaker(id: id, name: trimmed)] }
    }
}
