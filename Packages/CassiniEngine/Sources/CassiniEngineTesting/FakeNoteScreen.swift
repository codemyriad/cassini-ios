#if DEBUG
import Foundation
import CassiniEngine
import CassiniNotebook

/// The Note screen's ports over one note and its job held here, recording every call by name (as Android's
/// `FakeNotePorts`): `note` and `job` change what the screen sees, the outcomes and failures are scripted.
@MainActor public final class FakeNoteScreen {
    public var note: Note?
    public var job: Job?
    public private(set) var calls: [String] = []
    public private(set) var problems: [NoteProblem] = []
    /// The writes Name a speaker asked for, in order.
    public private(set) var namingWrites: [[NamingEffect]] = []
    public var transcribeOutcome = TranscribeOutcome.queued(changed: true)
    public var exportResult: Result<URL, ExportError> = .success(URL(fileURLWithPath: "/tmp/export.srt"))
    public var documentFails = false
    public var ownsPlayer = true
    public var recording = false
    public var playerBlocked = false
    public var draft: [DraftWord] = []
    public var session = NoteSession()
    public var isOpen = true
    /// What Name a speaker is given; nil for a speaker that is gone.
    public var namingInput: NamingInput?
    /// Scripted failure of the naming writes.
    public var namingFailure: VoicesStore.SaveFailure?
    /// Holds the naming writes until `releaseNaming()`.
    public var holdsNaming = false
    private var namingRelease: CheckedContinuation<Void, Never>?

    public init(note: Note?) { self.note = note }

    public func releaseNaming() {
        holdsNaming = false
        namingRelease?.resume()
        namingRelease = nil
    }

    public lazy var ports = NoteScreenModel.Ports(
        note: { [unowned self] id in note?.id == id ? note : nil }, job: { [unowned self] _ in job },
        update: { [unowned self] id, change in
            calls.append("update")
            if note?.id == id { change(&note!) }
        },
        commit: { [unowned self] id, change in
            calls.append("commit")
            guard note?.id == id else { return nil }
            change(&note!)
            return note
        },
        markMoment: { [unowned self] _, time in calls.append("markMoment:\(time)") },
        removeBookmark: { [unowned self] _, bookmark in calls.append("removeBookmark:\(bookmark)") },
        addSpeaker: { [unowned self] _, name in calls.append("addSpeaker:\(name)") },
        selectVersion: { [unowned self] _, version in calls.append("selectVersion:\(version)") },
        answerSuggestion: { [unowned self] _, _, yes throws(VoicesStore.SaveFailure) in
            calls.append("answer:\(yes)")
            if let namingFailure { throw namingFailure }
        },
        namingInput: { [unowned self] _, _ in namingInput },
        performNaming: { [unowned self] effects, _, speakerID throws(VoicesStore.SaveFailure) in
            if holdsNaming { await withCheckedContinuation { namingRelease = $0 } }
            calls.append("perform:\(speakerID)")
            namingWrites.append(effects)
            if let namingFailure { throw namingFailure }
        },
        transcribe: { [unowned self] _, kind in
            calls.append("transcribe:\(kind)")
            return transcribeOutcome
        },
        startOver: { [unowned self] _ in
            calls.append("startOver")
            return transcribeOutcome
        },
        stop: { [unowned self] _ in calls.append("stop") }, dequeue: { [unowned self] _ in calls.append("dequeue") },
        continueQueue: { [unowned self] in calls.append("continueQueue") },
        clearFailed: { [unowned self] _ in calls.append("clearFailed") },
        cancelJobDownload: { [unowned self] in calls.append("cancelJobDownload") },
        savedDraft: { [unowned self] _ in
            calls.append("savedDraft")
            return draft
        },
        ownsPlayer: { [unowned self] _ in ownsPlayer }, play: { [unowned self] in calls.append("play") },
        playFrom: { [unowned self] _, time in calls.append("playFrom:\(time)") },
        showPlayer: { [unowned self] note, _ in calls.append("showPlayer:\(note.audioFilename)") },
        leavePlayer: { [unowned self] _ in calls.append("leavePlayer") },
        playerBlocked: { [unowned self] in playerBlocked }, recording: { [unowned self] in recording },
        exportTranscript: { [unowned self] _, format throws(ExportError) in
            calls.append("exportTranscript:\(format)")
            return try exportResult.get()
        },
        copyAudio: { [unowned self] _ throws(ExportError) in
            calls.append("copyAudio")
            return try exportResult.get()
        },
        exportDocument: { [unowned self] _ in
            calls.append("exportDocument")
            if documentFails { throw CocoaError(.fileWriteUnknown) }
            return URL(fileURLWithPath: "/tmp/Weekly sync.opus")
        },
        discardExport: { [unowned self] url in calls.append("discard:\(url.lastPathComponent)") },
        trash: { [unowned self] _ in calls.append("moveToTrash") },
        session: { [unowned self] _ in session }, isOpen: { [unowned self] _ in isOpen },
        markStarted: { [unowned self] _ in
            calls.append("markStarted")
            session.started = true
        },
        openModelDownload: { [unowned self] _ in calls.append("openModelDownload") },
        present: { [unowned self] problem in problems.append(problem) })
}
#endif
