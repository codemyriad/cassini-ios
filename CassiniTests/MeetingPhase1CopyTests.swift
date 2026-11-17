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
        "common.stop",
        "library.allMeetings",
        "library.backToAllMeetings",
        "meeting.find.placeholder",
        "phone.row.resume",
        "player.pause",
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

    /// L-48: Stop replaces Finish on the Recording screen and the Live Activity; Pause and Resume label the side
    /// control. The Italian Stop is "Ferma" (GLOSSARY), never "Interrompi" or the old "Termina".
    @Test func recordingControlCopyComesFromTheSharedCatalog() {
        let expected: [String: [String: String]] = [
            "common.stop": ["en": "Stop", "it": "Ferma", "fr": "Arrêter", "es": "Detener", "pt-BR": "Parar", "pt-PT": "Parar"],
            "player.pause": ["en": "Pause", "it": "Pausa", "fr": "Pause", "es": "Pausar", "pt-BR": "Pausar", "pt-PT": "Pausa"],
            "phone.row.resume": ["en": "Resume", "it": "Riprendi", "fr": "Reprendre", "es": "Reanudar", "pt-BR": "Retomar",
                                 "pt-PT": "Retomar"],
        ]
        for (key, values) in expected {
            for (language, value) in values {
                #expect(MeetingPhase1Copy.template(key, language: language) == value, "\(key) \(language)")
            }
        }
    }

    @Test func generatedTranscribingCopyUsesEveryExplicitLocale() {
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
            for locale in Self.locales {
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

    @Test func rememberBodyFollowsAutomaticNamingSettingAndDeviceIdiomInEveryLocale() {
        #expect(SpeakersCopy.rememberBody("Luca", automatic: false, pad: false, voicesBackedUp: true, language: "en")
                == "Future meetings will suggest Luca. Cassini never uploads the voiceprint; system backups may include it.")
        #expect(SpeakersCopy.rememberBody("", automatic: false, pad: false, voicesBackedUp: true, language: "en")
                == "Future meetings will suggest this person. Cassini never uploads the voiceprint; system backups may include it.")
        #expect(SpeakersCopy.rememberBody("Luca", automatic: false, pad: true, voicesBackedUp: true, language: "en")
                == "Future meetings will suggest Luca. Cassini never uploads the voiceprint; system backups may include it.")
        #expect(SpeakersCopy.rememberBody("", automatic: false, pad: true, voicesBackedUp: true, language: "en")
                == "Future meetings will suggest this person. Cassini never uploads the voiceprint; system backups may include it.")

        #expect(SpeakersCopy.rememberBody("Luca", automatic: false, pad: false, voicesBackedUp: false, language: "en")
                == "Future meetings will suggest Luca. Cassini never uploads the voiceprint and marks it to be left out of iCloud Backup; a direct transfer may still copy it.")
        #expect(SpeakersCopy.rememberBody("", automatic: false, pad: false, voicesBackedUp: false, language: "en")
                == "Future meetings will suggest this person. Cassini never uploads the voiceprint and marks it to be left out of iCloud Backup; a direct transfer may still copy it.")
        #expect(SpeakersCopy.rememberBody("Luca", automatic: false, pad: true, voicesBackedUp: false, language: "en")
                == "Future meetings will suggest Luca. Cassini never uploads the voiceprint and marks it to be left out of iCloud Backup; a direct transfer may still copy it.")
        #expect(SpeakersCopy.rememberBody("", automatic: false, pad: true, voicesBackedUp: false, language: "en")
                == "Future meetings will suggest this person. Cassini never uploads the voiceprint and marks it to be left out of iCloud Backup; a direct transfer may still copy it.")

        #expect(SpeakersCopy.rememberBody("Luca", automatic: true, pad: false, voicesBackedUp: true, language: "en")
                == "Luca is named automatically next time.\nThe voiceprint stays on this iPhone.")
        #expect(SpeakersCopy.rememberBody("", automatic: true, pad: false, voicesBackedUp: true, language: "en")
                == "This person is named automatically next time.\nThe voiceprint stays on this iPhone.")
        #expect(SpeakersCopy.rememberBody("Luca", automatic: true, pad: true, voicesBackedUp: true, language: "en")
                == "Future meetings will name Luca automatically. Cassini never uploads the voiceprint; system backups may include it.")
        #expect(SpeakersCopy.rememberBody("", automatic: true, pad: true, voicesBackedUp: true, language: "en")
                == "Future meetings will name this person automatically. Cassini never uploads the voiceprint; system backups may include it.")
        #expect(SpeakersCopy.rememberBody("Luca", automatic: true, pad: true, voicesBackedUp: false, language: "en")
                == "Future meetings will name Luca automatically. Cassini never uploads the voiceprint and marks it to be left out of iCloud Backup; a direct transfer may still copy it.")
        #expect(SpeakersCopy.rememberBody("", automatic: true, pad: true, voicesBackedUp: false, language: "en")
                == "Future meetings will name this person automatically. Cassini never uploads the voiceprint and marks it to be left out of iCloud Backup; a direct transfer may still copy it.")

        for locale in Self.locales {
            for voicesBackedUp in [true, false] {
                for pad in [false, true] {
                    let suggestedNamed = SpeakersCopy.rememberBody("Luca", automatic: false, pad: pad, voicesBackedUp: voicesBackedUp, language: locale)
                    let suggestedUnnamed = SpeakersCopy.rememberBody("", automatic: false, pad: pad, voicesBackedUp: voicesBackedUp, language: locale)
                    #expect(suggestedNamed.contains("Luca"), "\(locale) pad=\(pad) backedUp=\(voicesBackedUp)")
                    #expect(suggestedNamed.contains("Cassini"), "\(locale) pad=\(pad) backedUp=\(voicesBackedUp): \(suggestedNamed)")
                    #expect(!suggestedNamed.localizedCaseInsensitiveContains("auto"), "\(locale) pad=\(pad): \(suggestedNamed)")
                    #expect(!suggestedUnnamed.localizedCaseInsensitiveContains("auto"), "\(locale) pad=\(pad): \(suggestedUnnamed)")
                    #expect(!suggestedNamed.contains("iPhone"), "\(locale) pad=\(pad): \(suggestedNamed)")
                    #expect(!suggestedUnnamed.contains("iPhone"), "\(locale) pad=\(pad): \(suggestedUnnamed)")
                    #expect(!suggestedNamed.localizedCaseInsensitiveContains("never leaves"), "\(locale): \(suggestedNamed)")
                    if !voicesBackedUp {
                        #expect(suggestedNamed.contains("iCloud"), "\(locale): \(suggestedNamed)")
                    }
                }

                let ipadNamed = SpeakersCopy.rememberBody("Luca", automatic: true, pad: true, voicesBackedUp: voicesBackedUp, language: locale)
                let ipadUnnamed = SpeakersCopy.rememberBody("", automatic: true, pad: true, voicesBackedUp: voicesBackedUp, language: locale)
                #expect(ipadNamed.contains("Luca"), "\(locale): \(ipadNamed)")
                #expect(ipadNamed.contains("Cassini"), "\(locale): \(ipadNamed)")
                #expect(ipadNamed.localizedCaseInsensitiveContains("autom"), "\(locale): \(ipadNamed)")
                #expect(ipadUnnamed.localizedCaseInsensitiveContains("autom"), "\(locale): \(ipadUnnamed)")
                #expect(!ipadNamed.contains("iPhone"), "\(locale): \(ipadNamed)")
                #expect(!ipadUnnamed.contains("iPhone"), "\(locale): \(ipadUnnamed)")
                #expect(!ipadNamed.localizedCaseInsensitiveContains("never leaves"), "\(locale): \(ipadNamed)")
                if !voicesBackedUp {
                    #expect(ipadNamed.contains("iCloud"), "\(locale): \(ipadNamed)")
                }
            }

            let iphoneNamed = SpeakersCopy.rememberBody("Luca", automatic: true, pad: false, language: locale)
            let iphoneUnnamed = SpeakersCopy.rememberBody("", automatic: true, pad: false, language: locale)
            #expect(iphoneNamed == MeetingPhase1Copy.template("speakers.rememberVoice.cardBody.iphone", language: locale)
                        .replacingOccurrences(of: "{name}", with: "Luca"))
            #expect(iphoneUnnamed == MeetingPhase1Copy.template("speakers.rememberVoice.cardBody.iphone.unnamed", language: locale))
            #expect(iphoneNamed.contains("\n") && iphoneNamed.contains("iPhone"))
            #expect(iphoneUnnamed.contains("\n") && iphoneUnnamed.contains("iPhone"))
        }

        let liveSuggest = SpeakersCopy.rememberBody("Luca", automatic: false)
        let liveIPhoneAuto = SpeakersCopy.rememberBody("Luca", automatic: true, pad: false)
        let liveIPadAuto = SpeakersCopy.rememberBody("Luca", automatic: true, pad: true)
        #expect(liveSuggest.contains("Luca") && !liveSuggest.localizedCaseInsensitiveContains("auto") && !liveSuggest.contains("iPhone"))
        #expect(liveIPhoneAuto.contains("Luca") && liveIPhoneAuto.contains("\n") && liveIPhoneAuto.contains("iPhone"))
        #expect(liveIPadAuto.contains("Luca") && liveIPadAuto.localizedCaseInsensitiveContains("autom") && !liveIPadAuto.contains("iPhone"))
    }
}
