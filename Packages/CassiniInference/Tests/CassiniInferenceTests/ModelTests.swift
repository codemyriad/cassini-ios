import Foundation
import Testing
import CassiniInference

/// Opt-in real-model test. The supplied recording and downloaded weights stay outside source control.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CASSINI_SPEAKER_AUDIO"] != nil))
func realSpeakerModelRunsAndReusesOfflineCache() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["CASSINI_SPEAKER_AUDIO"])
    let analyzer = SpeakerAnalyzer()
    let url = URL(fileURLWithPath: path)
    let first = try await analyzer.analyze(url: url, allowDownload: true) { _ in }
    #expect(!first.turns.isEmpty)
    let minimum = Int(ProcessInfo.processInfo.environment["CASSINI_MIN_SPEAKERS"] ?? "1") ?? 1
    print("Detected speaker count: \(Set(first.turns.map(\.speakerID)).count); expected at least \(minimum)")
    #expect(Set(first.turns.map(\.speakerID)).count >= minimum)
    #expect(!first.prints.isEmpty)
    #expect(first.turns.allSatisfy { $0.end > $0.start && $0.start >= 0 })
    let second = try await analyzer.analyze(url: url, allowDownload: false) { _ in }
    #expect(Set(first.turns.map(\.speakerID)).count == Set(second.turns.map(\.speakerID)).count)
    #expect(second.prints.allSatisfy { $0.vector.count == 256 && $0.vector.allSatisfy(\.isFinite) })
}
