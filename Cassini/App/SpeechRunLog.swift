import Foundation
import Synchronization
import os
import CassiniEngine
import CassiniNotebook
import CassiniSherpa

/// One line in the system log when a job starts and one when it ends, with the time it took and Cassini's memory:
/// what a tester reads in Console (subsystem `io.codemyriad.cassini`, category `SpeechRun`) to tell how a recognizer
/// did on a device nobody measured. No title, text or note id is logged. Observes only: it never decides an outcome.
enum SpeechRunLog {
    private static let log = Logger(subsystem: "io.codemyriad.cassini", category: "SpeechRun")
    private static let started = Mutex<[UUID: UInt64]>([:])

    static func diagnostics(base: TranscriptionJob.Diagnostics?) -> TranscriptionJob.Diagnostics {
        .init(started: { job in
            base?.started(job)
            started.withLock { $0[job.noteID] = DispatchTime.now().uptimeNanoseconds }
            let memory = MemorySample.now()
            log.notice("""
                Speech run started; recognizer=\(job.recognizer ?? "legacy", privacy: .public) kind=\(job.kind.rawValue, privacy: .public) \
                resumeMs=\(job.doneMs, privacy: .public) footprintMiB=\(mib(memory.footprintBytes), privacy: .public) \
                availableMiB=\(mib(memory.availableBytes), privacy: .public) \
                physicalMiB=\(mib(ProcessInfo.processInfo.physicalMemory), privacy: .public)
                """)
        }, finished: { job, outcome in
            base?.finished(job, outcome)
            let began = started.withLock { $0.removeValue(forKey: job.noteID) }
            let seconds = began.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1e9 } ?? -1
            let memory = MemorySample.now()
            log.notice("""
                Speech run ended; recognizer=\(job.recognizer ?? "legacy", privacy: .public) outcome=\(String(describing: outcome), privacy: .public) \
                seconds=\(seconds, format: .fixed(precision: 1), privacy: .public) footprintMiB=\(mib(memory.footprintBytes), privacy: .public) \
                peakSinceLaunchMiB=\(mib(memory.peakFootprintBytes), privacy: .public) \
                availableMiB=\(mib(memory.availableBytes), privacy: .public)
                """)
        })
    }

    private static func mib(_ bytes: UInt64) -> Int { Int(bytes >> 20) }
}
