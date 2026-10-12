import ActivityKit
import Foundation
import CassiniEngine
import CassiniNotebook

/// The recording's Live Activity on the Lock Screen and in the Dynamic Island. Requests that ActivityKit refuses
/// (Live Activities turned off) leave the recording as it is.
@MainActor final class ActivityKitAdapter: LiveActivityPort {
    private typealias RecordingActivity = Activity<RecordingActivityAttributes>
    /// The running activity; it is looked up by id where it is changed, off the main actor.
    private var activityID: String?

    func start(noteID: UUID, _ state: RecordingActivityState) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activityID = try? RecordingActivity.request(attributes: RecordingActivityAttributes(noteID: noteID),
                                                    content: ActivityContent(state: state, staleDate: nil)).id
    }

    func update(_ state: RecordingActivityState) {
        guard let activityID else { return }
        Task.detached {
            for activity in RecordingActivity.activities where activity.id == activityID {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    func end() {
        guard let activityID else { return }
        self.activityID = nil
        Task.detached {
            for activity in RecordingActivity.activities where activity.id == activityID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
