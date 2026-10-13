import Foundation
import CassiniEngine
import CassiniNotebook

/// The words of speaker naming and saved voices, from the Speakers string table. Android's English copy, with
/// "device" for Android's "phone" (Cassini also runs on iPad).
enum SpeakersCopy {
    // MARK: Name a speaker

    static func speaksFor(_ seconds: Double) -> String {
        String(localized: "Speaks for \(RecordingCopy.compact(seconds)) in this note", table: "Speakers")
    }
    static let playSample = String(localized: "Play a sample of this voice", table: "Speakers")
    static let stopSample = String(localized: "Stop the sample", table: "Speakers")
    static let nameField = String(localized: "Name", table: "Speakers")
    static let voicesRanked = String(localized: "Saved voices, closest first", table: "Speakers")
    static let voices = String(localized: "Saved voices", table: "Speakers")
    static let likely = String(localized: "Likely", table: "Speakers")
    static let showAll = String(localized: "Show all", table: "Speakers")
    static func alreadySaved(_ name: String) -> String { String(localized: "“\(name)” is already a saved voice.", table: "Speakers") }
    static let samePersonQuestion = String(localized: "Is this the same person?", table: "Speakers")
    static let samePerson = String(localized: "Same person", table: "Speakers")
    static let someoneElse = String(localized: "Someone else", table: "Speakers")
    static let answerFirst = String(localized: "Answer the question above first", table: "Speakers")
    static func savedAs(_ name: String) -> String { String(localized: "This voice is saved as “\(name)”.", table: "Speakers") }
    static let renameSavedQuestion = String(localized: "Also rename the saved voice?", table: "Speakers")
    static let renameSaved = String(localized: "Rename saved voice", table: "Speakers")
    static func notName(_ name: String) -> String { String(localized: "Not \(name)?", table: "Speakers") }
    static let remember = String(localized: "Remember this voice on this device", table: "Speakers")

    /// What remembering does: Android's "Future notes will name … automatically" when automatic naming is on.
    static func rememberBody(_ name: String, automatic: Bool) -> String {
        switch (name.isEmpty, automatic) {
        case (false, true):
            String(localized: "Future notes will name \(name) automatically. The voiceprint never leaves this device.", table: "Speakers")
        case (true, true):
            String(localized: "Future notes will name this person automatically. The voiceprint never leaves this device.", table: "Speakers")
        case (false, false):
            String(localized: "Future notes will suggest \(name). The voiceprint never leaves this device.", table: "Speakers")
        case (true, false):
            String(localized: "Future notes will suggest this person. The voiceprint never leaves this device.", table: "Speakers")
        }
    }

    static func rememberReason(_ reason: RememberReason) -> String {
        switch reason {
        case .tooLittleSpeech: tooLittleSpeech
        case .noModel: String(localized: "Recognising saved voices isn’t installed yet.", table: "Speakers")
        case .readOnly: String(localized: "Saved voices can’t be changed now, so this voice can’t be remembered.", table: "Speakers")
        }
    }
    static let tooLittleSpeech = String(localized: "Too little speech to remember this voice.", table: "Speakers")
    static let mergeInto = String(localized: "Merge into…", table: "Speakers")
    static let saveName = String(localized: "Save name", table: "Speakers")
    static let cancel = String(localized: "Cancel", table: "Speakers")
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
        return String(localized: "\(notes) notes", table: "Speakers") + " · "
            + String(localized: "\(speech) confirmed speech", table: "Speakers")
    }
    static func options(_ name: String) -> String { String(localized: "Options for \(name)", table: "Speakers") }
    static let renameMore = String(localized: "Rename…", table: "Speakers")
    static let forgetMore = String(localized: "Forget…", table: "Speakers")
    static func forgetTitle(_ name: String) -> String { String(localized: "Forget \(name)?", table: "Speakers") }
    static let forgetBody = String(localized: "Cassini stops recognising this voice. Names already in your notes stay.", table: "Speakers")
    static let forget = String(localized: "Forget", table: "Speakers")
    static let stale = String(localized: "Name them again in a note to keep recognising them", table: "Speakers")
    static let footnote = String(localized: "To add someone, name a speaker in any note and keep “Remember this voice” on.", table: "Speakers")
    static let forgetEveryoneMore = String(localized: "Forget everyone…", table: "Speakers")
    static let forgetEveryoneTitle = String(localized: "Forget everyone?", table: "Speakers")
    static func forgetEveryoneBody(_ count: Int) -> String {
        String(localized: "Cassini stops recognising all \(count) saved voices and deletes the voiceprints from every note. Names already in your notes stay.", table: "Speakers")
    }
    static let forgetEveryone = String(localized: "Forget everyone", table: "Speakers")
    static let empty = String(localized: "No saved voices yet", table: "Speakers")
    static let unreadableTitle = String(localized: "Saved voices can’t be read", table: "Speakers")
    static let unreadableBody = String(localized: "They were made by a newer Cassini or are damaged. Nothing was changed.", table: "Speakers")
    /// iOS: voiceprints of notes remain although nobody is saved.
    static let forgetAllData = String(localized: "Forget all voice data", table: "Speakers")
    static let forgetAllDataBody = String(localized: "Deletes the voiceprints of every note. Names already in your notes stay.", table: "Speakers")

    // MARK: Speakers of a note (iOS)

    static let speakersTitle = String(localized: "Speakers", table: "Speakers")
    static let peopleInRecording = String(localized: "People in this note", table: "Speakers")
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
    static let noteNotSaved = String(localized: "The note could not be saved. Nothing was changed.", table: "Speakers")
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
