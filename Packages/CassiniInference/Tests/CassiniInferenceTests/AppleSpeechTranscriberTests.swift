import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniNotebook
@testable import CassiniInference

struct AppleSpeechTranscriberTests {
    @Test func unavailableHardwareNeverQueriesLocalesOrOffersAnInstall() async throws {
        let calls = Mutex(0)
        let candidate = AppleSpeechTranscriber(probe: .init(isAvailable: { false }, supportedLocale: { _ in
            calls.withLock { $0 += 1 }; return Locale(identifier: "en-US")
        }, assetStatus: { _ in calls.withLock { $0 += 1 }; return .ready }))
        let locale = Locale(identifier: "en-US")
        #expect(await candidate.assetStatus(locale: locale) == .unsupported)
        #expect(await candidate.unavailability(locale: locale) == .model)
        #expect(await candidate.modelName(locale: locale) == nil)
        #expect(await candidate.runLanguage(requested: "en-US") == nil)
        #expect(await candidate.speechLanguages().isEmpty)
        await #expect(throws: TranscriptionError.failed(.model)) {
            try await candidate.installAssets(locale: locale) { _ in Issue.record("offered an unsupported install") }
        }
        await #expect(throws: TranscriptionError.failed(.model)) {
            _ = try await candidate.transcribe(.init(url: URL(fileURLWithPath: "/missing-audio"), language: "en-US", allowDownload: true)) { _ in
                Issue.record("started unsupported transcription")
            }
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func unsupportedLocaleIsNotMistakenForADownload() async throws {
        let calls = Mutex(0)
        let candidate = AppleSpeechTranscriber(probe: .init(isAvailable: { true }, supportedLocale: { _ in nil },
            assetStatus: { _ in calls.withLock { $0 += 1 }; return .notDownloaded }))
        let locale = Locale(identifier: "de-DE")
        #expect(await candidate.unavailability(locale: locale) == .unsupportedLanguage)
        #expect(await candidate.assetStatus(locale: locale) == .unsupported)
        await #expect(throws: TranscriptionError.failed(.unsupportedLanguage)) {
            try await candidate.installAssets(locale: locale) { _ in Issue.record("offered an unsupported install") }
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func equivalentLocaleAndAssetChangesAreRechecked() async {
        let status = Mutex<ModelPartStatus>(.notDownloaded)
        let requested = Mutex<[String]>([])
        let candidate = AppleSpeechTranscriber(probe: .init(isAvailable: { true }, supportedLocale: { locale in
            requested.withLock { $0.append(locale.identifier(.bcp47)) }; return Locale(identifier: "en-GB")
        }, assetStatus: { locale in
            #expect(locale.identifier(.bcp47) == "en-GB")
            return status.withLock { $0 }
        }))
        let locale = Locale(identifier: "en-AU")
        #expect(await candidate.assetStatus(locale: locale) == .notDownloaded)
        #expect(await candidate.unavailability(locale: locale) == nil)
        #expect(await candidate.runLanguage(requested: "en-AU") == "en-GB")
        status.withLock { $0 = .ready }
        #expect(await candidate.assetStatus(locale: locale) == .ready)
        status.withLock { $0 = .unsupported }
        #expect(await candidate.unavailability(locale: locale) == .model)
        #expect(await candidate.modelName(locale: locale) == nil)
        #expect(requested.withLock { $0 }.allSatisfy { $0 == "en-AU" })
    }
}
