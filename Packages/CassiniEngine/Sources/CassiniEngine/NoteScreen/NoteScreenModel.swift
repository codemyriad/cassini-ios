import CassiniCore
import Foundation
import Observation
import CassiniNotebook

/// What the Note screen could not do, for the app's error presenter to word.
public enum NoteProblem {
    /// A Transcribe (or Start over, or Identify speakers) was refused.
    case refused(EnqueueRefusal)
    /// A transcript or audio export could not be made.
    case export(ExportError)
    /// The Cassini document could not be made.
    case documentNotSaved
    /// An answer to "Is this Luca?" could not be saved.
    case speakerNotSaved(VoicesStore.SaveFailure)
}

/// The Note screen's state and the effects it carries out (Android `NoteViewModel`'s side of the stores). The rules
/// are pure and in CassiniNotebook: `NoteScreenState` turns taps, banner buttons and menu rows into `NoteEffect`s,
/// `NoteSheet(opening:)` picks the sheet an effect opens, and `PlaybackFollow` decides auto-follow and its resume
/// timer. This model keeps what the screen shows (the open sheet, the share sheet, the saved draft) and runs each
/// effect through its `Ports`, which the app binds to its stores. The sheets of the screen (Speakers, Versions, Edit
/// passage, the suggestion cards) act through it too, so the transcript's read-only rule holds in every one of them.
@MainActor @Observable
public final class NoteScreenModel {
    public struct Ports {
        // Notes
        public var note: @MainActor (UUID) -> Note?
        /// The note's job, nil without one.
        public var job: @MainActor (UUID) -> Job?
        /// Saves a note's change.
        public var update: @MainActor (UUID, @escaping @Sendable (inout Note) -> Void) -> Void
        /// Changes the note now and waits for the write; nil when it failed or the note is gone.
        public var commit: @MainActor (UUID, @escaping @Sendable (inout Note) -> Void) async -> Note?
        public var markMoment: @MainActor (UUID, TimeInterval) -> Void
        public var removeBookmark: @MainActor (UUID, UUID) -> Void
        /// Speakers: Add a speaker, by name.
        public var addSpeaker: @MainActor (UUID, String) -> Void
        /// Versions: shows the version.
        public var selectVersion: @MainActor (UUID, UUID) -> Void
        /// "Yes, Luca" (true) or "Not Luca" (false).
        public var answerSuggestion: @MainActor (SpeakerSuggestion, UUID, Bool) async throws(VoicesStore.SaveFailure) -> Void
        /// What Name a speaker needs about a speaker, and the writes it asks for.
        public var namingInput: @MainActor (UUID, String) async -> NamingInput?
        public var performNaming: @MainActor ([NamingEffect], UUID, String) async throws(VoicesStore.SaveFailure) -> Void

        // The queue
        public var transcribe: @MainActor (UUID, JobKind) async -> TranscribeOutcome
        public var startOver: @MainActor (UUID) async -> TranscribeOutcome
        /// Stop and keep progress on the running note; Remove from queue on a queued one.
        public var stop: @MainActor (UUID) -> Void
        public var dequeue: @MainActor (UUID) -> Void
        public var continueQueue: @MainActor () -> Void
        public var clearFailed: @MainActor (UUID) -> Void
        /// Cancel of the running job's model download.
        public var cancelJobDownload: @MainActor () -> Void
        /// The words of the note's saved progress.
        public var savedDraft: @MainActor (UUID) async -> [DraftWord]
        /// Whether the speaker models are installed, so names carry over to a new version.
        public var speakerModelsReady: @MainActor () async -> Bool

        // The player
        /// Whether the note holds the player and it can play.
        public var ownsPlayer: @MainActor (UUID) -> Bool
        public var play: @MainActor () -> Void
        /// Plays the note from a time, when it holds the player.
        public var playFrom: @MainActor (Note, TimeInterval) -> Void
        /// Opens the note's player for the screen, or reloads it when the audio changed.
        public var showPlayer: @MainActor (Note, PlaybackOwner) -> Void
        public var leavePlayer: @MainActor (PlaybackOwner) -> Void
        /// A recording keeps the player closed.
        public var playerBlocked: @MainActor () -> Bool
        /// A recording holds the audio.
        public var recording: @MainActor () -> Bool

