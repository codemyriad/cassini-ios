import Foundation
import Testing
@testable import Cassini

@Suite struct MeetingPhase1CopyTests {
    @Test func generatedMeetingCopyUsesEveryExplicitLocale() {
        #expect(MeetingPhase1Copy.template("library.allMeetings", language: "en") == "All meetings")
        #expect(MeetingPhase1Copy.template("library.allMeetings", language: "it") == "Tutte le riunioni")
        #expect(MeetingPhase1Copy.template("library.allMeetings", language: "fr") == "Toutes les réunions")
        #expect(MeetingPhase1Copy.template("library.allMeetings", language: "es") == "Todas las reuniones")
        #expect(MeetingPhase1Copy.template("library.allMeetings", language: "pt-BR") == "Todas as reuniões")
        #expect(MeetingPhase1Copy.template("library.allMeetings", language: "pt-PT") == "Todas as reuniões")
        #expect(MeetingPhase1Copy.template("library.backToAllMeetings", language: "en") == "Back to all meetings")
        #expect(MeetingPhase1Copy.template("library.backToAllMeetings", language: "it") == "Torna a tutte le riunioni")
        #expect(MeetingPhase1Copy.template("library.backToAllMeetings", language: "fr") == "Retour à toutes les réunions")
        #expect(MeetingPhase1Copy.template("library.backToAllMeetings", language: "es") == "Volver a todas las reuniones")
        #expect(MeetingPhase1Copy.template("library.backToAllMeetings", language: "pt-BR") == "Voltar a todas as reuniões")
        #expect(MeetingPhase1Copy.template("library.backToAllMeetings", language: "pt-PT") == "Voltar a todas as reuniões")
        #expect(MeetingPhase1Copy.template("meeting.find.placeholder", language: "en") == "Find in this meeting")
        #expect(MeetingPhase1Copy.template("meeting.find.placeholder", language: "it") == "Cerca in questa riunione")
        #expect(MeetingPhase1Copy.template("meeting.find.placeholder", language: "fr") == "Rechercher dans cette réunion")
        #expect(MeetingPhase1Copy.template("meeting.find.placeholder", language: "es") == "Buscar en esta reunión")
        #expect(MeetingPhase1Copy.template("meeting.find.placeholder", language: "pt-BR") == "Buscar nesta reunião")
        #expect(MeetingPhase1Copy.template("meeting.find.placeholder", language: "pt-PT") == "Pesquisar nesta reunião")
    }

    @Test func generatedTranscribingCopyUsesEveryExplicitLocale() {
        let locales = ["en", "it", "fr", "es", "pt-BR", "pt-PT"]
        let keys = [
            "common.stop",
            "transcribing.heading",
            "transcribing.eta.minutes.one",
            "transcribing.eta.minutes.other",
            "transcribing.details.a11y",
            "transcribing.stopAndKeepProgress",
            "transcribing.transcriptSoFar",
            "transcribing.step.reading",
            "transcribing.step.preparing",
            "transcribing.step.words",
            "transcribing.step.speakers",
            "transcribing.step.saving",
            "transcribing.stat.timeLeft",
            "transcribing.stat.audioDone",
            "transcribing.stat.audioDoneValue",
            "transcribing.stat.wordsSoFar",
            "transcribing.stat.batteryAtFinish",
            "transcribing.speakerSuggestion",
            "transcribing.speakerSuggestion.no",
            "transcribing.speakerSuggestion.yes",
        ]
        for key in keys {
            for locale in locales {
                let resolved = MeetingPhase1Copy.template(key, language: locale)
                #expect(!resolved.isEmpty && resolved != key, "\(key) in \(locale)")
            }
        }
        // Regional Portuguese distinctions stay separate across pt-BR and pt-PT.
        #expect(MeetingPhase1Copy.template("transcribing.heading", language: "pt-BR") == "Transcrevendo")
        #expect(MeetingPhase1Copy.template("transcribing.heading", language: "pt-PT") == "A transcrever")
        #expect(MeetingPhase1Copy.template("transcribing.step.speakers", language: "pt-BR") == "Locutores e reconhecimento")
        #expect(MeetingPhase1Copy.template("transcribing.step.speakers", language: "pt-PT") == "Oradores e reconhecimento")
        #expect(MeetingPhase1Copy.template("transcribing.step.saving", language: "pt-BR") == "Salvamento")
        #expect(MeetingPhase1Copy.template("transcribing.step.saving", language: "pt-PT") == "Gravação")
        #expect(MeetingPhase1Copy.template("transcribing.stat.batteryAtFinish", language: "pt-BR") == "Bateria ao terminar")
        #expect(MeetingPhase1Copy.template("transcribing.stat.batteryAtFinish", language: "pt-PT") == "Bateria no final")
    }
}
