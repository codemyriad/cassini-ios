import Foundation
import Testing
import CassiniNotebook
@testable import Cassini

private let minute: Int64 = 60_000
private let mebibyte: Int64 = 1_048_576

/// The arguments of the board copy for each kind that reads arguments.
private let boardArgs: [BannerKind: BannerArgs] = [
    .recStorageLow: BannerArgs(ms1: 10 * minute + 20_000),
    .recStoppedStorage: BannerArgs(bytes: 200 * mebibyte),
    .recovered: BannerArgs(count: 1, ms1: 5 * minute + 12_000),
    .txPaused: BannerArgs(ms1: 12 * minute + 40_000, ms2: 34 * minute + 12_000),
    .txQueueHeld: BannerArgs(count: 2),
    .txFailed: BannerArgs(text: "The audio could not be decoded."),
    .dlDownloading: BannerArgs(bytes: 296 * mebibyte, bytes2: 640 * mebibyte, percent: 46, part: .speech),
    .dlChecking: BannerArgs(percent: 80),
    .dlNoSpace: BannerArgs(bytes: 860 * mebibyte),
    .libNoMatch: BannerArgs(text: "fattura"),
    .importing: BannerArgs(text: "call.m4a"),
    .importNoSpace: BannerArgs(bytes: 1_500_000_000),
    .notesUnreadable: BannerArgs(count: 2),
]

private func args(_ kind: BannerKind) -> BannerArgs { boardArgs[kind] ?? BannerArgs() }

