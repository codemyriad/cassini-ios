import Foundation
import CassiniNotebook

/// The recording's Lock Screen and Dynamic Island presence.
@MainActor public protocol LiveActivityPort: AnyObject {
    /// Starts the activity of the recording into `noteID`; a tap on it returns to that recording.
    func start(noteID: UUID, _ state: RecordingActivityState)
    func update(_ state: RecordingActivityState)
    func end()
}