        // Exports
        public var exportTranscript: @MainActor (UUID, TranscriptFormat) async throws(ExportError) -> URL
        public var copyAudio: @MainActor (UUID) async throws(ExportError) -> URL
        public var exportDocument: @MainActor (UUID) async throws -> URL
        /// Removes an export once the share sheet is done with it.
        public var discardExport: @MainActor (URL) -> Void
        /// Move to Recently Deleted (it asks first while the note is transcribing).
        public var trash: @MainActor (UUID) async -> Void

        // Navigation
        public var session: @MainActor (UUID) -> NoteSession
        public var isOpen: @MainActor (UUID) -> Bool
        public var markStarted: @MainActor (UUID) -> Void
        /// The model download screen over the note (`ScreenStack.offerModelDownload`).
        public var openModelDownload: @MainActor (UUID) -> Void
        public var present: @MainActor (NoteProblem) -> Void

        // The draft's names
        /// The note's draft names now and after every change (`DraftNamesStore.changes`).
        public var draftNames: @MainActor (UUID) -> AsyncStream<DraftNames> = { _ in AsyncStream { $0.finish() } }
        /// Whether the job lets the draft's speakers be named now.
        public var draftNamingOpen: @MainActor (UUID) -> Bool = { _ in false }
        /// Carries out the draft effects of Name a speaker or a suggestion card; false when naming closed meanwhile.
        public var changeDraft: @MainActor (UUID, [NamingEffect]) async -> Bool = { _, _ in false }
        /// The running job's draft as its tracker has it, nil without one.
        public var runningDraft: @MainActor (UUID) -> DraftState? = { _ in nil }
        /// The saved voices, and whether they can be changed now.
        public var savedVoices: @MainActor () -> [SavedVoice] = { [] }
        public var voicesReadOnly: @MainActor () -> Bool = { true }

        public init(note: @escaping @MainActor (UUID) -> Note?, job: @escaping @MainActor (UUID) -> Job?,
                    update: @escaping @MainActor (UUID, @escaping @Sendable (inout Note) -> Void) -> Void,
                    commit: @escaping @MainActor (UUID, @escaping @Sendable (inout Note) -> Void) async -> Note?,
                    markMoment: @escaping @MainActor (UUID, TimeInterval) -> Void,
                    removeBookmark: @escaping @MainActor (UUID, UUID) -> Void,
                    addSpeaker: @escaping @MainActor (UUID, String) -> Void,
                    selectVersion: @escaping @MainActor (UUID, UUID) -> Void,
                    answerSuggestion: @escaping @MainActor (SpeakerSuggestion, UUID, Bool) async throws(VoicesStore.SaveFailure) -> Void,
                    namingInput: @escaping @MainActor (UUID, String) async -> NamingInput?,
                    performNaming: @escaping @MainActor ([NamingEffect], UUID, String) async throws(VoicesStore.SaveFailure) -> Void,
                    transcribe: @escaping @MainActor (UUID, JobKind) async -> TranscribeOutcome,
                    startOver: @escaping @MainActor (UUID) async -> TranscribeOutcome,
                    stop: @escaping @MainActor (UUID) -> Void, dequeue: @escaping @MainActor (UUID) -> Void,
                    continueQueue: @escaping @MainActor () -> Void, clearFailed: @escaping @MainActor (UUID) -> Void,
                    cancelJobDownload: @escaping @MainActor () -> Void,
                    savedDraft: @escaping @MainActor (UUID) async -> [DraftWord],
                    speakerModelsReady: @escaping @MainActor () async -> Bool,
                    ownsPlayer: @escaping @MainActor (UUID) -> Bool, play: @escaping @MainActor () -> Void,
                    playFrom: @escaping @MainActor (Note, TimeInterval) -> Void,
                    showPlayer: @escaping @MainActor (Note, PlaybackOwner) -> Void,
                    leavePlayer: @escaping @MainActor (PlaybackOwner) -> Void,
                    playerBlocked: @escaping @MainActor () -> Bool,
                    recording: @escaping @MainActor () -> Bool,
                    exportTranscript: @escaping @MainActor (UUID, TranscriptFormat) async throws(ExportError) -> URL,
                    copyAudio: @escaping @MainActor (UUID) async throws(ExportError) -> URL,
                    exportDocument: @escaping @MainActor (UUID) async throws -> URL,
                    discardExport: @escaping @MainActor (URL) -> Void,
                    trash: @escaping @MainActor (UUID) async -> Void,
                    session: @escaping @MainActor (UUID) -> NoteSession, isOpen: @escaping @MainActor (UUID) -> Bool,
                    markStarted: @escaping @MainActor (UUID) -> Void,
                    openModelDownload: @escaping @MainActor (UUID) -> Void,
                    present: @escaping @MainActor (NoteProblem) -> Void) {
            self.note = note; self.job = job; self.update = update; self.commit = commit
            self.markMoment = markMoment; self.removeBookmark = removeBookmark; self.addSpeaker = addSpeaker
            self.selectVersion = selectVersion; self.answerSuggestion = answerSuggestion
            self.namingInput = namingInput; self.performNaming = performNaming
            self.transcribe = transcribe; self.startOver = startOver; self.stop = stop; self.dequeue = dequeue
            self.continueQueue = continueQueue; self.clearFailed = clearFailed; self.cancelJobDownload = cancelJobDownload
            self.savedDraft = savedDraft; self.speakerModelsReady = speakerModelsReady
            self.ownsPlayer = ownsPlayer; self.play = play; self.playFrom = playFrom; self.showPlayer = showPlayer
            self.leavePlayer = leavePlayer; self.playerBlocked = playerBlocked
            self.recording = recording
            self.exportTranscript = exportTranscript; self.copyAudio = copyAudio; self.exportDocument = exportDocument
            self.discardExport = discardExport; self.trash = trash
            self.session = session; self.isOpen = isOpen; self.markStarted = markStarted
            self.openModelDownload = openModelDownload; self.present = present
        }
    }

