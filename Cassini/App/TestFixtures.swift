#if DEBUG
import Foundation
import AVFoundation
import CassiniNotebook

/// UI automation only. These fixtures never appear in an ordinary installation.
enum TestFixtures {
    static func seed(_ repository: NoteRepository) throws {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        var note = Note(id: id, title: "A quieter kind of productivity", audioFilename: "audio.wav")
        note.duration = 24; note.status = .ready; note.language = "en-US"; note.isFavorite = true
        note.transcript = [
            .init(text: "What if being productive meant paying closer attention, rather than doing more?", start: 0, end: 6, speaker: "Alex"),
            .init(text: "The best ideas usually arrive in the space between things. A walk, a conversation, a moment to pause.", start: 6, end: 14, speaker: "Sam"),
            .init(text: "Let’s protect an hour on Thursday for focused work. No notifications, no meetings. Just room to think.", start: 14, end: 24, speaker: "Alex")
        ]
        note.bookmarks = [.init(time: 14, label: "Make room for focused work")]
        note.waveform = (0..<96).map { Float(0.15 + abs(sin(Double($0) * 0.73)) * 0.55) }
        try repository.save(note)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: repository.audioURL(for: note), settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        memset(buffer.floatChannelData![0], 0, 16_000 * MemoryLayout<Float>.size)
        for _ in 0..<24 { try file.write(from: buffer) }
        var second = Note(title: "Thoughts from the morning walk", createdAt: Date().addingTimeInterval(-86400), audioFilename: "audio.wav")
        second.duration = 24; second.status = .audioOnly; second.waveform = note.waveform
        try repository.save(second)
        try FileManager.default.copyItem(at: repository.audioURL(for: note), to: repository.audioURL(for: second))
    }
}
#endif
