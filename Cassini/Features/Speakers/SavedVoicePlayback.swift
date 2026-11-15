import Foundation
import CassiniEngine
import CassiniNotebook

/// Built off the UI thread once per saved-voice snapshot, using each referenced meeting's stats once.
struct SavedVoicePlayback: Sendable {
    let source: PlaybackSource
    let savedPosition: Double
    let start: Double
    let end: Double

    /// Include the library snapshot: loading, trashing or replacing meeting audio changes sample resolution.
    struct Snapshot: Hashable {
        let voices: [SavedVoice]
        let notes: [Note]
        let root: URL?
    }

    static func samples(voices: [SavedVoice], notes: [Note], root: URL?) -> [UUID: Self] {
        guard let root else { return [:] }
        let referenced = Set(voices.flatMap { $0.samples.filter { $0.guidedEnrollment != true }.map(\.noteID) })
        let notes = notes.filter { $0.trashedAt == nil && referenced.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        let stats = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, SpeakerStats.of($0.transcript)) })
        var result: [UUID: Self] = [:]
        for voice in voices {
            for sample in voice.samples {
                if sample.guidedEnrollment == true {
                    let url = root.appendingPathComponent("PrivateVoices/Enrollment/\(voice.id.uuidString).caf")
                    if FileManager.default.fileExists(atPath: url.path) {
                        result[voice.id] = Self(source: PlaybackSource(noteID: voice.id, url: url, title: voice.name), savedPosition: 0, start: 0,
                                               end: min(10, sample.print.speechSeconds))
                        break
                    }
                } else if let note = byID[sample.noteID], note.audio.isPlayable,
                          let window = stats[note.id]?.first(where: { $0.speakerID == sample.print.speakerID })?.sample {
                    let url = root.appendingPathComponent(note.id.uuidString).appendingPathComponent(note.audioFilename)
                    result[voice.id] = Self(source: PlaybackSource(noteID: note.id, url: url, title: voice.name),
                                           savedPosition: note.playbackPosition, start: window.start, end: window.end)
                    break
                }
            }
        }
        return result
    }
}
