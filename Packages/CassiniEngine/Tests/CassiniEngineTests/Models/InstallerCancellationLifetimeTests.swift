import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// No timers or live network: completion is held precisely between owner detachment and continuation resumption.
@Suite struct InstallerCancellationLifetimeTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor func cancellationInTheIdlePublicationGapDoesNotAffectTheNextRequest() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let suite = "cassini.installer-lifetime.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, clock: FakeClock(), defaultLanguage: "en-US")
        let repository = ModelRepository(root: folder.root, consent: settings, fetcher: NeverFetch())
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let held = Mutex(false)
        // No missing artifacts: offline best-effort speaker parts return an outcome without fetching.
        let owner = PinnedModelInstaller(models: repository, storage: FakeStorage(), online: { false }, onChange: { status in
            guard status == .idle, held.withLock({ first in if first { return false }; first = true; return true }) else { return }
            entered.continuation.yield(())
            entered.continuation.finish()
            release.wait()
        })
        await repository.recordConsent()
        let caller = Task.detached { try await owner.install([.speakers], granted: true) }
        for await _ in entered.stream { break }
        #expect(owner.status == .idle)
        caller.cancel() // finish already removed current, but the caller's continuation is still suspended.
        release.signal()
        switch await caller.result {
        case .success(let outcome): #expect(outcome == .installed(skipped: [.speakers]))
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(try await owner.install([.speakers], granted: true) == .installed(skipped: [.speakers]))
        #expect(owner.status == .idle)
    }

    @Test func cancellationBeforeAttachmentIsRememberedOnlyByThatRequest() {
        var request: PinnedModelInstaller.RequestCancellation? = .init()
        weak var lifetime = request
        #expect(request?.isCancelled == false)
        request?.cancel()
        request?.cancel()
        #expect(request?.isCancelled == true, "attach observes cancellation even if leave ran before a waiter existed")
        #expect(PinnedModelInstaller.RequestCancellation().isCancelled == false)
        request = nil
        #expect(lifetime == nil, "pre-attachment cancellation state has no owner-global lifetime")
    }
}

private struct NeverFetch: ModelFetching {
    func fetch(_ model: ModelDescriptor, into directory: URL, progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
        Issue.record("Offline best-effort request must not fetch")
        throw CancellationError()
    }
}