/// The English copy of every kind with its board arguments: title, body and action labels.
private let english: [BannerKind: (String, String?, [String])] = [
    .trustVerified: ("Verified", "Audio matches the transcript exactly. Everything works.", []),
    .trustNotVerified: ("Not verified", "The audio could not be checked, so word timing may be off.", ["Play anyway"]),
    .trustAudioChanged: ("Audio changed since transcription", "Word timing may not match what you hear.", ["Transcribe again"]),
    .trustUnreadable: ("Transcript can’t be read", "The file’s Cassini data is damaged. The audio still plays.", ["Transcribe again"]),
    .trustNewerFormat: ("Newer Cassini format", "This version can’t be read here yet. The audio still plays.", []),
    .plainAudio: ("Plain audio", "No transcript yet.", ["Transcribe"]),
    .unplayable: ("This recording can’t be played",
                  "Cassini closed before the recording was saved. You can still save the file.", []),
    .recPausedOtherApp: ("Paused — another app is using audio", "Resume when your call ends. Nothing was lost.", ["Resume"]),
    .recInputLost: ("Paused — audio input disconnected", "Check your microphone, then resume. Nothing was lost.", ["Resume"]),
    .recStorageLow: ("Storage almost full — about 10 min left",
                     "Free some space to keep going. If it runs out, the recording saves automatically.", []),
    .recStoppedStorage: ("Stopped — storage almost full", "Less than 200 MB free. The recording so far is saved.", ["Open note"]),
    .recMicOff: ("Microphone access is off", "Turn it on in system settings. Recording starts when you come back.",
                 ["Open settings"]),
    .recMicFailed: ("Microphone stopped working", "Recording ended. The audio so far is in your library.", ["Open note"]),
    .recCouldNotStart: ("Couldn’t start the microphone", "Another app may be using it. Try again.", ["Try again"]),
    .recovered: ("1 recording recovered", "Cassini closed unexpectedly. We saved what was captured (05:12).", ["Open"]),
    .recCompressionFailed: ("Saved in its original quality", "Compression could not finish. Your recording is safe.", []),
    .txPaused: ("Paused at 12:40 of 34:12", "Pick up where you left off. The draft so far is kept.", ["Resume", "Start over"]),
    .txPausedEarly: ("Paused before any words were found", "Resume to start transcribing.", ["Resume"]),
    .txQueueHeld: ("Transcription paused · 2 waiting", "Continue when you’re ready.", ["Continue"]),
    .txCalculating: ("Calculating time left…", "An estimate appears after the first few minutes of audio.", []),
    .txBattery: ("Measuring battery use…", "Plugged in — no battery estimate needed.", []),
    .txOneVoice: ("All words shown as one voice", "Speakers couldn’t be told apart in this recording.", ["Transcribe again"]),
    .txCheckpointMismatch: ("Saved progress no longer matches", "The recording or models changed. Your recording is kept.",
                            ["Start over"]),
    .txFailed: ("Couldn’t transcribe", "The audio could not be decoded. Your recording is kept.", ["Try again"]),
    .dlDownloading: ("Downloading speech recognition — 46%", "296 of 640 MB.", ["Cancel"]),
    .dlChecking: ("Checking files — 80%", "Each file is verified before it is used.", []),
    .dlNoConnection: ("No connection", "Connect to the internet and try again. Recording still works.", ["Retry"]),
    .dlStopped: ("Download stopped", "The connection dropped. Try again to continue where it stopped.", ["Retry"]),
    .dlNoSpace: ("Not enough storage", "Free about 860 MB and try again.", ["Retry"]),
    .dlFileCheck: ("File check failed", "The download was damaged and has been discarded.", ["Download again"]),
    .dlInstallFailed: ("Couldn’t finish installing", "Try again. Your recordings are safe.", ["Try again"]),
    .dlRecordNow: ("Record now, transcribe later", "Transcription needs a one-time download. Audio is safe meanwhile.",
                   ["Download"]),
    .libEmpty: ("No notes yet", "Record something, or import an audio file.", ["Record", "Import"]),
    .libNoMatch: ("Nothing matches “fattura”", "Try another word or title.", []),
    .importing: ("Importing call.m4a…", nil, []),
    .importTooLarge: ("File too large", "Choose a file under 4 GB.", ["Choose another"]),
    .importNoSpace: ("Not enough space to import", "This file needs about 1.4 GB free. Free some space and try again.",
                     ["Try again"]),
    .importOpen: ("Can’t open this file", "It doesn’t look like audio Cassini can read.", ["Choose another"]),
    .notificationsOff: ("Notifications are off", "Progress shows only in the app.", ["Turn on"]),
    .voicesUnreadable: ("Saved voices can’t be read",
                        "They were made by a newer Cassini or are damaged. Nothing was changed.", []),
    .libUnavailable: ("Your notes can’t be opened", "Your files are kept. Free some storage, then open Cassini again.", []),
    .notesUnreadable: ("2 notes can’t be read", "Their files are kept on this device.", []),
]

/// A value of each `BannerArgs` field that differs from the default, to check `BannerKind.uses`.
private func vary(_ args: BannerArgs, _ arg: BannerArg) -> BannerArgs {
    var args = args
    switch arg {
    case .count: args.count = 7
    case .text: args.text = "x.wav"
    case .ms1: args.ms1 = 62 * minute + 3_000
    case .ms2: args.ms2 = 83 * minute
    case .bytes: args.bytes = 5_000_000_000
    case .bytes2: args.bytes2 = 950 * mebibyte
    case .percent: args.percent = 37
    case .part: args.part = .voices
    case .bySystem: args.bySystem = true
    }
    return args
}

/// The banner catalogue in English: every kind with its board copy (the app runs its tests in English).
@MainActor @Suite struct BannerCopyTests {
    // ports: BannerKindTest#everyKindHasItsBoardCopy
    @Test func everyKindHasItsBoardCopy() {
        #expect(Set(english.keys) == Set(BannerKind.allCases))
        for kind in BannerKind.allCases {
            guard let (title, body, actions) = english[kind] else { continue }
            #expect(BannerCopy.title(kind, args(kind)) == title, "\(kind)")
            #expect(BannerCopy.body(kind, args(kind), locale: Locale(identifier: "en_US")) == body, "\(kind)")
            #expect(kind.actions.map(BannerCopy.action) == actions, "\(kind)")
        }
    }

