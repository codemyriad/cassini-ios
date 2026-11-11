#if DEBUG
import UIKit

/// Where UI-test launches keep their library and preferences: a generation folder under CassiniUITests and a
/// preferences suite of the same name, the current one named in the `current` file. A reset starts a new
/// generation, so whatever the app graph before a relaunch inside the app still writes lands in its own folder and
/// suite, not in the next test's.
enum UITestStorage {
    static let base = URL.applicationSupportDirectory.appendingPathComponent("CassiniUITests", isDirectory: true)
    private static let suitePrefix = "io.codemyriad.cassini.ui-tests"
    private static var pointer: URL { base.appendingPathComponent("current") }

    /// The generation to use. A reset on a fresh process removes every generation; a reset inside the running app
    /// keeps the one before it (its graph may still be writing) and removes the older ones. Without a reset the
    /// current generation goes on, as a relaunch to check persistence expects.
    static func generation(reset: Bool, inProcess: Bool) -> (root: URL, suite: String) {
        let manager = FileManager.default
        let current = (try? String(contentsOf: pointer, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reset, let current, !current.isEmpty, manager.fileExists(atPath: base.appendingPathComponent(current).path) {
            return (base.appendingPathComponent(current, isDirectory: true), suite(current))
        }
        let generations = (try? manager.contentsOfDirectory(atPath: base.path))?.filter { $0.hasPrefix("gen-") } ?? []
        for old in generations where !(inProcess && old == current) {
            try? manager.removeItem(at: base.appendingPathComponent(old))
            UserDefaults.standard.removePersistentDomain(forName: suite(old))
        }
        if !inProcess {
            // The library and suite of the launches before generations.
            for item in (try? manager.contentsOfDirectory(atPath: base.path)) ?? [] where !item.hasPrefix("gen-") {
                try? manager.removeItem(at: base.appendingPathComponent(item))
            }
            UserDefaults.standard.removePersistentDomain(forName: suitePrefix)
        }
        let name = "gen-" + UUID().uuidString
        let root = base.appendingPathComponent(name, isDirectory: true)
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(name.utf8).write(to: pointer, options: .atomic)
        return (root, suite(name))
    }

    private static func suite(_ generation: String) -> String { suitePrefix + "." + generation }
}

/// A UI-test launch inside the running app: the test runner opens
/// `cassini://ui-test/relaunch?token=…&arg=…&arg=…` instead of starting the app again, which costs XCTest about five
/// seconds a launch. The app drops its graph and builds a new one from the arguments, as a launch would, and the
/// `launchFinished` marker carries the token once that graph's launch work is done. Only a process launched with
/// `--ui-testing` answers it; a launch that needs a new process (other system arguments, a relaunch to check
/// persistence) is still a launch.
struct UITestRelaunch {
    let arguments: [String]
    let token: String

    init?(url: URL, launchedForUITests: Bool) {
        guard launchedForUITests, url.scheme == "cassini", url.host == "ui-test", url.path == "/relaunch",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value else { return nil }
        self.arguments = items.filter { $0.name == "arg" }.compactMap(\.value)
        self.token = token
        guard arguments.contains("--ui-testing") else { return nil }
    }

    /// Quiets `old` and returns the graph that replaces it.
    @MainActor func graph(replacing old: AppGraph) -> AppGraph {
        old.quietForUITestRelaunch()
        // Whatever UIKit presents outside SwiftUI's tree goes with the old screens, and so does the keyboard.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.rootViewController?.presentedViewController?.dismiss(animated: false) }
        }
        return AppGraph(environment: .uiTesting(arguments: arguments, inProcess: true, token: token))
    }
}

extension AppGraph {
    /// Synthetic growth only, in a process explicitly launched for UI testing.
    func appendUITestDraft(_ url: URL) -> Bool {
        guard environment.launch.marksLaunchFinished, url.scheme == "cassini", url.host == "ui-test",
              url.path == "/append-draft", let clock = environment.draftClock,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == "count" })?.value,
              let count = Int(value), (1...120).contains(count) else { return false }
        clock.grant(count)
        return true
    }

    /// Temporary synthetic-test diagnostic: compare current stored/indexed/projected rows with a stale UI row.
    /// Called only after a UI assertion has already failed; it adds no view observer or rendering dependency.
    func captureUITestLibraryProjection(_ url: URL) -> Bool {
        guard environment.launch.marksLaunchFinished, url.scheme == "cassini", url.host == "ui-test",
              url.path == "/library-projection" else { return false }
        let rows = libraryScreen.content.sections.flatMap(\.rows)
        let notes: [[String: String]] = library.notes.map { note in
            let indexed = libraryScreen.note(note.id)
            return ["id": note.id.uuidString, "title": note.title, "audio": String(describing: note.audio),
                    "meetingTime": String(describing: note.meetingTime),
                    "indexedAudio": String(describing: indexed?.audio),
                    "indexedMeetingTime": String(describing: indexed?.meetingTime)]
        }
        let snapshot: [String: Any] = [
            "root": library.root?.path ?? "nil", "graph": String(describing: ObjectIdentifier(self)),
            "activeID": recording.state.activeRecording?.noteID.uuidString ?? "nil",
            "cardID": libraryScreen.recordingCard?.noteID.uuidString ?? "nil",
            "notes": notes,
            "rows": rows.map { ["id": $0.id.uuidString, "title": $0.title, "status": String(describing: $0.status),
                                  "meetingTime": String(describing: $0.meetingTime), "duration": String($0.duration)] }
        ]
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CassiniUITestLibraryProjection.json")
        do {
            try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination, options: .atomic)
        } catch { assertionFailure("Could not save synthetic UI-test projection: \(error)") }
        return true
    }

    /// Stops what the graph does on its own, so a graph replaced by a relaunch inside the app neither records, plays
    /// nor transcribes beside the new one.
    func quietForUITestRelaunch() {
        if recording.state.inProgress { recording.controller.pause() }
        playback.stop()
        processing.stopAll()
        processing.setVisible(false)
    }
}
#endif
