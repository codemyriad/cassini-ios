import Foundation
import Observation
import CassiniNotebook

/// The imports of the app (Android `ImportTracker`): the Library's picker and files opened from other apps both start
/// one here, so "Importing <name>…" and the import errors show for either. Imports run side by side; none is dropped.
///
/// A new import clears the last failure ("shown until dismissed or the next import"); a failed one sets it.
@MainActor @Observable public final class ImportTracker {
    /// The display names of the imports that run, in the order they started.
    public private(set) var running: [String] = []
    /// The last import that failed, until it is dismissed or another import starts.
    public private(set) var failure: ImportFailureFact?

    @ObservationIgnored private let clock: any AppClock

    public init(clock: any AppClock) { self.clock = clock }

    /// Runs `body`, the import of the file named `displayName`. The task's value is nil when the import was cancelled
    /// or threw; a throw other than cancellation is shown as "Can't open this file".
    @discardableResult
    public func start(displayName: String,
                      _ body: @escaping @Sendable () async throws -> ImportOutcome) -> Task<ImportOutcome?, Never> {
        running.append(displayName)
        failure = nil
        return Task {
            let outcome: ImportOutcome?
            var failed: ImportFailureKind?
            do {
                outcome = try await body()
                failed = outcome?.failure
            } catch is CancellationError {
                outcome = nil
            } catch {
                outcome = nil
                failed = .cannotOpen
            }
            if let index = running.firstIndex(of: displayName) { running.remove(at: index) }
            if let failed { failure = ImportFailureFact(displayName: displayName, kind: failed, at: clock.now) }
            return outcome
        }
    }

    /// A batch's storage error uses the same localized notice as a single-file import.
    public func recordFailure(_ kind: ImportFailureKind, displayName: String) {
        failure = ImportFailureFact(displayName: displayName, kind: kind, at: clock.now)
    }

    /// The user closed the import error.
    public func dismissFailure() { failure = nil }
}
