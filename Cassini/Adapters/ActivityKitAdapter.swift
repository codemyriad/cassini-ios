import ActivityKit
import Foundation
import UIKit
import CassiniEngine
import CassiniNotebook

/// The recording's Live Activity on the Lock Screen and in the Dynamic Island. Requests that ActivityKit refuses
/// (Live Activities turned off) leave the recording as it is.
///
/// - Activities outlive the process: after a crash or a kill the last one still shows a running recording with live
///   buttons. Every activity but the current one is ended at creation (launch), at each start, and, as far as the
///   system allows, when the app is being closed.
/// - Updates and ends reach ActivityKit one after another, in the order they were asked.
@MainActor final class ActivityKitAdapter: LiveActivityPort {
    private typealias RecordingActivity = Activity<RecordingActivityAttributes>
    /// The current activity; it is looked up by id where it is changed.
    private var activityID: String?
    /// The last ActivityKit call asked for; each new one waits for it.
    private var tail: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    init() {
        endOthers()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // Best effort: the process may end first. The next launch ends what is left.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func start(noteID: UUID, _ state: RecordingActivityState) {
        end()
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            activityID = try? RecordingActivity.request(attributes: RecordingActivityAttributes(noteID: noteID),
                                                        content: ActivityContent(state: state, staleDate: nil)).id
        }
        endOthers()
    }

    func update(_ state: RecordingActivityState) {
        guard let activityID else { return }
        serially {
            for activity in RecordingActivity.activities where activity.id == activityID {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    func end() {
        guard let activityID else { return }
        self.activityID = nil
        serially {
            for activity in RecordingActivity.activities where activity.id == activityID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Ends every recording activity but the current one, as it is when the call runs.
    private func endOthers() {
        serially { [weak self] in
            for activity in RecordingActivity.activities where activity.id != self?.activityID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Runs `work` after every call asked for before it.
    private func serially(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
}
