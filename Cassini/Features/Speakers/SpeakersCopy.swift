import Foundation
import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The words of speaker naming and saved voices: shared Phase 1 copy (`MeetingPhase1Copy`) for Name a speaker and
/// Saved voices' shared keys, and the `Speakers` string table for iOS-specific and remaining speaker flows.
enum SpeakersCopy {
    // MARK: Name a speaker

    static var dialogLabel: String { MeetingPhase1Copy.speakerDialogLabel }

    static func speaksFor(_ seconds: Double) -> String {
        MeetingPhase1Copy.speakerTalkTime(RecordingCopy.compact(seconds))
    }

    static func quoted(_ quote: String) -> String {
        MeetingPhase1Copy.quote(quote)
    }

    static var playSample: String { MeetingPhase1Copy.speakerPlaySample }
    static let stopSample = String(localized: "Stop the sample", table: "Speakers")
    static var nameField: String { MeetingPhase1Copy.speakerNameLabel }
    static var voicesRanked: String { MeetingPhase1Copy.speakerVoicesRanked }
    static var voices: String { MeetingPhase1Copy.savedVoices }
    static var likely: String { MeetingPhase1Copy.speakerLikely }
    static let showAll = String(localized: "Show all", table: "Speakers")

    /// "{name} is already a saved voice." (`speakers.duplicate.notice`), with only the `{name}` placeholder span in
    /// semibold — splitting the template before substitution so a name matching template words never styles surrounding copy.
    static func duplicateNotice(_ name: String, language: String? = nil, bundle: Bundle = .main) -> AttributedString {
        let raw = language.map { MeetingPhase1Copy.template("speakers.duplicate.notice", language: $0, bundle: bundle) }
            ?? MeetingPhase1Copy.speakerDuplicateNoticeTemplate
        return styledTemplate(raw, placeholder: "{name}", value: name)
    }

    static func styledTemplate(_ template: String, placeholder: String, value: String) -> AttributedString {
        guard !placeholder.isEmpty else { return AttributedString(template) }
        var result = AttributedString()
        var remainder = template[...]
        while let range = remainder.range(of: placeholder) {
            if range.lowerBound > remainder.startIndex {
                result += AttributedString(remainder[..<range.lowerBound])
            }
            var emphasized = AttributedString(value)
            emphasized.font = .subheadline.weight(.semibold)
            result += emphasized
            remainder = remainder[range.upperBound...]
        }
        if !remainder.isEmpty {
            result += AttributedString(remainder)
        }
        return result
    }

    static var samePerson: String { MeetingPhase1Copy.speakerSamePerson }
    static var someoneElse: String { MeetingPhase1Copy.speakerSomeoneElse }
    static let answerFirst = String(localized: "Answer the question above first", table: "Speakers")
    static func savedAs(_ name: String) -> String { String(localized: "This voice is saved as “\(name)”.", table: "Speakers") }
    static let renameSavedQuestion = String(localized: "Also rename the saved voice?", table: "Speakers")
    static func renameSavedNotice(_ name: String) -> AttributedString {
        var lead = AttributedString(savedAs(name))
        lead.font = .subheadline.weight(.semibold)
        return lead + AttributedString(" " + renameSavedQuestion)
    }
    static let renameSaved = String(localized: "Rename saved voice", table: "Speakers")
    static let nameBlank = String(localized: "Enter a name.", table: "Speakers", comment: "Rename saved voice: the name field is blank")
    static let save = String(localized: "Save", table: "Speakers", comment: "Rename saved voice: the button that saves the name")
    static func notName(_ name: String) -> String { String(localized: "Not \(name)?", table: "Speakers") }
    static var remember: String { MeetingPhase1Copy.speakerRememberTitle }

