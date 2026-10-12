import Foundation
import Observation

/// The launch work, in the order it runs. Each work package registers its hook in its slot; nothing else may reorder
/// them.
public enum StartupStep: Int, CaseIterable, Comparable, Sendable {
    /// Read the notes.
    case load
    /// Repair captures that were live when Cassini closed.
    case recover
    /// Bring the transcription queue in line with the notes.
    case reconcile
    /// Drop voiceprints of notes that no longer exist.
    case voiceLinks
    /// Delete notes whose days in Recently Deleted are over.
    case purge
    /// Remove stale temporary files and exports.
    case sweep

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct StartupReport: Equatable, Sendable {
    /// Steps in the order they ran.
    public var ran: [StartupStep] = []
    /// Steps whose hook threw, with the error.
    public var failed: [StartupStep: String] = [:]
    public init() {}
}

/// Runs the registered hooks once, step by step, and then is ready. A failing hook is reported and the next step
/// still runs.
@MainActor @Observable
public final class Startup {
    public typealias Hook = @MainActor () async throws -> Void

    @ObservationIgnored private var hooks: [StartupStep: [Hook]] = [:]
    @ObservationIgnored private var waiters: [CheckedContinuation<StartupReport, Never>] = []
    @ObservationIgnored private var isRunning = false
    public private(set) var report: StartupReport?

    public init() {}

    public var isReady: Bool { report != nil }

    /// Adds a hook to `step`; hooks of one step run in the order they were registered.
    public func register(_ step: StartupStep, _ hook: @escaping Hook) {
        precondition(report == nil, "Startup already ran")
        hooks[step, default: []].append(hook)
    }

    @discardableResult
    public func run(onStep: ((StartupStep) -> Void)? = nil) async -> StartupReport {
        if let report { return report }
        if isRunning { return await ready() }
        isRunning = true
        var report = StartupReport()
        for step in StartupStep.allCases {
            onStep?(step)
            for hook in hooks[step] ?? [] {
                do { try await hook() } catch { report.failed[step] = String(describing: error) }
            }
            report.ran.append(step)
        }
        self.report = report
        for waiter in waiters { waiter.resume(returning: report) }
        waiters.removeAll()
        return report
    }

    /// Returns once every step has run.
    public func ready() async -> StartupReport {
        if let report { return report }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
