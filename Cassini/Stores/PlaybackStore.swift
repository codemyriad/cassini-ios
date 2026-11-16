import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// The app's one player, by note: finds each note's audio file and hands it to `PlaybackController`, which owns the
/// position, the saves and the samples.
@MainActor @Observable final class PlaybackStore {
    @ObservationIgnored let controller: PlaybackController
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored let seekProbe: PlaybackSeekProbe?
    @ObservationIgnored private var preparation = 0
    @ObservationIgnored private var preparing: Task<Void, Never>?
    @ObservationIgnored private var preparingOwner: PlaybackOwner?
    @ObservationIgnored private let fileSignature: @MainActor (URL) async -> String?

    init(controller: PlaybackController, library: LibraryStore, seekProbe: PlaybackSeekProbe? = nil,
         fileSignature: @escaping @MainActor (URL) async -> String? = { await PlaybackStore.signature(of: $0) }) {
        self.controller = controller; self.library = library; self.seekProbe = seekProbe
        self.fileSignature = fileSignature
    }

    convenience init(playback: any AudioPlayback, library: LibraryStore, preview: NotePreview? = nil) {
        let positions = LibraryPlaybackPositions(library: library, preview: preview)
        self.init(controller: PlaybackController(parts: .init(player: playback, positions: positions)), library: library,
                  seekProbe: (playback as? AVPlaybackAdapter)?.seekProbe)
    }

    var state: PlaybackState { controller.state }
    var controls: PlaybackControls { controller.controls }

    var rate: Float {
        get { controller.rate }
        set { controller.rate = newValue }
    }

    /// Whether `noteID` holds the player and it can play.
    func owns(_ noteID: UUID) -> Bool { controls.noteID == noteID && controls.status != .failed }

    /// Whether the player of `noteID` could not open its file.
    func failed(_ noteID: UUID) -> Bool { controls.noteID == noteID && controls.status == .failed }

    /// While a recording runs the player is closed and nothing opens.
    var isBlocked: Bool { controller.isBlocked }

    /// The Note screen `owner` shows `note`'s player: `PlaybackController.show` with the note's file, which opens it at
    /// the saved position or reloads it when the audio changed (the compressed copy replaced the capture).
    func requestShow(_ note: Note, owner: PlaybackOwner) {
        let request = beginPreparation(owner)
        preparing = Task { await prepare(note, owner: owner, request: request) }
    }

    func show(_ note: Note, owner: PlaybackOwner) async {
        await prepare(note, owner: owner, request: beginPreparation(owner))
    }

    /// Saved voices already has a source. Claim the player before a pending Note file stat can finish.
    func showImmediately(_ source: PlaybackSource, at position: TimeInterval, owner: PlaybackOwner) {
        preparation &+= 1
        preparingOwner = nil
        controller.show(source, at: position, owner: owner)
    }

    private func beginPreparation(_ owner: PlaybackOwner) -> Int {
        preparation &+= 1
        preparingOwner = owner
        return preparation
    }

    private func prepare(_ note: Note, owner: PlaybackOwner, request: Int) async {
        guard preparation == request else { return }
        guard note.audio.isPlayable, let url = library.audioURL(note) else {
            controller.leave(owner)
            return
        }
        let signature = await fileSignature(url)
        guard !Task.isCancelled, preparation == request else { return }
        preparingOwner = nil
        let source = PlaybackSource(noteID: note.id, url: url, title: note.title, signature: signature)
        controller.show(source, at: note.playbackPosition, owner: owner)
    }

    /// The screen `owner` is gone, or its note lost its player (a transcription started).
    func leave(_ owner: PlaybackOwner) {
        if preparingOwner == owner { preparation &+= 1; preparingOwner = nil }
        controller.leave(owner)
    }

    func togglePlayback() { controller.toggle() }
    func play() { controller.play() }
    func pause() { controller.pause() }
    func seek(_ position: TimeInterval) { controller.seek(to: position) }
    func skip(_ seconds: TimeInterval) { controller.skip(by: seconds) }

    /// Plays `note` from `time`, when its player is open.
    func play(_ note: Note, from time: TimeInterval) {
        guard owns(note.id) else { return }
        controller.seek(to: time)
        controller.play()
    }

    /// Plays `start..<end` of `note` (a speaker sample), then goes back to where it was.
    @discardableResult
    func playSample(_ note: Note, from start: TimeInterval, to end: TimeInterval) -> Bool {
        controller.playRange(note.id, from: start, to: end)
    }

    /// Ends a speaker sample early: the position from before returns and playback stays paused.
    func stopSample() {
        if state.sample != nil { controller.pause() }
    }

    /// Closes the player (its note is moving to Recently Deleted), saving the position first.
    func stop() { preparation &+= 1; preparingOwner = nil; controller.leave() }

    /// Closes the player while a recording runs, and keeps it closed until it ends.
    func setBlocked(_ blocked: Bool) {
        if blocked { preparation &+= 1; preparingOwner = nil }
        controller.setBlocked(blocked)
    }

    /// Saves the position (final) without pausing: the app goes to the background.
    func savePosition() { controller.savePosition() }

    /// Waits until every position save asked for so far has been handed to the Library.
    func settle() async {
        await preparing?.value
        await controller.settle()
    }

    /// The size and modification date of the file: a file written again under the same name gets a new one.
    @concurrent private static func signature(of url: URL) async -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(modified)"
    }
}

/// The Library preview of a note at a playback position; nil keeps the stored preview.
typealias NotePreview = @Sendable (Note, TimeInterval) -> String?

/// Playback positions saved to the note through the Library, so the screens show them at once and they are written in
/// order with the note's other edits. A final save also stores the Library preview at that position. A save that
/// fails is dropped without an alert, as on Android: the next one counts.
@MainActor final class LibraryPlaybackPositions: PlaybackPositions {
    private let library: LibraryStore
    private let preview: NotePreview?

    init(library: LibraryStore, preview: NotePreview?) {
        self.library = library; self.preview = preview
    }

    func save(_ noteID: UUID, position: TimeInterval, final: Bool) async {
        let preview = final ? preview : nil
        await library.commit(noteID, reportsFailure: false) { note in
            note.playbackPosition = position
            if let preview, let text = preview(note, position) { note.previewText = text }
        }
    }
}
