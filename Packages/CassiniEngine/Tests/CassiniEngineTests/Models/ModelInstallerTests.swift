import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniNotebook

/// Android's ModelInstallerTest over a fake store: no file is written and nothing is fetched.
@Suite struct ModelInstallerTests {
    private let all: Set<ModelPart> = [.speech, .speakers, .voices]
    private let speechReady: Set<ModelDescriptor> = [ModelCatalog.parakeet, ModelCatalog.vad]

    // ports: ModelInstallerTest#withoutConsentNothingIsFetchedAndTheNetworkIsNotAsked
    @Test func withoutConsentNothingIsFetchedAndTheNetworkIsNotAsked() async throws {
        let store = FakeStore(consent: false)
        let outcome = try await ModelInstaller(store: store).install(all) { _ in Issue.record("No progress without consent") }
        #expect(outcome == .needsConsent(missingBytes: ModelPlan.of { _ in false }.totalBytes))
        #expect(store.attempts.isEmpty)
        #expect(store.networkChecks == 0)
        #expect(store.spaceChecks == 0)
    }

    // ports: ModelInstallerTest#nothingMissingNeedsNoConsentAndNoNetwork
    @Test func nothingMissingNeedsNoConsentAndNoNetwork() async throws {
        let store = FakeStore(ready: speechReady.union([ModelCatalog.diarization, ModelCatalog.voiceprint]), consent: false)
        #expect(try await ModelInstaller(store: store).install(all) { _ in } == .installed())
        #expect(store.consentChecks == 0)
        #expect(store.networkChecks == 0)
    }

    // ports: ModelInstallerTest#offlineSkipsTheBestEffortPartsAtOnce
    @Test func offlineSkipsTheBestEffortPartsAtOnce() async throws {
        // An install that ran records an issue; the skip must not touch the store at all.
        let store = FakeStore(ready: speechReady, online: false)
        store.onInstall = { _, _ in Issue.record("Offline, the best-effort parts must be skipped, not installed") }
        let outcome = try await ModelInstaller(store: store).install([.speakers, .voices]) { _ in }
        #expect(outcome == .installed(skipped: [.speakers, .voices]))
        #expect(store.attempts.isEmpty)
    }

    // ports: ModelInstallerTest#offlineStillTriesSpeechAndReportsNoConnection
    @Test func offlineStillTriesSpeechAndReportsNoConnection() async throws {
        let store = FakeStore(online: false)
        store.fail(ModelCatalog.parakeet, with: URLError(.cannotFindHost))
        let outcome = try await ModelInstaller(store: store).install(all) { _ in }
        let speech = ModelPlan.of { _ in false }.missing.filter { $0.part == .speech }
        let required = ModelPlan(speech).requiredFreeBytes
        #expect(outcome == .failed(part: .speech, error: .noConnection, requiredFreeBytes: required))
        #expect(store.attempts == [ModelCatalog.parakeet])
    }

    // ports: ModelInstallerTest#installsEveryPartInOrder
    @Test func installsEveryPartInOrder() async throws {
        let store = FakeStore()
        #expect(try await ModelInstaller(store: store).install(all) { _ in } == .installed())
        #expect(store.attempts == [ModelCatalog.parakeet, ModelCatalog.vad, ModelCatalog.diarization, ModelCatalog.voiceprint])
    }

    // ports: ModelInstallerTest#voicesWaitForTheDiarizer
    @Test func voicesWaitForTheDiarizer() async throws {
        let store = FakeStore(ready: speechReady)
        store.fail(ModelCatalog.diarization, with: ModelError(.modelVerify))
        let outcome = try await ModelInstaller(store: store).install(all) { _ in }
        #expect(outcome == .installed(skipped: [.voices], failed: [.speakers: .fileCheckFailed]))
        #expect(store.attempts == [ModelCatalog.diarization])
    }

    // ports: ModelInstallerTest#aFailedDetectorDoesNotFailSpeech
    @Test func aFailedDetectorDoesNotFailSpeech() async throws {
        let store = FakeStore()
        store.fail(ModelCatalog.vad, with: ModelError(.modelDownload, "HTTP 503"))
        #expect(try await ModelInstaller(store: store).install([.speech]) { _ in } == .installed())
        #expect(store.attempts == [ModelCatalog.parakeet, ModelCatalog.vad])
    }

