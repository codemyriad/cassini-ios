import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct DefaultLabelsTests {
    // ports: DefaultLabelsTest#placeholdersInEveryLanguageAreDefault
    @Test func placeholdersInEveryLanguageAreDefault() {
        #expect(DefaultLabels.isDefault(id: "spk_1", label: "Speaker 1"))
        #expect(DefaultLabels.isDefault(id: "spk_1", label: "Speaker 12"))
        #expect(DefaultLabels.isDefault(id: "spk_1", label: "Voce 2"))
        for word in ["Intervenant", "Hablante", "Locutor", "Orador"] {
            #expect(DefaultLabels.isDefault(id: "spk_1", label: "\(word) 2"), "\(word)")
        }
        #expect(DefaultLabels.isDefault(id: "diar_x_1", label: "diar_x_1"))
        #expect(DefaultLabels.isDefault(id: "spk_1", label: ""))
        #expect(DefaultLabels.isDefault(id: "spk_1", label: "  "))
        #expect(DefaultLabels.placeholderNumber("Speaker 12") == 12)
        #expect(DefaultLabels.placeholder(3) == "Speaker 3")
    }

    /// D47: a placeholder is written in the user's language, with the glossary's "Speaker {n}"; English in any other.
    @Test func thePlaceholderIsWrittenInTheAppsLanguage() {
        let written = ["en", "it", "fr", "es", "pt-BR", "pt-PT", "de"].map { DefaultLabels.placeholder(3, language: $0) }
        #expect(written == ["Speaker 3", "Voce 3", "Intervenant 3", "Hablante 3", "Locutor 3", "Orador 3", "Speaker 3"])
    }

    // ports: DefaultLabelsTest#namesAreNotDefault
    @Test func namesAreNotDefault() {
        for name in ["Ada Example", "Speaker Ada", "Speaker", "Voce", "speaker 1", "Relatore 1", "Orador Ana", "Locutor"] {
            #expect(!DefaultLabels.isDefault(id: "spk_1", label: name), "\(name)")
        }
    }
}

@Suite struct VoiceStalenessTests {
    typealias F = VoiceFixtures

    /// iOS: a voice with one sample of the current model is current.
    @Test func oneCurrentSampleIsEnough() {
        var voice = F.voice("v", model: "old")
        voice.samples += F.voice("w").samples
        #expect(!VoiceStaleness.isStale(voice, model: F.model))
    }
}

@Suite struct SpeakerSuggestionsTests {
    typealias F = VoiceFixtures

    func note(_ speakers: [NoteSpeaker]) -> Note {
        var note = Note(title: "Call")
        note.speakers = speakers
        note.transcript = [TranscriptSegment(text: "Ciao", start: 0, end: 2, speakerID: "a"),
                           TranscriptSegment(text: "Sì", start: 2, end: 3, speakerID: "b"),
                           TranscriptSegment(text: "Bene", start: 3, end: 5, speakerID: "b")]
        note.refreshSpeakerLabels()
        return note
    }

    // ports: NoteTranscriptsTest#aSuggestionToAForgottenVoiceIsNotShown
    @Test func aSuggestionToAForgottenVoiceIsNotShown() {
        let gone = NoteSpeaker(id: "b", name: "Speaker 2", match: .suggested(voice: F.id("gone"), score: 0.7))
        #expect(SpeakerSuggestions.of(note([NoteSpeaker(id: "a", name: "Anna"), gone]), voices: [F.voice("luca")]).isEmpty)
    }

    @Test func aSuggestionGoesAboveThePlaceholdersFirstPassage() throws {
        let luca = F.voice("luca", "Luca")
        let suggested = NoteSpeaker(id: "b", name: "Speaker 2", match: .suggested(voice: luca.id, score: 0.7))
        let note = note([NoteSpeaker(id: "a", name: "Anna"), suggested])
        let card = try #require(SpeakerSuggestions.of(note, voices: [luca]).first)
        #expect(card.segmentID == note.transcript[1].id)
        #expect(card.voiceName == "Luca")
        #expect(card.label == "Speaker 2")
    }

    @Test func aNamedRejectedOrAutomaticSpeakerHasNoCard() {
        let luca = F.voice("luca", "Luca")
        var rejected = NoteSpeaker(id: "b", name: "Speaker 2", match: .suggested(voice: luca.id, score: 0.7))
        rejected.excludedVoiceIDs = [luca.id]
        let named = NoteSpeaker(id: "b", name: "Bruno", match: .suggested(voice: luca.id, score: 0.7))
        let auto = NoteSpeaker(id: "b", name: "Luca", match: .auto(voice: luca.id, score: 0.9))
        for speaker in [rejected, named, auto] {
            #expect(SpeakerSuggestions.of(note([speaker]), voices: [luca]).isEmpty)
        }
    }
}
