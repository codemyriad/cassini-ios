#if canImport(ActivityKit)
import ActivityKit
import Foundation
import CassiniNotebook

/// The recording's Live Activity. This folder is compiled into the app and the widget extension, so both see the same
/// type; `RecordingActivityState` itself lives in CassiniNotebook.
struct RecordingActivityAttributes: ActivityAttributes {
    typealias ContentState = RecordingActivityState
    /// The note being recorded, so a tap opens its recording.
    var noteID: UUID
}
#endif