    /// How an Edit passage save ended.
    public enum PassageSave: Hashable, Sendable {
        case saved
        /// The transcript no longer holds the passage as it was opened.
        case changed
        /// A job for the note makes the transcript read-only.
        case locked
    }

    public let noteID: UUID
    public var screen: NoteScreenState
    public var sheet: NoteSheet?
    /// The text typed so far into Name this speaker or Rename, kept with the open sheet.
    public var sheetDraft: String?
    public var shareItem: ShareItem?
    /// A Cassini document is being prepared.
    public private(set) var exportingDocument = false
    public var showBookmarks = false
    /// The saved progress of a stopped, failed, queued or resuming job, for its read-only draft.
    public private(set) var savedDraft: [DraftWord] = []
    @ObservationIgnored private var retainedWords: [DraftWord] = []
    /// The speaker models are installed: Transcribe again says "Speaker names carry over."
    public private(set) var speakerModelsReady = false
    /// The draft's names (`names.json`), while the screen is shown.
    public private(set) var draftNames = DraftNames.empty
    @ObservationIgnored private var namesTask: Task<Void, Never>?
    private struct MappedDraftKey: Equatable {
        var draft: DraftState
        var names: DraftNames
        var voiceNames: [UUID: String]
        var language: String
    }
    @ObservationIgnored private var mappedDraftKey: MappedDraftKey?
    @ObservationIgnored private var mappedDraft: DraftState?
    @ObservationIgnored private(set) var shownDraftBuilds = 0
    /// This screen, as the owner of the player.
    @ObservationIgnored public let playerOwner = PlaybackOwner()
    @ObservationIgnored let ports: Ports
    @ObservationIgnored private var resumeFollow: Task<Void, Never>?
    /// The search kept with the stack was brought back into this screen.
    @ObservationIgnored private var restored = false
    /// The screen is on the stack and shown; a screen that left opens no player.
    @ObservationIgnored private var visible = false

    public init(noteID: UUID, query: String? = nil, ports: Ports) {
        self.noteID = noteID
        self.ports = ports
        screen = NoteScreenState(query: query)
    }

    public var note: Note? { ports.note(noteID) }
    public var job: Job? { ports.job(noteID) }
    /// Why the transcript cannot be changed now (`ReadOnlyReason.of`); every sheet of the screen follows it.
    public var readOnly: ReadOnlyReason? { note.flatMap { ReadOnlyReason.of($0, job: job) } }

    /// The note's transcribe row as the Library's actions menu has it, for Transcribe again's caption ("Adds version
    /// 3. Speaker names carry over."), so both menus say the same.
    public var transcribeAction: TranscribeAction? {
        note.map { LibraryMapping.transcribeAction($0, job: job, voiceModelReady: speakerModelsReady) }
    }

