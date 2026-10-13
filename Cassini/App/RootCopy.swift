import Foundation

/// The words of the root view: the empty detail column of the split view (Library table) and the app-wide error
/// alert (Failures table).
enum RootCopy {
    static let chooseRecording = String(localized: "Choose a recording", table: "Library",
                                        comment: "The detail column of the split view before a note is open")
    static let chooseRecordingBody = String(localized: "Pick a recording in your library to read and listen.", table: "Library")
    static let errorTitle = String(localized: "Something needs attention", table: "Failures", comment: "Title of an app-wide error alert")
    static let ok = String(localized: "OK", table: "Failures")
    static let openSettings = String(localized: "Open settings", table: "Failures", comment: "Opens this app's page in Settings")
}