    // ports: ModelInstallerTest#aMissingDetectorIsFetchedAloneWhenOnline
    @Test func aMissingDetectorIsFetchedAloneWhenOnline() async throws {
        let store = FakeStore(ready: [ModelCatalog.parakeet])
        #expect(try await ModelInstaller(store: store).install([.speech]) { _ in } == .installed())
        #expect(store.attempts == [ModelCatalog.vad])

        let offline = FakeStore(ready: [ModelCatalog.parakeet], online: false)
        #expect(try await ModelInstaller(store: offline).install([.speech]) { _ in } == .installed())
        #expect(offline.attempts.isEmpty)
    }

    private var speechFreeBytes: Int64 { ModelPlan(ModelPlan.of { _ in false }.missing.filter { $0.part == .speech }).requiredFreeBytes }

    // ports: ModelInstallerTest#notEnoughSpaceFailsSpeechBeforeTheFirstByte
    @Test func notEnoughSpaceFailsSpeechBeforeTheFirstByte() async throws {
        let speech = speechFreeBytes
        let store = FakeStore(usable: speech - 1)
        let outcome = try await ModelInstaller(store: store).install(all) { _ in }
        // The figure is what speech alone needs: the best-effort parts never make the job fail.
        #expect(outcome == .failed(part: .speech, error: .notEnoughStorage, requiredFreeBytes: speech))
        #expect(store.attempts.isEmpty)

        let enough = FakeStore(usable: ModelPlan.of { _ in false }.requiredFreeBytes)
        #expect(try await ModelInstaller(store: enough).install(all) { _ in } == .installed())
    }

    // ports: ModelInstallerTest#theRoomThatSpeechNeedsAlsoFitsTheOtherParts
    @Test func theRoomThatSpeechNeedsAlsoFitsTheOtherParts() async throws {
        // Speech's peak holds the 431 MiB encoder download, which is deleted before the speaker parts start.
        #expect(try await ModelInstaller(store: FakeStore(usable: speechFreeBytes)).install(all) { _ in } == .installed())
    }

    // ports: ModelInstallerTest#spaceTakenDuringSpeechInstallsSpeechAndDegradesTheRest
    @Test func spaceTakenDuringSpeechInstallsSpeechAndDegradesTheRest() async throws {
        let speech = speechFreeBytes
        let store = FakeStore(usable: speech)
        // Another app fills the phone while speech downloads: only what speech's files left stays free.
        store.onInstall = { [store] model, _ in
            if model == ModelCatalog.parakeet { store.take(speech - model.artifactBytes) }
        }
        let outcome = try await ModelInstaller(store: store).install(all) { _ in }
        #expect(outcome == .installed(failed: [.speakers: .notEnoughStorage, .voices: .notEnoughStorage]))
        #expect(store.attempts == [ModelCatalog.parakeet, ModelCatalog.vad])
    }

    // ports: ModelInstallerTest#notEnoughSpaceOnlyDegradesTheBestEffortParts
    @Test func notEnoughSpaceOnlyDegradesTheBestEffortParts() async throws {
        let store = FakeStore(ready: speechReady, usable: 0)
        let outcome = try await ModelInstaller(store: store).install(all) { _ in }
        #expect(outcome == .installed(failed: [.speakers: .notEnoughStorage, .voices: .notEnoughStorage]))
        #expect(store.attempts.isEmpty)
    }