    // MARK: Effects

    public func run(_ effect: NoteEffect?) {
        guard let effect else { return }
        if let opened = NoteSheet(opening: effect, in: note) {
            sheet = opened
            return
        }
        switch effect {
        case .seekAndPlay(let time): seek(time)
        case .transcribe(let kind): Task { follow(await ports.transcribe(noteID, kind)) }
        case .startOver: Task { follow(await ports.startOver(noteID)) }
        case .acknowledgeTrustAndPlay:
            ports.update(noteID) { $0.document?.trustAcknowledged = true }
            if ports.ownsPlayer(noteID) { ports.play() }
        case .continueQueue: ports.continueQueue()
        case .clearFailed: ports.clearFailed(noteID)
        case .toggleStar: ports.update(noteID) { $0.isFavorite.toggle() }
        case .exportTranscript(let format):
            export { ports, id throws(ExportError) in try await ports.exportTranscript(id, format) }
        case .shareAudio: export { ports, id throws(ExportError) in try await ports.copyAudio(id) }
        case .exportDocument: exportDocument()
        case .stop: ports.stop(noteID)
        case .removeFromQueue: ports.dequeue(noteID)
        case .moveToTrash: Task { await ports.trash(noteID) }
        case .nameSpeaker, .openVersions, .openSpeakers, .editPassage, .rename, .documentInfo:
            break // A sheet (above); a passage that is gone opens nothing.
        }
    }

    /// A row of the note's "…" menu.
    public func perform(_ action: NoteMenuAction) {
        guard let note else { return }
        run(screen.menu(action, note: note, job: job, readOnly: readOnly))
    }

    /// A button of a banner over the transcript.
    public func bannerAction(_ action: BannerAction) {
        guard let note else { return }
        run(screen.bannerAction(action, note: note, job: job))
    }

    public func dismiss(_ banner: BannerSpec) {
        guard let note else { return }
        run(screen.dismiss(banner, note: note, job: job))
    }

    /// The question open over the screen was confirmed.
    public func confirmDialog() { run(screen.confirmDialog()) }

    /// A speaker header, a speaker of the Speakers list or a suggestion card's header: Name a speaker, unless the
    /// transcript is read-only (then the screen says why).
    public func speakerTapped(_ speakerID: String) {
        if isDraftSpeaker(speakerID) {
            run(screen.speakerTapped(speakerID, readOnly: ports.draftNamingOpen(noteID) ? nil : .saving))
        } else {
            run(screen.speakerTapped(speakerID, readOnly: readOnly))
        }
    }
    public func versionsTapped() { run(screen.versionsTapped(readOnly: readOnly)) }
    public func speakersTapped() { run(screen.speakersTapped(readOnly: readOnly)) }
    public func editPassage(_ segmentID: UUID) { run(screen.editPassage(segmentID, readOnly: readOnly)) }

    /// "Mark this moment": the bookmark, and the section that lists it open.
    public func markMoment(at time: TimeInterval) {
        ports.markMoment(noteID, time)
        showBookmarks = true
    }

    public func removeBookmark(_ bookmarkID: UUID) { ports.removeBookmark(noteID, bookmarkID) }

    /// The processing card's Stop and keep progress, and the Speakers list's Cancel analysis.
    public func stopJob() { ports.stop(noteID) }
    /// The Queued card's Remove from queue.
    public func removeFromQueue() { ports.dequeue(noteID) }
    /// The processing card's Cancel of the job's model download.
    public func cancelJobDownload() { ports.cancelJobDownload() }

    /// What queuing a job led to (`TranscribeOutcome.followUp`): without consent the open sheet gives way to the
    /// model download screen, which asks over the note; a refusal says why.
    private func follow(_ outcome: TranscribeOutcome) {
        switch outcome.followUp {
        case .openModelDownload:
            sheet = nil
            ports.openModelDownload(noteID)
        case .refused(let refusal): ports.present(.refused(refusal))
        case .none: break
        }
    }

    /// Plays from `time`, unless a recording holds the audio.
    public func seek(_ time: TimeInterval) {
        guard !ports.recording(), let note else { return }
        ports.playFrom(note, time)
    }

