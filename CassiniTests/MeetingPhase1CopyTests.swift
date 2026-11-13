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
}
