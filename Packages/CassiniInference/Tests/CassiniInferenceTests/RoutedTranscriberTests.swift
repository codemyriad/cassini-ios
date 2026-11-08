import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
@testable import CassiniInference

@Suite struct RoutedTranscriberTests {
    @Test func persistedJobsKeepTheirBackendAcrossPreferenceChanges() throws {
        let legacy = FakeTranscriber(.returns([], total: 1), recognizer: .appleSpeech)
        let whistle = FakeTranscriber(.returns([], total: 1), recognizer: .whistle)
        let optedIn = RoutedTranscriber(legacy: legacy, preferred: whistle)
        #expect(optedIn.recognizer == .whistle)
        #expect(try optedIn.forJob(recognizer: nil).recognizer == .appleSpeech)
        #expect(try optedIn.forJob(recognizer: "appleSpeech").recognizer == .appleSpeech)
        #expect(try optedIn.forJob(recognizer: "whistle").recognizer == .whistle)
        let internalOptOut = RoutedTranscriber(legacy: legacy, retained: whistle)
        #expect(internalOptOut.recognizer == .appleSpeech)
        #expect(try internalOptOut.forJob(recognizer: "whistle").recognizer == .whistle)
        let optedOut = RoutedTranscriber(legacy: legacy)
        #expect(throws: TranscriptionError.self) { try optedOut.forJob(recognizer: "whistle") }
        #expect(throws: TranscriptionError.self) { try optedIn.forJob(recognizer: "future-engine") }
    }
}
