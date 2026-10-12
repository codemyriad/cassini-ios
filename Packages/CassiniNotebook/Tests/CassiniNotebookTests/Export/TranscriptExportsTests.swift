import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

struct TranscriptExportsTests {
    private let texts = ExportTexts(subtitle: { _, durationMs, speakers in "sub \(durationMs) \(speakers)" },
                                    emptyText: "No words were found in this recording.", unassignedLabel: "Unknown speaker")

    private func note(_ segments: [TranscriptSegment], speakers: [NoteSpeaker] = []) -> Note {
        var note = Note(title: "Consegna: giovedì?")
        note.duration = 12.5; note.status = .ready; note.transcript = segments; note.speakers = speakers
        return note
    }

    @Test func timedWordsKeepTheirSpeakersAndTimesInCanonicalOrder() {
        let segments = [
            TranscriptSegment(text: "Sì, certo.", start: 0, end: 0.9, speakerID: "S1",
                              words: [.init(text: " Sì,", start: 0, end: 0.3), .init(text: "certo.", start: 0.4, end: 0.9)]),
            TranscriptSegment(text: "Bene.", start: 0.8, end: 1.2, speakerID: "S2", words: [.init(text: "Bene.", start: 0.8, end: 1.2)])
        ]
        let export = ExportTranscript(note: note(segments, speakers: [.init(id: "S1", name: "Giulia"), .init(id: "S2", name: "Speaker 2")]),
                                      unassignedLabel: "?")
        #expect(export.words == [Word("S1", 0, 300, "Sì,"), Word("S1", 400, 900, "certo."), Word("S2", 800, 1200, "Bene.")])
        #expect(export.labels["S1"] == "Giulia")
        #expect(export.durationMs == 12_500)
        #expect(export.title == "Consegna: giovedì?")
    }