    // ports: ModelInstallerTest#progressCountsTheWholePartAndPassesVerifyingThrough
    @Test func progressCountsTheWholePartAndPassesVerifyingThrough() async throws {
        let store = FakeStore()
        let parakeet = ModelCatalog.parakeet.downloadBytes
        let vad = ModelCatalog.vad.downloadBytes
        store.onInstall = { model, progress in
            let size = model.downloadBytes
            progress(size / 2, false)
            progress(size, false)
            progress(size * 4 / 5, true)
            progress(size, true)
        }
        let seen = Mutex<[DownloadProgress]>([])
        _ = try await ModelInstaller(store: store).install([.speech]) { progress in seen.withLock { $0.append(progress) } }
        let total = parakeet + vad
        let events = seen.withLock { $0 }
        #expect(events == [
            DownloadProgress(part: .speech, doneBytes: parakeet / 2, totalBytes: total, verifying: false),
            DownloadProgress(part: .speech, doneBytes: parakeet, totalBytes: total, verifying: false),
            DownloadProgress(part: .speech, doneBytes: parakeet * 4 / 5, totalBytes: total, verifying: true),
            DownloadProgress(part: .speech, doneBytes: parakeet, totalBytes: total, verifying: true),
            DownloadProgress(part: .speech, doneBytes: parakeet + vad / 2, totalBytes: total, verifying: false),
            DownloadProgress(part: .speech, doneBytes: parakeet + vad, totalBytes: total, verifying: false),
            DownloadProgress(part: .speech, doneBytes: parakeet + vad * 4 / 5, totalBytes: total, verifying: true),
            DownloadProgress(part: .speech, doneBytes: total, totalBytes: total, verifying: true),
        ])
        #expect(events[2].percent == 79)
        #expect(events.last?.percent == 100)
    }

    // ports: ModelInstallerTest#errorsMapToTheDownloadBanners
    @Test func errorsMapToTheDownloadBanners() {
        func map(_ error: any Error, online: Bool = true) -> DownloadError {
            ModelInstaller.downloadError(error, online: { online })
        }
        func refusal(_ location: String, hop: Int) -> any Error {
            do {
                _ = try RedirectPolicy.downloads.next(from: URL(string: "https://dist.gocassini.com/model")!, location: location,
                                                      hop: hop)
                Issue.record("The redirect must be refused")
                return CancellationError()
            } catch {
                return error
            }
        }
        let refused = refusal("https://example.org/model", hop: 1)
        let tooMany = refusal("https://dist.gocassini.com/model", hop: 6)
        #expect(map(refused) == .hostNotAllowed)
        #expect(map(refused, online: false) == .hostNotAllowed)
        #expect(map(tooMany) == .interrupted)
        #expect(map(ModelError(.modelDownload, "HTTP 503")) == .interrupted)
        #expect(map(ModelError(.modelDownload, "HTTP 503"), online: false) == .noConnection)
        #expect(map(ModelError(.space)) == .notEnoughStorage)
        #expect(map(ModelError(.modelVerify)) == .fileCheckFailed)
        #expect(map(ModelError(.modelInstall)) == .install)
        // iOS only: the host's manifest does not offer the model as pinned; nothing to retry until Cassini is updated.
        #expect(map(ModelError(.download(.pinUnavailable), "The manifest does not list x")) == .pinUnavailable)
        #expect(map(ModelError(.download(.pinUnavailable)), online: false) == .pinUnavailable)
        #expect(map(URLError(.timedOut)) == .noConnection)
        #expect(map(URLError(.cannotFindHost)) == .noConnection)
        #expect(map(URLError(.networkConnectionLost)) == .interrupted)
        #expect(map(URLError(.networkConnectionLost), online: false) == .noConnection)
        #expect(map(CocoaError(.featureUnsupported)) == .install)
        // iOS reports a full disk as its own error.
        #expect(map(POSIXError(.ENOSPC)) == .notEnoughStorage)
        #expect(map(CocoaError(.fileWriteOutOfSpace)) == .notEnoughStorage)
    }

    // ports: ModelInstallerTest#aTimeoutDuringTheSpeechDownloadIsNoConnection
    @Test func aTimeoutDuringTheSpeechDownloadIsNoConnection() async throws {
        let store = FakeStore()
        store.fail(ModelCatalog.parakeet, with: URLError(.timedOut))
        let outcome = try await ModelInstaller(store: store).install(all) { _ in }
        guard case .failed(_, let error, _) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(error == .noConnection)
        #expect(store.attempts == [ModelCatalog.parakeet])
    }

    // ports: ModelInstallerTest#aCancelledFetchIsNeverABestEffortFailure
    @Test func aCancelledFetchIsNeverABestEffortFailure() async {
        let store = FakeStore(ready: speechReady)
        store.fail(ModelCatalog.diarization, with: ModelError(.cancelled))
        await #expect(throws: CancellationError.self, "A cancelled fetch must cancel the install") {
            try await ModelInstaller(store: store).install(all) { _ in }
        }
        #expect(store.attempts == [ModelCatalog.diarization])
    }

    // ports: ModelInstallerTest#cancellingTheCallerInterruptsTheFetch
    @Test func cancellingTheCallerInterruptsTheFetch() async throws {
        let store = FakeStore()
        let started = Mutex(false)
        let interrupted = Mutex(false)
        store.onInstall = { _, _ in
            started.withLock { $0 = true }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                interrupted.withLock { $0 = true }
                // ArtifactFetcher reports a cancel between blocks this way.
                throw ModelError(.cancelled)
            }
        }
        let install = Task { try await ModelInstaller(store: store).install(all) { _ in } }
        try await waitUntil { started.withLock { $0 } }
        install.cancel()
        await #expect(throws: CancellationError.self, "The install must end cancelled") { try await install.value }
        #expect(interrupted.withLock { $0 })
        #expect(store.attempts == [ModelCatalog.parakeet])
    }
}