    /// Shares the file `file` writes for the note, or says why there is none. The file is removed once the sheet is
    /// done with it.
    private func export(_ file: @escaping @MainActor (Ports, UUID) async throws(ExportError) -> URL) {
        Task {
            do throws(ExportError) { shareItem = shared(try await file(ports, noteID)) }
            catch { ports.present(.export(error)) }
        }
    }

    private func exportDocument() {
        exportingDocument = true
        Task {
            do { shareItem = shared(try await ports.exportDocument(noteID)) }
            catch { ports.present(.documentNotSaved) }
            exportingDocument = false
        }
    }

    private func shared(_ url: URL) -> ShareItem {
        ShareItem(url: url) { [discard = ports.discardExport] in discard(url) }
    }

    // MARK: The screen's sheets

    /// Speakers: whether its speakers and Add a speaker can change the note. Identify speakers waits too while
    /// `readOnly` is `jobPending`, which the list shows with its progress and Cancel analysis.
    public var speakersEditable: Bool { readOnly == nil }

    /// Add a speaker, refused while the transcript is read-only. Returns whether the speaker was added.
    @discardableResult
    public func addSpeaker(named name: String) -> Bool {
        guard readOnly == nil else { return false }
        ports.addSpeaker(noteID, name)
        return true
    }

    /// Identify speakers: a speakers-only job; without consent the sheet gives way to the model download screen.
    public func identifySpeakers() async {
        guard readOnly == nil else { return }
        follow(await ports.transcribe(noteID, .speakersOnly))
    }

    /// Versions: shows the version and closes the sheet.
    public func selectVersion(_ versionID: UUID) {
        ports.selectVersion(noteID, versionID)
        sheet = nil
    }

    /// Edit passage's Save. The change runs again on the stored note when someone else saved it meanwhile; it then
    /// finds the passage gone, and the editor says so.
    public func revisePassage(_ original: TranscriptSegment, to revised: TranscriptSegment,
                              stamp: VersionStamp) async -> PassageSave {
        guard readOnly == nil else { return .locked }
        guard note?.holds(original) == true else { return .changed }
        guard revised != original else { return .saved }
        let saved = await ports.commit(noteID) { _ = $0.revisePassage(original, to: revised, stamp: stamp) }
        return saved?.holds(revised) == true ? .saved : .changed
    }

    /// "Yes, Luca" or "Not Luca" on a suggestion card; nothing while the transcript is read-only. A draft's card answers
    /// in the draft's names (Android's `DraftNames.confirm` and `reject`), while its naming is open.
    public func answer(_ suggestion: SpeakerSuggestion, yes: Bool) async {
        if suggestion.segmentID == NoteTranscripts.draftSegment {
            guard ports.draftNamingOpen(noteID) else { return }
            let effect: NamingEffect = yes
                ? .draftName(speakerID: suggestion.speakerID, name: suggestion.voiceName, voice: .saved(suggestion.voiceID),
                             confirm: true, score: suggestion.score)
                : .reject(speakerID: suggestion.speakerID, voiceID: suggestion.voiceID, voiceName: suggestion.voiceName,
                          unenrol: false, restorePlaceholder: false, draft: true)
            _ = await ports.changeDraft(noteID, [effect])
            return
        }
        guard readOnly == nil else { return }
        do throws(VoicesStore.SaveFailure) {
            try await ports.answerSuggestion(suggestion, noteID, yes)
        } catch {
            ports.present(.speakerNotSaved(error))
        }
    }

    /// The model of Name a speaker for one of the note's speakers, or one of the draft's: its saves then go to the
    /// draft's names, and are refused once the job closed naming.
    public func naming(_ speakerID: String) -> NameSpeakerModel {
        guard isDraftSpeaker(speakerID) else {
            return NameSpeakerModel(noteID: noteID, speakerID: speakerID, ports: .init(
                input: ports.namingInput, perform: ports.performNaming,
                readOnly: { [weak self] in self?.readOnly }))
        }
        let change = ports.changeDraft, open = ports.draftNamingOpen
        return NameSpeakerModel(noteID: noteID, speakerID: speakerID, ports: .init(
            input: { [weak self] _, id in await self?.draftInput(id) },
            perform: { effects, noteID, _ throws(VoicesStore.SaveFailure) in _ = await change(noteID, effects) },
            readOnly: { [noteID] in open(noteID) ? nil : .saving }))
    }

