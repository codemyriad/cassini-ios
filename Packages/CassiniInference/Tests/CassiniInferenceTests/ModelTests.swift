import Foundation
import Testing
import CassiniEngine
import CassiniInference

/// Opt-in real-model test. The supplied recording and downloaded weights stay outside source control.
/// `CASSINI_MIN_SPEAKERS` asks for at least that many speakers; `CASSINI_EXPECTED_SPEAKERS` for exactly that many, the
/// figure `docs/validation.md` states for the AMI ES2004a meeting (four).
@Test(.enabled(if: ProcessInfo.processInfo.environment["CASSINI_SPEAKER_AUDIO"] != nil))
func realSpeakerModelRunsAndReusesOfflineCache() async throws {
    let environment = ProcessInfo.processInfo.environment
    let path = try #require(environment["CASSINI_SPEAKER_AUDIO"])
    let analyzer = SpeakerAnalyzer(storage: UnlimitedStorage())
    let url = URL(fileURLWithPath: path)
    let first = try await analyzer.analyze(url: url, allowDownload: true) { _ in }
    #expect(!first.turns.isEmpty)
    let speakers = Set(first.turns.map(\.speakerID)).count
    let minimum = Int(environment["CASSINI_MIN_SPEAKERS"] ?? "1") ?? 1
    print("Detected speaker count: \(speakers); expected at least \(minimum)")
    #expect(speakers >= minimum)
    if let expected = environment["CASSINI_EXPECTED_SPEAKERS"].flatMap(Int.init) {
        #expect(speakers == expected, "the validation figure for this recording")
    }
    #expect(!first.prints.isEmpty)
    #expect(first.turns.allSatisfy { $0.end > $0.start && $0.start >= 0 })
    let second = try await analyzer.analyze(url: url, allowDownload: false) { _ in }
    #expect(Set(first.turns.map(\.speakerID)).count == Set(second.turns.map(\.speakerID)).count)
    #expect(second.prints.allSatisfy { $0.vector.count == 256 && $0.vector.allSatisfy(\.isFinite) })
}

private struct UnlimitedStorage: StorageProbe {
    func availableBytes(at url: URL) -> Int64 { .max }
}
