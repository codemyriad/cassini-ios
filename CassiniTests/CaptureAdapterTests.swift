import AVFoundation
import Testing
import CassiniAudio
import CassiniEngine
@testable import Cassini

/// `AVCaptureAdapter.start` when the recorder's `record()` fails. On a busy simulator it did, after about 30 s, with
/// the recorder's audio queue already delivering input; released unstopped, the recorder ended the app
/// (EXC_BAD_ACCESS in AudioRecorderAQInputCallback). An iOS-only adapter; Android has no counterpart.
@MainActor @Suite struct CaptureAdapterTests {
    /// What happens to the recorders and the session, in order, and what the next recorders' `record()` answers. The
    /// tests run on the main actor; the recorders' deinit writes here too.
    final class Log: @unchecked Sendable {
        var entries: [String] = []
        var answers: [Bool]
        init(answers: [Bool]) { self.answers = answers }
    }

    /// A recorder whose `record()` answers `records`, writing each call to the log, and whether a delegate was still
    /// set when it was stopped and when it went.
    final class FakeRecorder: CaptureRecorder {
        weak var delegate: (any AVAudioRecorderDelegate)?
        var isMeteringEnabled = false
        let currentTime: TimeInterval = 2
        let url: URL
        private let records: Bool
        private let log: Log

        init(url: URL, records: Bool, log: Log) {
            self.url = url; self.records = records; self.log = log
        }

        func record() -> Bool { log.entries.append("record \(records)"); return records }
        func pause() { log.entries.append("pause") }
        func stop() { log.entries.append(delegate == nil ? "stop" : "stop with a delegate") }
        func updateMeters() {}
        func averagePower(forChannel channelNumber: Int) -> Float { -160 }
        deinit { log.entries.append(delegate == nil ? "released" : "released with a delegate") }
    }

    /// An adapter over a session that only logs, whose recorders' `record()` answers the next of the log's answers.
    func adapter(_ log: Log) -> AVCaptureAdapter {
        let session = CaptureSession(requestPermission: { true }, prepare: { log.entries.append("prepare") },
                                     activate: { log.entries.append("activate") },
                                     deactivate: { log.entries.append("deactivate") })
        return AVCaptureAdapter(session: session) { url in
            FakeRecorder(url: url, records: log.answers.isEmpty ? true : log.answers.removeFirst(), log: log)
        }
    }

    let url = URL(fileURLWithPath: "/dev/null/capture.caf")

    @Test func aRecorderThatFailsToRecordIsStoppedWithoutItsDelegateBeforeItGoesAndTheSessionIsGivenBack() async {
        let log = Log(answers: [false])
        let capture = adapter(log)
        await #expect(throws: AudioError.startFailed) { try await capture.start(url: url) }
        #expect(log.entries == ["prepare", "record false", "stop", "released", "deactivate"])
    }

    @Test func aStartAfterAFailedOneRecords() async throws {
        let log = Log(answers: [false, true])
        let capture = adapter(log)
        await #expect(throws: AudioError.startFailed) { try await capture.start(url: url) }
        log.entries = []
        #expect(try await capture.start(url: url) == .pcm48kMono, "the failed recorder is not kept: not busy")
        #expect(log.entries == ["prepare", "record true"])
        #expect(try await capture.stop().duration == 2)
        #expect(log.entries == ["prepare", "record true", "stop with a delegate", "released with a delegate", "deactivate"])
    }
}
