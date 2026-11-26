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
                if !catalog.contains(where: { $0.byteID == Data(id.utf8) }) {
                    catalog.append(NoteSpeaker(id: id, name: transcript[index].speaker ?? DefaultLabels.placeholder(catalog.count + 1)))
                }
            } else if let name = transcript[index].speaker, !name.isEmpty {
                let id = legacy[name] ?? "legacy_\(UUID().uuidString)"
                legacy[name] = id
                transcript[index].speakerID = id
                if !catalog.contains(where: { $0.byteID == Data(id.utf8) }) { catalog.append(NoteSpeaker(id: id, name: name)) }
            }
        }
        speakers = catalog
        backfillSpeakerColours()
        refreshSpeakerLabels()
    }

    /// Metadata-only upgrade for existing local notes and their kept versions.
    public mutating func backfillSpeakerColours() {
        let all = (speakers ?? []) + (versions ?? []).flatMap(\.speakers)
        let assigned = Dictionary(all.compactMap { speaker in speaker.colourIndex.map { (speaker.byteID, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        var allocator = SpeakerColourAllocator(exactAssignments: assigned)
        func fill(_ catalog: [NoteSpeaker], order: [String]) -> [NoteSpeaker] {
            var result = catalog
            var seen = Set<Data>()
            for id in order + catalog.map(\.id) where seen.insert(Data(id.utf8)).inserted {
                guard let index = result.firstIndex(where: { $0.byteID == Data(id.utf8) }), result[index].colourIndex == nil else { continue }
                result[index].colourIndex = allocator.reserve(id)
            }
            return result
        }
        // Oldest kept speech supplies a legacy identity's original slot, before later merges/reordering.
        if var history = versions {
            for index in history.indices {
                history[index].speakers = fill(history[index].speakers, order: SpeakerColourOrder.segments(history[index].segments))
            }
            versions = history
        }
        if let catalog = speakers { speakers = fill(catalog, order: SpeakerColourOrder.segments(transcript)) }
    }

    /// Fill missing legacy slots once, preserving every existing assignment.
    public static func assignColourIndices(_ speakers: [NoteSpeaker], order: [String]) -> [NoteSpeaker] {
        var result = speakers
        var allocator = SpeakerColourAllocator(exactAssignments: Dictionary(speakers.compactMap { speaker in
            speaker.colourIndex.map { (speaker.byteID, $0) }
        }, uniquingKeysWith: { first, _ in first }))
        var seen = Set<Data>()
        for id in order + speakers.map(\.id) where seen.insert(Data(id.utf8)).inserted {
            guard let index = result.firstIndex(where: { $0.byteID == Data(id.utf8) }), result[index].colourIndex == nil else { continue }
            result[index].colourIndex = allocator.reserve(id)
        }
        return result
    }

    /// Writes each speaker's name onto its passages.
    public mutating func refreshSpeakerLabels() {
        for index in transcript.indices {
            if let id = transcript[index].speakerID { transcript[index].speaker = speakers?.first { $0.byteID == Data(id.utf8) }?.name }
        }
    }

    public func speaker(_ id: String) -> NoteSpeaker? { speakers?.first { $0.byteID == Data(id.utf8) } }

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

    /// The id of the selected version when it holds the transcript and speakers shown.
    public var shownVersionID: UUID? { shownVersionIndex.flatMap { versions?[$0].id } }

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
        backfillSpeakerColours()
        guard let index = speakers?.firstIndex(where: { $0.byteID == Data(id.utf8) }) else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Limits.nameMaxLength))
        guard !trimmed.isEmpty else { return }
        changeShownSpeakers { note in
            note.speakers?[index].name = trimmed; note.speakers?[index].provenance = .user; note.refreshSpeakerLabels()
        }
    }

    /// Marks or unmarks a speaker as a background voice, keeping its name and provenance intact (D112 / L-86).
    public mutating func setSpeakerBackground(_ id: String, _ background: Bool) {
        backfillSpeakerColours()
        guard let index = speakers?.firstIndex(where: { $0.byteID == Data(id.utf8) }) else { return }
        changeShownSpeakers { note in
            note.speakers?[index].background = background
        }
    }

    /// One speaker's before/after state for a version-bound Name a speaker batch Undo (D112 / L-86).
    public struct SpeakerUndoEntry: Equatable, Hashable, Sendable {
        public let speakerID: String
        public let before: NoteSpeaker
        public let after: NoteSpeaker
        public init(speakerID: String, before: NoteSpeaker, after: NoteSpeaker) {
            self.speakerID = speakerID; self.before = before; self.after = after
        }
    }

    /// Restores the shown speakers (and refreshes passage labels) from an Undo snapshot without adding a version.
    public mutating func restoreShownSpeakers(_ previous: [NoteSpeaker]?) {
        changeShownSpeakers { note in
            note.speakers = previous
            note.refreshSpeakerLabels()
        }
    }

    /// Whether `entries` can be safely undone on the target version (`versionID`, or the unversioned shown transcript
    /// when `versionID` is nil) without overwriting another version or newer edits to those speakers.
    public func canRestoreSpeakers(_ entries: [SpeakerUndoEntry], versionID: UUID?,
                                   expectedAfterSpeakers: [NoteSpeaker]? = nil) -> Bool {
        guard !entries.isEmpty else { return false }
        func matches(_ list: [NoteSpeaker]) -> Bool {
            entries.allSatisfy { entry in
                list.first(where: { $0.byteID == Data(entry.speakerID.utf8) }) == entry.after
            }
        }
        if let targetVersionID = versionID {
            if shownVersionID == targetVersionID {
                return speakers.map(matches) ?? false
            }
            if let version = versions?.first(where: { $0.id == targetVersionID }) {
                return matches(version.speakers)
            }
            return false
        }
        if shownVersionID == nil {
            return speakers.map(matches) ?? false
        }
        if let expected = expectedAfterSpeakers,
           let version = versions?.last(where: { $0.id != selectedVersionID && $0.speakers == expected }) {
            return matches(version.speakers)
        }
        return false
    }

    /// Restores only the speakers in `entries` on their original transcript version (`versionID`), leaving any other
    /// currently displayed version untouched. Returns true if the target version matched the expected revision.
    @discardableResult
    public mutating func restoreSpeakers(_ entries: [SpeakerUndoEntry], versionID: UUID?,
                                         expectedAfterSpeakers: [NoteSpeaker]? = nil) -> Bool {
        guard !entries.isEmpty else { return false }
        func matches(_ list: [NoteSpeaker]) -> Bool {
            entries.allSatisfy { entry in
                list.first(where: { $0.byteID == Data(entry.speakerID.utf8) }) == entry.after
            }
        }
        func patch(_ list: inout [NoteSpeaker], segments: inout [TranscriptSegment]) {
            for entry in entries {
                if let index = list.firstIndex(where: { $0.byteID == Data(entry.speakerID.utf8) }) {
                    list[index] = entry.before
                }
            }
            for index in segments.indices {
                if let id = segments[index].speakerID {
                    segments[index].speaker = list.first { $0.byteID == Data(id.utf8) }?.name
                }
            }
        }
        if let targetVersionID = versionID {
            if shownVersionID == targetVersionID, let shown = shownVersionIndex {
                guard var list = speakers, matches(list) else { return false }
                patch(&list, segments: &transcript)
                speakers = list
                versions?[shown].segments = transcript
                versions?[shown].speakers = list
                return true
            }
            if var history = versions, let index = history.firstIndex(where: { $0.id == targetVersionID }) {
                var version = history[index]
                guard matches(version.speakers) else { return false }
                patch(&version.speakers, segments: &version.segments)
                history[index] = version
                versions = history
                return true
            }
            return false
        }
        if shownVersionID == nil {
            guard var list = speakers, matches(list) else { return false }
            patch(&list, segments: &transcript)
            speakers = list
            return true
        }
        if let expected = expectedAfterSpeakers, var history = versions,
           let index = history.lastIndex(where: { $0.id != selectedVersionID && $0.speakers == expected }) {
            var version = history[index]
            guard matches(version.speakers) else { return false }
            patch(&version.speakers, segments: &version.segments)
            history[index] = version
            versions = history
            return true
        }
        return false
    }

    /// Rolls back partially committed speakers on `versionID` after a mid-batch failure.
    public mutating func rollbackSpeakers(_ previous: [NoteSpeaker], versionID: UUID?) {
        guard !previous.isEmpty else { return }
        func patch(_ list: inout [NoteSpeaker], segments: inout [TranscriptSegment]) {
            for speaker in previous {
                if let index = list.firstIndex(where: { $0.byteID == speaker.byteID }) {
                    list[index] = speaker
                }
            }
            for index in segments.indices {
                if let id = segments[index].speakerID {
                    segments[index].speaker = list.first { $0.byteID == Data(id.utf8) }?.name
                }
            }
        }
        if let targetVersionID = versionID {
            if shownVersionID == targetVersionID, let shown = shownVersionIndex {
                guard var list = speakers else { return }
                patch(&list, segments: &transcript)
                speakers = list
                versions?[shown].segments = transcript
                versions?[shown].speakers = list
            } else if var history = versions, let index = history.firstIndex(where: { $0.id == targetVersionID }) {
                var version = history[index]
                patch(&version.speakers, segments: &version.segments)
                history[index] = version
                versions = history
            }
        } else if shownVersionID == nil, var list = speakers {
            patch(&list, segments: &transcript)
            speakers = list
        }
    }

    /// Restores a voice link that `unlinkVoice` scrubbed when a voice's last sample was temporarily removed.
    /// Only restores links that are currently `.unmatched`, never overwriting a newer match or rejection.
    public mutating func restoreVoiceLink(speakerID: String, versionID: UUID?, match: VoiceMatchState) {
        let key = Data(speakerID.utf8)
        if let versionID {
            if var history = versions, let vIndex = history.firstIndex(where: { $0.id == versionID }),
               let sIndex = history[vIndex].speakers.firstIndex(where: { $0.byteID == key }),
               history[vIndex].speakers[sIndex].match == .unmatched {
                history[vIndex].speakers[sIndex].match = match
                versions = history
                if selectedVersionID == versionID,
                   var shownList = speakers,
                   let shownIndex = shownList.firstIndex(where: { $0.byteID == key }),
                   shownList[shownIndex].match == .unmatched {
                    shownList[shownIndex].match = match
                    speakers = shownList
                }
            }
        } else if var list = speakers,
                  let index = list.firstIndex(where: { $0.byteID == key }),
                  list[index].match == .unmatched {
            changeShownSpeakers { note in
                note.speakers?[index].match = match
            }
        }
    }

    /// Shows everything `source` said as `target`, keeping the transcript before the merge as a version. The merged
    /// version links `target` to its voice only as an automatic match: a confirmed sample belongs to the version it
    /// was confirmed in, so taking it back later never takes it back twice. The merged version records the alias and
    /// the version it was made from, for the export's provenance.
    public mutating func mergeSpeaker(_ source: String, into target: String, stamp: VersionStamp = VersionStamp(date: Date())) {
        guard Data(source.utf8) != Data(target.utf8), speaker(source) != nil, let targetIndex = speakers?.firstIndex(where: { $0.byteID == Data(target.utf8) })
        else { return }
        backfillSpeakerColours()
        let mergedFrom = shownVersionIndex.flatMap { versions?[$0].id } ?? stamp.before
        saveCurrentVersion(.beforeSpeakerMerge, id: stamp.before, date: stamp.date)
        for index in transcript.indices where transcript[index].speakerID.map({ Data($0.utf8) }) == Data(source.utf8) { transcript[index].speakerID = target }
        if case .confirmed(let voice, let score) = speakers?[targetIndex].match {
            speakers?[targetIndex].match = .auto(voice: voice, score: score)
        }
        speakers?.removeAll { $0.byteID == Data(source.utf8) }
        refreshSpeakerLabels()
        selectedVersionID = nil
        saveCurrentVersion(.mergedSpeakers, id: stamp.after, date: stamp.date)
        if let merged = versions?.firstIndex(where: { $0.id == stamp.after }) {
            versions?[merged].speakerMerges = [source: target]
            versions?[merged].derivedFrom = mergedFrom
        }
    }

    public mutating func addSpeaker(id: String, name: String) {
        backfillSpeakerColours()
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Limits.nameMaxLength))
        guard !trimmed.isEmpty, speaker(id) == nil else { return }
        changeShownSpeakers {
            let all = ($0.speakers ?? []) + ($0.versions ?? []).flatMap(\.speakers)
            var allocator = SpeakerColourAllocator(exactAssignments: Dictionary(all.compactMap { speaker in
                speaker.colourIndex.map { (speaker.byteID, $0) }
            }, uniquingKeysWith: { first, _ in first }))
            $0.speakers = ($0.speakers ?? []) + [NoteSpeaker(id: id, name: trimmed,
                colourIndex: allocator.reserve(id), provenance: .user)]
        }
    }
}