    @Test func anEditedPassageSharesItsSpanAmongItsWords() {
        let segments = [TranscriptSegment(text: "Testo  corretto\na mano", start: 2, end: 9.5, speakerID: "S1")]
        let export = ExportTranscript(note: note(segments), unassignedLabel: "?")
        #expect(export.words == [Word("S1", 2_000, 4_083, "Testo"), Word("S1", 4_083, 7_416, "corretto"),
                                 Word("S1", 7_416, 7_833, "a"), Word("S1", 7_833, 9_500, "mano")])
        #expect(SrtWriter.write(export) == """
            1
            00:00:02,000 --> 00:00:07,833
            Testo corretto a

            2
            00:00:07,833 --> 00:00:09,500
            mano

            """)
    }

    @Test func aLongEditedPassageIsCutIntoCuesLikeATimedOne() {
        let text = (1...30).map { "parola\($0)" }.joined(separator: " ")
        #expect(text.utf16.count > SubtitleCues.maxText)
        let export = ExportTranscript(note: note([TranscriptSegment(text: text, start: 1, end: 21, speakerID: "S1")]),
                                      unassignedLabel: "?")
        #expect(export.words.count == 30)
        #expect(zip(export.words, export.words.dropFirst()).allSatisfy { $0.endMs == $1.startMs && $0.startMs < $1.startMs })
        let cues = SubtitleCues.build(export, labelPrefixForSrt: true)
        #expect(cues.count > 1)
        #expect(cues.map(\.text).joined(separator: " ") == text)
        for cue in cues {
            #expect(cue.endMs - cue.startMs <= SubtitleCues.maxSpanMs)
            #expect(cue.text.utf16.count <= SubtitleCues.maxText)
            #expect(cue.lines.allSatisfy { $0.utf16.count <= SubtitleCues.lineLength }, "\(cue.lines)")
        }
    }

    @Test func passagesWithoutASpeakerAreLabelledAsUnknown() throws {
        let segments = [
            TranscriptSegment(text: "Ciao", start: 0, end: 1, speakerID: "S1", words: [.init(text: "Ciao", start: 0, end: 1)]),
            TranscriptSegment(text: "Chi parla?", start: 3, end: 4)
        ]
        let text = String(decoding: try TranscriptExports.data(note(segments, speakers: [.init(id: "S1", name: "Giulia")]),
                                                                format: .text, texts: texts), as: UTF8.self)
        #expect(text == "Consegna: giovedì?\nsub 12500 2\n\n[00:00] Giulia\nCiao\n\n[00:03] Unknown speaker\nChi parla?\n")
    }

    @Test func aListedSpeakerWithoutWordsIsNotCounted() throws {
        let segments = [TranscriptSegment(text: "Ciao", start: 0, end: 1, speakerID: "S1", words: [.init(text: "Ciao", start: 0, end: 1)])]
        let speakers: [NoteSpeaker] = [.init(id: "S1", name: "Giulia"), .init(id: "S2", name: "Marco")]
        let text = String(decoding: try TranscriptExports.data(note(segments, speakers: speakers), format: .text, texts: texts),
                          as: UTF8.self)
        #expect(text == "Consegna: giovedì?\nsub 12500 1\n\n[00:00]\nCiao\n")
    }

    @Test func aVersionExportsItsOwnWordsAndNames() throws {
        var source = note([TranscriptSegment(text: "Nuovo", start: 0, end: 1, speakerID: "S1")], speakers: [.init(id: "S1", name: "Anna")])
        let version = TranscriptVersion(name: "Before", segments: [TranscriptSegment(text: "Vecchio", start: 1, end: 2, speakerID: "S1")],
                                        speakers: [.init(id: "S1", name: "Bruno")])
        source.versions = [version]
        let vtt = String(decoding: try TranscriptExports.data(source, format: .webVTT, version: version, texts: texts), as: UTF8.self)
        #expect(vtt == "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nVecchio\n")
        let json = try JSONSerialization.jsonObject(with: TranscriptExports.data(source, format: .json, version: version, texts: texts)) as? [String: Any]
        #expect((json?["transcript"] as? [[String: Any]])?.first?["text"] as? String == "Vecchio")
    }

    @Test func aFinishedTranscriptWithoutWordsWritesTheEmptyText() throws {
        let text = String(decoding: try TranscriptExports.data(note([]), format: .text, texts: texts), as: UTF8.self)
        #expect(text == "Consegna: giovedì?\nsub 12500 0\n\nNo words were found in this recording.\n")
        #expect(TranscriptExports.availability(of: note([])) == .available)
    }

    @Test func availabilityFollowsTheTranscriptAndTheDocument() {
        var plain = Note(title: "Audio")
        #expect(TranscriptExports.availability(of: plain) == .afterTranscription)
        plain.status = .failed
        #expect(TranscriptExports.availability(of: plain) == .afterTranscription)
        var recording = note([TranscriptSegment(text: "x", start: 0, end: 1)])
        recording.audio = .live
        #expect(TranscriptExports.availability(of: recording) == .afterTranscription)
        var kept = note([TranscriptSegment(text: "x", start: 0, end: 1)])
        kept.status = .transcribing
        #expect(TranscriptExports.availability(of: kept) == .available)
        for state in [DocumentState.unreadable, .invalidMetadata, .unknownFormat] {
            var document = note([TranscriptSegment(text: "x", start: 0, end: 1)])
            document.document = DocumentInfo(state: state)
            #expect(TranscriptExports.availability(of: document) == .notReadable)
        }
        for state in [DocumentState.ok, .unverified, .staleAudio] {
            var document = note([TranscriptSegment(text: "x", start: 0, end: 1)])
            document.document = DocumentInfo(state: state)
            #expect(TranscriptExports.availability(of: document) == .available)
        }
    }

    @Test func exportsAreUTF8WithoutBOMOrCarriageReturns() throws {
        let segments = [TranscriptSegment(text: "Riga\r\nnuova", start: 0, end: 1, speakerID: "S1")]
        for format in [TranscriptFormat.text, .subtitles, .webVTT] {
            let data = try TranscriptExports.data(note(segments), format: format, texts: texts)
            let text = try #require(String(data: data, encoding: .utf8))
            expectExportShape(text)
        }
    }
}
