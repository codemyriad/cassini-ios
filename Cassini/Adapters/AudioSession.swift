import AVFoundation

/// Activates and deactivates the shared audio session off the main thread, one change at a time and in the order they
/// were asked for. `setActive` can block for hundreds of milliseconds (a Bluetooth route), and iOS warns that calling it
/// on the main thread can make the UI unresponsive.
enum AudioSession {
    private static let queue = DispatchQueue(label: "app.codemyriad.cassini.audio-session", qos: .userInitiated)

    /// Activates the session for playback of spoken audio (its category set first, when it changed); `done` runs on the
    /// main actor with the error, if any.
    static func activateForPlayback(_ done: @escaping @MainActor @Sendable ((any Error)?) -> Void) {
        queue.async {
            let result = Result {
                let session = AVAudioSession.sharedInstance()
                if session.category != .playback || session.mode != .spokenAudio {
                    try session.setCategory(.playback, mode: .spokenAudio)
                }
                try session.setActive(true)
            }
            let failure: (any Error)? = if case .failure(let error) = result { error } else { nil }
            Task { @MainActor in done(failure) }
        }
    }

    /// Activates the session as it is set up and waits for it.
    static func activate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do { try AVAudioSession.sharedInstance().setActive(true); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Gives the audio back to other apps, so the audio another app was playing resumes.
    static func deactivate() {
        queue.async { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
