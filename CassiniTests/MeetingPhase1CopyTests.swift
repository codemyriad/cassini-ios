import Foundation
import SwiftUI
import Testing
@testable import Cassini

@Suite struct MeetingPhase1CopyTests {
    static let locales = ["en", "it", "fr", "es", "pt-BR", "pt-PT"]
    static let allKeys = [
        "common.cancel",
        "common.quote",
        "common.savedVoices",
        "library.allMeetings",
        "library.backToAllMeetings",
        "meeting.find.placeholder",
        "speakers.dialog.a11y",
        "speakers.duplicate.notice",
        "speakers.duplicate.samePerson",
        "speakers.duplicate.someoneElse",
        "speakers.mergeInto",
        "speakers.nameLabel",
        "speakers.playSample",
        "speakers.rememberVoice.cardBody.iphone",
        "speakers.rememberVoice.cardBody.iphone.unnamed",
        "speakers.rememberVoice.modelsNeeded",
        "speakers.rememberVoice.title",
        "speakers.rememberVoice.tooShort",
        "speakers.saveName",
        "speakers.savedVoices.heading",
        "speakers.savedVoices.likely",
        "speakers.talkTime",
    ]

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

    @Test func speakerPhase1KeysResolveInEveryLocaleAndKeepTwoLineRememberBody() {
        for key in Self.allKeys {
            for locale in Self.locales {
                let value = MeetingPhase1Copy.template(key, language: locale)
                #expect(!value.isEmpty && value != key, "\(key) in \(locale)")
            }
        }
        for locale in Self.locales {
            #expect(MeetingPhase1Copy.template("speakers.rememberVoice.cardBody.iphone", language: locale).contains("\n"))
            #expect(MeetingPhase1Copy.template("speakers.rememberVoice.cardBody.iphone.unnamed", language: locale).contains("\n"))
        }
        #expect(MeetingPhase1Copy.template("speakers.duplicate.notice", language: "en") == "{name} is already a saved voice.")
    }

    @Test func duplicateNoticeStylesOnlyThePlaceholderSpanEvenWhenNameMatchesTemplateWords() {
        for trickyName in ["Sam Rivera", "saved", "{name}"] {
            let notice = SpeakersCopy.duplicateNotice(trickyName, language: "en")
            #expect(String(notice.characters) == "\(trickyName) is already a saved voice.")
            let runs = Array(notice.runs)
            #expect(runs.count == 2)
            #expect(String(notice[runs[0].range].characters) == trickyName)
            #expect(runs[0].swiftUI.font == .subheadline.weight(.semibold))
            #expect(String(notice[runs[1].range].characters) == " is already a saved voice.")
            #expect(runs[1].swiftUI.font == nil)
        }
    }
}