    // MARK: The draft

    /// The draft the screen shows, with its names: the running job's, or the saved progress of a stopped or failed one.
    /// Nil without one.
    public var shownDraft: DraftState? {
        shownDraft(language: DefaultLabels.appLanguage)
    }

    /// The language is part of the key because legacy placeholder labels use the app's language. Keeping this
    /// overload internal lets the key be tested without replacing the process's main localization bundle.
    func shownDraft(language: String) -> DraftState? {
        // Read the observable inputs before checking the cache, preserving SwiftUI's dependency registrations.
        let voiceNames = Dictionary(ports.savedVoices().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let names = draftNames
        let currentJob = ports.job(noteID)
        let currentNote = ports.note(noteID)
        let modeShowsDraft = currentJob.map { job in
            currentNote.map { NoteMode.of($0, job: job).showsDraft } ?? (job.state != .needsConsent)
        } ?? false
        let raw: DraftState
        if let running = ports.runningDraft(noteID) {
            retainedWords = running.words
            raw = running
        } else if modeShowsDraft, !savedDraft.isEmpty {
            raw = DraftState(words: savedDraft, tentativeFromMs: .max, namingOpen: ports.draftNamingOpen(noteID))
        } else if modeShowsDraft, let doneMs = currentJob?.doneMs, doneMs > 0, !retainedWords.isEmpty {
            let kept = retainedWords.filter { $0.endMs <= doneMs }
            guard !kept.isEmpty else {
                mappedDraftKey = nil
                mappedDraft = nil
                return nil
            }
            raw = DraftState(words: kept, tentativeFromMs: .max, namingOpen: ports.draftNamingOpen(noteID))
        } else {
            if !modeShowsDraft { retainedWords = [] }
            mappedDraftKey = nil
            mappedDraft = nil
            return nil
        }
        let key = MappedDraftKey(draft: raw, names: names, voiceNames: voiceNames, language: language)
        if mappedDraftKey != key {
            mappedDraft = DraftView.build(raw, names: names, voiceNames: voiceNames)
            mappedDraftKey = key
            shownDraftBuilds += 1
        }
        return mappedDraft
    }

    /// Whether `speakerID` is a speaker of the draft on screen.
    private func isDraftSpeaker(_ speakerID: String) -> Bool {
        !speakerID.isEmpty && shownDraft?.words.contains { Data($0.speaker.utf8) == Data(speakerID.utf8) } == true
    }

    /// What Name a speaker knows about a draft speaker (Android's `draftInput`): its numbers from the draft's words
    /// (merges applied), its label, its live match, the other draft speakers to merge into, and a print to come once
    /// the voiceprint model is installed.
    func draftInput(_ speakerID: String) async -> NamingInput? {
        guard let draft = shownDraft else { return nil }
        let stats = SpeakerStats.of(words: draft.words.map { Word($0.speaker, $0.startMs, $0.endMs, $0.text) })
        guard let stat = stats.first(where: { Data($0.speakerID.utf8) == Data(speakerID.utf8) }) else { return nil }
        let labels = Dictionary(uniqueKeysWithValues: draft.labels.map { (Data($0.key.utf8), $0.value) })
        let provenance = Dictionary(uniqueKeysWithValues: draft.provenance.map { (Data($0.key.utf8), $0.value) })
        func label(_ stat: SpeakerStat) -> String { labels[Data(stat.speakerID.utf8)] ?? DefaultLabels.placeholder(stat.ordinal + 1) }
        let order = SpeakerColourOrder.earliest(draft.words, id: { $0.speaker }, start: { Double($0.startMs) })
        let fallback = Dictionary(uniqueKeysWithValues: order.enumerated().map { (Data($0.element.utf8), $0.offset) })
        let stored = Dictionary(uniqueKeysWithValues: draft.colourIndices.map { (Data($0.key.utf8), $0.value) })
        let indices = stored.merging(fallback) { stored, _ in stored }
        let targets = stats.filter { Data($0.speakerID.utf8) != Data(speakerID.utf8) && $0.wordCount > 0 }.map {
            MergeTarget(speakerID: $0.speakerID, name: label($0), ordinal: $0.ordinal, speakingTime: $0.speakingTime,
                        colourIndex: indices[Data($0.speakerID.utf8)], provenance: provenance[Data($0.speakerID.utf8)])
        }
        let ready = await ports.speakerModelsReady()
        // A running job holds the audio: no sample plays until it stops.
        let canSample = ports.runningDraft(noteID) == nil && note?.audio.isPlayable == true
        return NamingInput(speakerID: speakerID, label: label(stat), ordinal: stat.ordinal, speakingTime: stat.speakingTime,
                           sample: stat.sample, print: nil, match: draftNames.match(speakerID),
                           voices: ports.savedVoices(), voicesReadOnly: ports.voicesReadOnly(), voiceModelReady: ready,
                           mergeTargets: targets, canSample: canSample, draft: true, willHavePrint: ready,
                           colourIndex: indices[Data(speakerID.utf8)], provenance: provenance[Data(speakerID.utf8)])
    }

    // MARK: Opening

    /// What the screen's player follows (`NotePlayer.key`): nil in a mode without a player (a running job) and while a
    /// recording keeps the player closed. The screen calls `updatePlayer()` when it changes.
    public var playerKey: NotePlayer.Key? {
        guard let note, NoteMode.of(note, job: job).hasPlayer else { return nil }
        return NotePlayer.key(for: note, blocked: ports.playerBlocked())
    }

    /// Opens, reloads or leaves the player for `playerKey`. A screen that left does nothing: it opens no player, and
    /// has none to leave.
    public func updatePlayer() {
        guard visible else { return }
        if let note, playerKey != nil { ports.showPlayer(note, playerOwner) } else { ports.leavePlayer(playerOwner) }
    }

    /// Brings back the search the stack kept for this screen (when SwiftUI built the view again), opens the player,
    /// and runs the Library's start action.
    public func appeared(start: NoteStartAction?) {
        visible = true
        if !restored {
            restored = true
            if let kept = ports.session(noteID).search { screen.search = NoteScreenState(query: kept).search }
        }
        updatePlayer()
        runStart(start)
        Task { speakerModelsReady = await ports.speakerModelsReady() }
        if namesTask == nil {
            let names = ports.draftNames(noteID)
            namesTask = Task { [weak self] in
                for await value in names { self?.draftNames = value }
            }
        }
    }

    /// A fresh Library request can reuse this note's view. Reset its route query and consume the new start action.
    public func reopened(query: String?, start: NoteStartAction?) {
        guard ports.isOpen(noteID) else { return }
        screen.search = NoteScreenState(query: query).search
        runStart(start)
    }

    /// Runs the Library's start action once for the screen: the router remembers that it ran, and a route restored
    /// with the scene carries none. A screen leaving the stack forgets it ran, and runs nothing.
    public func runStart(_ start: NoteStartAction?) {
        guard let start, ports.isOpen(noteID), !ports.session(noteID).started else { return }
        ports.markStarted(noteID)
        run(start.effect)
    }

    /// Reads a stopped, failed, queued or resuming job's saved progress for its draft; a finished note or a job over
    /// an existing transcript shows none.
    public func loadSavedDraft() async {
        let shouldLoad: Bool = if let job {
            note.map { NoteMode.of($0, job: job).showsDraft } ?? (job.state != .needsConsent)
        } else {
            false
        }
        let draft = shouldLoad ? await ports.savedDraft(noteID) : []
        if !Task.isCancelled {
            savedDraft = draft
            if !shouldLoad || draft.isEmpty { retainedWords = draft }
        }
    }

    // MARK: Follow

    /// A drag during playback pauses auto-follow; once the scrolling stops, `PlaybackFollow.resumeAfter` without
    /// scrolling resumes it.
    public func scrolled(_ scrolling: PlaybackFollow.Scrolling, playing: Bool) {
        switch screen.follow.scrolled(scrolling, playing: playing) {
        case .keep: break
        case .cancel: resumeFollow?.cancel()
        case .restart(let delay):
            resumeFollow?.cancel()
            resumeFollow = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                screen.follow.resume()
            }
        }
    }

    /// The Follow playback chip.
    public func resumeFollowing() {
        resumeFollow?.cancel()
        screen.follow.resume()
    }

    /// The screen left: so does its player, and the follow timer stops.
    public func disappeared() {
        visible = false
        ports.leavePlayer(playerOwner)
        resumeFollow?.cancel()
        namesTask?.cancel()
        namesTask = nil
    }
}
