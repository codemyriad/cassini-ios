import Foundation
import Observation
import CassiniNotebook

/// While recording: the capture's events, the storage and length policy checked each second, and the title written
/// as it is typed.
///
/// Touches: `titleWrite`, and reads `captureURL`; the state only through `setState`, `addLevel` and `publishActivity`.
extension RecordingController {
    func startPolicy() {
        // Capture only the scheduler across suspension. Unwrapping a weak controller before an
        // unbounded async method would keep it alive for the lifetime of the policy loop.
        let clock = parts.clock, interval = parts.timing.tick
        policy = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                if tick() {
                    // A new operation: the end cancels this loop.
                    serialized { await self.end(.space, title: nil) }
                    return
                }
                // The strong reference ends with this iteration, before the next sleep.
            }
        }
    }

    /// One policy decision; true when it asks to stop for space.
    func tick() -> Bool {
        guard var active = state.activeRecording, let url = captureURL else { return false }
        active.elapsed = parts.capture.elapsed
        let check = policyCheck(elapsed: active.elapsed, at: url)
        active.space = check.space
        if case .storageLow(let minutes) = check.decision {
            active.warning = .lowStorage(minutesLeft: Int(minutes))
        } else {
            active.warning = nil
        }
        setState(.active(active))
        publishActivity()
        return check.decision == .stopForSpace
    }

    func policyCheck(elapsed: TimeInterval, at url: URL) -> (decision: RecordingPolicy.Decision, space: RecordingSpace) {
        RecordingPolicy.check(usableBytes: parts.storage.availableBytes(at: url.deletingLastPathComponent()),
                              fileBytes: parts.capture.fileBytes, elapsedMs: Int64(elapsed * 1000))
    }

    func handle(_ event: CaptureEvent) {
        guard var active = state.activeRecording else { return }
        switch event {
        case .level(let level):
            guard active.pause == nil else { return }
            addLevel(level)
        case .interrupted, .routeLost:
            // A user pause stays a user pause; the end of the interruption does not resume.
            guard active.pause == nil else { return }
            parts.capture.pause()
            active.pause = event == .interrupted ? .otherApp : .routeLost
            active.elapsed = parts.capture.elapsed
            setState(.active(active))
            publishActivity()
        case .failed, .mediaReset:
            serialized { await self.end(.microphone, title: nil) }
        }
    }

    func scheduleTitleWrite(for noteID: UUID) {
        titleWrite?.cancel()
        let debounce = parts.timing.titleDebounce, clock = parts.clock
        titleWrite = Task { [weak self] in
            do { try await clock.sleep(for: debounce) } catch { return }
            guard !Task.isCancelled, let self, let active = state.activeRecording, active.noteID == noteID,
                  let title = NoteTitles.clean(active.title) else { return }
            _ = try? await parts.notes.update(noteID) { $0.title = title }
            publishActivity()
        }
    }
}