    /// What remembering does: the `Speakers` device strings reflecting automatic naming and whether saved voices are
    /// included in backups (`voicesBackedUp`), across both iPhone and iPad.
    static func rememberBody(_ name: String, automatic: Bool, pad: Bool = false, voicesBackedUp: Bool = true,
                             language: String? = nil, bundle: Bundle = .main) -> String {
        if let language {
            let locale = Locale(identifier: language)
            let selected = Bundle.preferredLocalizations(from: bundle.localizations,
                forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"
            let localized = bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
            return deviceRememberBody(name, automatic: automatic, voicesBackedUp: voicesBackedUp,
                                      bundle: localized, locale: locale)
        }
        return deviceRememberBody(name, automatic: automatic, voicesBackedUp: voicesBackedUp)
    }

    private static func deviceRememberBody(_ name: String, automatic: Bool, voicesBackedUp: Bool,
                                           bundle: Bundle? = nil, locale: Locale = .current) -> String {
        switch (name.isEmpty, automatic, voicesBackedUp) {
        case (false, true, true):
            String(localized: "Future meetings will name \(name) automatically. Cassini never uploads the voiceprint; system backups may include it.",
                   table: "Speakers", bundle: bundle, locale: locale)
        case (true, true, true):
            String(localized: "Future meetings will name this person automatically. Cassini never uploads the voiceprint; system backups may include it.",
                   table: "Speakers", bundle: bundle, locale: locale)
        case (false, false, true):
            String(localized: "Future meetings will suggest \(name). Cassini never uploads the voiceprint; system backups may include it.",
                   table: "Speakers", bundle: bundle, locale: locale)
        case (true, false, true):
            String(localized: "Future meetings will suggest this person. Cassini never uploads the voiceprint; system backups may include it.",
                   table: "Speakers", bundle: bundle, locale: locale)
        case (false, true, false):
            String(localized: "Future meetings will name \(name) automatically. Cassini never uploads the voiceprint and marks it to be left out of iCloud Backup; a direct transfer may still copy it.",
                   table: "Speakers", bundle: bundle, locale: locale)
        case (true, true, false):
            String(localized: "Future meetings will name this person automatically. Cassini never uploads the voiceprint and marks it to be left out of iCloud Backup; a direct transfer may still copy it.",
                   table: "Speakers", bundle: bundle, locale: locale)
        case (false, false, false):
            String(localized: "Future meetings will suggest \(name). Cassini never uploads the voiceprint and marks it to be left out of iCloud Backup; a direct transfer may still copy it.",
                   table: "Speakers", bundle: bundle, locale: locale)
        case (true, false, false):
            String(localized: "Future meetings will suggest this person. Cassini never uploads the voiceprint and marks it to be left out of iCloud Backup; a direct transfer may still copy it.",
                   table: "Speakers", bundle: bundle, locale: locale)
        }
    }

    static func rememberReason(_ reason: RememberReason) -> String {
        switch reason {
        case .tooLittleSpeech: tooLittleSpeech
        case .noModel: MeetingPhase1Copy.speakerRememberModelsNeeded
        case .readOnly: String(localized: "Saved voices can’t be changed now, so this voice can’t be remembered.", table: "Speakers")
        }
    }
    static var tooLittleSpeech: String { MeetingPhase1Copy.speakerRememberTooShort }
    static var mergeInto: String { MeetingPhase1Copy.speakerMergeInto }
    static var saveName: String { MeetingPhase1Copy.speakerSaveName }
    static var cancel: String { MeetingPhase1Copy.cancel }
    static let done = String(localized: "Done", table: "Speakers")
    static let nameThisSpeaker = String(localized: "Name this speaker", table: "Speakers")
    static let couldNotSave = String(localized: "Could not save the speaker", table: "Speakers")
    static let ok = String(localized: "OK", table: "Speakers")

    // MARK: Merge

    static func mergeTitle(_ source: String) -> String { String(localized: "Merge \(source) into…", table: "Speakers") }
    static func mergeConfirmTitle(_ source: String, _ target: String) -> String {
        String(localized: "Merge \(source) into \(target)?", table: "Speakers")
    }
    static func mergeConfirmBody(_ source: String, _ target: String, added: Int, shown: Int) -> String {
        String(localized: "Everything \(source) said will be shown as \(target).", table: "Speakers") + " "
            + String(localized: "This adds version \(added); version \(shown) stays available.", table: "Speakers")
    }
    static let merge = String(localized: "Merge", table: "Speakers")

    // MARK: Suggestions

    /// "Is this **Luca**?", with the name in bold.
    static func suggestion(_ name: String) -> AttributedString {
        var bold = AttributedString(name)
        bold.inlinePresentationIntent = .stronglyEmphasized
        let template = String(localized: "Is this \(name)?", table: "Speakers")
        guard let range = template.range(of: name) else { return AttributedString(template) }
        return AttributedString(template[..<range.lowerBound]) + bold + AttributedString(template[range.upperBound...])
    }
    static func yes(_ name: String) -> String { String(localized: "Yes, \(name)", table: "Speakers") }
    static func not(_ name: String) -> String { String(localized: "Not \(name)", table: "Speakers") }

    // MARK: Saved voices

    static let privacy = String(localized: "Voiceprints stay on this device. They are never uploaded or written into shared files — only the names you choose are.", table: "Speakers")
    static func meta(notes: Int, seconds: Double) -> String {
        let speech = SavedVoiceList.roughMinutes(seconds).map(RecordingCopy.hoursMinutes)
            ?? String(localized: "under 1 min", table: "Speakers")
        return SavedVoicesPhase2Copy.meta(meetings: notes, confirmedSpeech: speech)
    }
    static func options(_ name: String) -> String { String(localized: "Options for \(name)", table: "Speakers") }
    static let renameMore = String(localized: "Rename…", table: "Speakers")
    static let forgetMore = String(localized: "Forget…", table: "Speakers")
    static func forgetTitle(_ name: String) -> String { SavedVoicesPhase2Copy.forgetTitle(name) }
    static func forgetBody(_ name: String) -> String { SavedVoicesPhase2Copy.forgetBody(name) }
    static var forget: String { SavedVoicesPhase2Copy.forgetPrimary }
    static var stale: String { SavedVoicesPhase2Copy.stale }
    static var footnote: String { SavedVoicesPhase2Copy.howToAdd }
    static let forgetEveryoneMore = String(localized: "Forget everyone…", table: "Speakers")
    static let forgetEveryoneTitle = String(localized: "Forget everyone?", table: "Speakers")
    static func forgetEveryoneBody(_ count: Int) -> String {
        String(localized: "Cassini stops recognising all \(count) saved voices and deletes the voiceprints from every meeting. Names already in your meetings stay.", table: "Speakers")
    }
    static let forgetEveryone = String(localized: "Forget everyone", table: "Speakers")
    static var empty: String { SavedVoicesPhase2Copy.empty }
    static let unreadableTitle = String(localized: "Saved voices can’t be read", table: "Speakers")
    static let unreadableBody = String(localized: "They were made by a newer Cassini or are damaged. Nothing was changed.", table: "Speakers")
    /// iOS: voiceprints of meetings remain although nobody is saved.
    static let forgetAllData = String(localized: "Forget all voice data", table: "Speakers")
    static let forgetAllDataBody = String(localized: "Deletes the voiceprints of every meeting. Names already in your meetings stay.", table: "Speakers")

    // MARK: Speakers of a meeting (iOS)

    static let speakersTitle = String(localized: "Speakers", table: "Speakers")
    static let peopleInRecording = String(localized: "People in this meeting", table: "Speakers")
    static let speakersFooter = String(localized: "A name applies to every passage of that speaker. Check suggested and automatic names before relying on them.", table: "Speakers")
    static let addSpeaker = String(localized: "Add a speaker", table: "Speakers")
    static let add = String(localized: "Add", table: "Speakers")
    static let identifySpeakers = String(localized: "Identify speakers", table: "Speakers")
    static let cancelAnalysis = String(localized: "Cancel analysis", table: "Speakers")
    static let analysisFooter = String(localized: "Speaker analysis runs on this device and may take several minutes for a long recording. Names you gave stay available in Versions when you analyze again.", table: "Speakers")
    static let analyzeAgainTitle = String(localized: "Analyze speakers again?", table: "Speakers")
    static let analyzeAgain = String(localized: "Analyze again", table: "Speakers")
    static let analyzeAgainBody = String(localized: "This adds a new version. You can go back to the current names in Versions.", table: "Speakers")
    static let auto = String(localized: "auto", table: "Speakers")
    static func mightBe(_ name: String) -> String { String(localized: "Might be \(name)", table: "Speakers") }

    // MARK: Versions

    static let versionsTitle = String(localized: "Versions", table: "Speakers")
    static func version(_ number: Int) -> String { String(localized: "Version \(number)", table: "Speakers") }

    /// Versions' detail line of a transcription: "Transcribed 8 Oct, 9:41 AM · 4,812 words" (Android
    /// `ui_versions_transcribed`).
    static func versionTranscribed(at date: String, words: Int) -> String {
        let count = wordCount(words)
        return String(localized: "Transcribed \(date) · \(count)", table: "Speakers",
                      comment: "Versions: a transcription's date and time, then its word count")
    }

    /// Versions' detail line of a merge: "Speakers merged · from version 1 · 8 Oct, 9:41 AM" (Android
    /// `ui_versions_merged`).
    static func versionMerged(from version: Int, at date: String) -> String {
        String(localized: "Speakers merged · from version \(version) · \(date)", table: "Speakers",
               comment: "Versions: a merge, the version it was made from, and its date and time")
    }

    /// Versions' detail line of any other version: what made it, its date and time and its word count.
    static func versionDetail(_ kind: String, at date: String, words: Int) -> String {
        let count = wordCount(words)
        return String(localized: "\(kind) · \(date) · \(count)", table: "Speakers",
                      comment: "Versions: what made a version (Edited passages, Previous transcript…), its date and time, and its word count")
    }

    /// "4,812 words".
    static func wordCount(_ words: Int) -> String {
        String(localized: "\(words) words", table: "Speakers", comment: "A transcript version's word count")
    }

    /// What made a version, under its number in Versions.
    static func versionKind(_ version: TranscriptVersion) -> String {
        switch version.kind {
        case .transcription: String(localized: "On-device transcription", table: "Speakers")
        case .previous: String(localized: "Previous transcript", table: "Speakers")
        case .beforeSpeakerMerge: String(localized: "Before speaker merge", table: "Speakers")
        case .mergedSpeakers: String(localized: "Speakers merged", table: "Speakers")
        case .beforeSpeakerAnalysis: String(localized: "Before speaker analysis", table: "Speakers")
        case .speakerAnalysis: String(localized: "Speaker analysis", table: "Speakers")
        case .beforePassageEdit: String(localized: "Before passage edit", table: "Speakers")
        case .editedPassages: String(localized: "Edited passages", table: "Speakers")
        case .editedTranscript: String(localized: "Edited transcript", table: "Speakers")
        case .imported:
            if let id = version.portableID {
                String(localized: "Imported · \(id)", table: "Speakers", comment: "A version from an imported Cassini document, with its id")
            } else {
                String(localized: "Imported", table: "Speakers", comment: "A version from an imported Cassini document")
            }
        case .legacy(let name): name
        case .unknown: String(localized: "From a newer Cassini", table: "Speakers",
                              comment: "A version made by a newer build of Cassini, of a kind this one does not know")
        }
    }

    // MARK: Errors

    static let voicesReadOnly = String(localized: "Saved voices can’t be changed now. Nothing was changed.", table: "Speakers")
    static let noteNotSaved = String(localized: "The meeting could not be saved. Nothing was changed.", table: "Speakers")
    static func voiceNotSaved(_ reason: String) -> String {
        String(localized: "The saved voice could not be written: \(reason). Try again.", table: "Speakers")
    }
    /// Why an edit of the saved voices did not happen; nil when it did.
    static func message(_ edit: VoiceEdit) -> String? {
        switch edit {
        case .done: nil
        case .readOnly: voicesReadOnly
        case .invalid: String(localized: "A name needs 1 to 80 characters.", table: "Speakers")
        case .notFound: String(localized: "This saved voice no longer exists.", table: "Speakers")
        case .failed(let reason): voiceNotSaved(reason)
        }
    }
}