    // ports: BannerKindTest#variantsOfTheCopy
    @Test func variantsOfTheCopy() {
        #expect(BannerCopy.body(.txFailed, BannerArgs()) == "Your recording is kept.")
        #expect(BannerCopy.body(.plainAudio, BannerArgs()) == "No transcript yet.")
        #expect(BannerCopy.body(.plainAudio, BannerArgs(text: "Too long.")) == "Too long.")
        let paused = "iOS ended the time Cassini had in the background. Resume to continue where it stopped."
        #expect(BannerCopy.body(.txPaused, BannerArgs(bySystem: true)) == paused)
        #expect(BannerCopy.body(.txPausedEarly, BannerArgs(bySystem: true)) == paused)
        #expect(BannerCopy.body(.dlStopped, BannerArgs(bySystem: true))
                == "iOS stopped the download. Try again to continue where it stopped.")
        #expect(BannerCopy.title(.recovered, BannerArgs(count: 3)) == "3 recordings recovered")
        #expect(BannerCopy.title(.dlDownloading, BannerArgs(bytes: 31 * mebibyte, bytes2: 62 * mebibyte, part: .speakers))
                == "Downloading speaker separation — 50%")
        #expect(BannerCopy.title(.txPaused, BannerArgs(ms1: 62 * minute + 3_000, ms2: 83 * minute)) == "Paused at 1:02:03 of 1:23:00")
        #expect(BannerCopy.body(.dlDownloading, BannerArgs(percent: 46)) == nil, "Apple's assets report no bytes")
        #expect(BannerCopy.title(.recStorageLow, BannerArgs(ms1: 10_000)) == "Storage almost full — about 1 min left")
        #expect(BannerCopy.title(.notesUnreadable, BannerArgs(count: 1)) == "1 note can’t be read")
    }

    // ports: BannerKindTest#usesListsExactlyTheArgumentsTheCopyReads
    @Test func usesListsExactlyTheArgumentsTheCopyReads() {
        for kind in BannerKind.allCases {
            let base = BannerArgs()
            let text = [BannerCopy.title(kind, base), BannerCopy.body(kind, base)]
            for arg in BannerArg.allCases {
                let varied = vary(base, arg)
                let other = [BannerCopy.title(kind, varied), BannerCopy.body(kind, varied)]
                if kind.uses.contains(arg) {
                    #expect(text != other, "\(kind) should read \(arg)")
                } else {
                    #expect(text == other, "\(kind) should not read \(arg)")
                }
            }
        }
    }

    // ports: BannerKindTest#noPlaceholderIsLeft
    @Test func noPlaceholderIsLeft() {
        let placeholder = /%(\d+\$)?(@|l*d)/
        for kind in BannerKind.allCases {
            for args in [BannerArgs(), args(kind)] {
                let title = BannerCopy.title(kind, args)
                #expect(!title.contains(placeholder), "\(kind) title: \(title)")
                if let body = BannerCopy.body(kind, args) { #expect(!body.contains(placeholder), "\(kind) body: \(body)") }
            }
        }
        for action in BannerAction.allCases { #expect(!BannerCopy.action(action).isEmpty) }
    }

    /// The Italian copy is Android's; WP14 checks the whole table.
    @Test func theItalianTableHasAndroidsCopy() throws {
        let italian = try #require(Bundle.main.path(forResource: "it", ofType: "lproj").flatMap(Bundle.init(path:)))
        let lookup = { (key: String) in italian.localizedString(forKey: key, value: nil, table: "Notices") }
        #expect(lookup("Verified") == "Verificata")
        #expect(lookup("Play anyway") == "Riproduci comunque")
        #expect(lookup("Paused at %@ of %@") == "In pausa a %@ di %@")
        #expect(lookup("Nothing matches “%@”") == "Nessun risultato per “%@”")
        #expect(BannerCopy.body(.importNoSpace, BannerArgs(bytes: 1_500_000_000), locale: Locale(identifier: "it_IT"))?
                    .contains("1,4 GB") == true)
    }
}