/// Android's FakeStore: the models in `ready` are installed; each install takes its installed files from the free
/// bytes (its downloads are deleted once checked).
private final class FakeStore: ModelStore, Sendable {
    private struct State {
        var installed: Set<ModelDescriptor>
        var free: Int64
        var attempts: [ModelDescriptor] = []
        var failures: [ModelDescriptor: any Error] = [:]
        var onInstall: @Sendable (ModelDescriptor, @Sendable (Int64, Bool) -> Void) async throws -> Void = { _, _ in }
        var consentChecks = 0
        var networkChecks = 0
        var spaceChecks = 0
    }

    private let consent: Bool
    private let online: Bool
    private let state: Mutex<State>

    init(ready: Set<ModelDescriptor> = [], consent: Bool = true, online: Bool = true, usable: Int64 = .max) {
        self.consent = consent
        self.online = online
        state = Mutex(State(installed: ready, free: usable))
    }

    var attempts: [ModelDescriptor] { state.withLock { $0.attempts } }
    var consentChecks: Int { state.withLock { $0.consentChecks } }
    var networkChecks: Int { state.withLock { $0.networkChecks } }
    var spaceChecks: Int { state.withLock { $0.spaceChecks } }

    var onInstall: @Sendable (ModelDescriptor, @Sendable (Int64, Bool) -> Void) async throws -> Void {
        get { state.withLock { $0.onInstall } }
        set { state.withLock { $0.onInstall = newValue } }
    }

    /// Space that something else takes.
    func take(_ bytes: Int64) { state.withLock { $0.free -= bytes } }

    func fail(_ model: ModelDescriptor, with error: any Error) { state.withLock { $0.failures[model] = error } }

    func consented() async -> Bool {
        state.withLock { $0.consentChecks += 1 }
        return consent
    }

    func hasValidatedNetwork() -> Bool {
        state.withLock { $0.networkChecks += 1 }
        return online
    }

    func ready(_ model: ModelDescriptor) -> Bool { state.withLock { $0.installed.contains(model) } }

    func usableBytes() -> Int64 {
        state.withLock { state in
            state.spaceChecks += 1
            return state.free
        }
    }

    func install(_ model: ModelDescriptor, progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
        let (failure, onInstall) = state.withLock { state in
            state.attempts.append(model)
            return (state.failures[model], state.onInstall)
        }
        if let failure { throw failure }
        try await onInstall(model, progress)
        state.withLock { state in
            state.installed.insert(model)
            state.free -= model.artifactBytes
        }
    }
}

extension ModelInstallerTests {
    @Test func wrappedAndDirectTransportCodesUseTheSameClassification() {
        let codes: [URLError.Code] = [.timedOut, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
            .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .networkConnectionLost, .badServerResponse]
        for online in [true, false] {
            for code in codes {
                let wrapped = ModelError(.modelDownload, "diagnostic without a transport code", urlErrorCode: code)
                #expect(ModelInstaller.downloadError(wrapped, online: { online })
                    == ModelInstaller.downloadError(URLError(code), online: { online }))
            }
        }
        #expect(ModelInstaller.isCancellation(ModelError(.modelDownload, urlErrorCode: .cancelled)))
        #expect(!ModelInstaller.isCancellation(ModelError(.modelDownload, urlErrorCode: .networkConnectionLost)))
    }
}
