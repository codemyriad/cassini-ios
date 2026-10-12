import CassiniNotebook

/// The recording's Lock Screen and Dynamic Island presence.
@MainActor public protocol LiveActivityPort: AnyObject {
    func start(_ state: RecordingActivityState)
    func update(_ state: RecordingActivityState)
    func end()
}
