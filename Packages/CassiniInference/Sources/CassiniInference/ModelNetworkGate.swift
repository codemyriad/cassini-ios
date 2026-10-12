import Foundation
import Synchronization
import FluidAudio

/// FluidAudio's `ModelHub.offlineMode` is one switch for the whole process. Cassini keeps it on (no network), and
/// turns it off only while at least one permitted download runs: a download that ends, or a request that joins one
/// and leaves, never turns it back on in the middle of another download.
public final class ModelNetworkGate: Sendable {
    /// The gate over FluidAudio's switch.
    public static let fluidAudio = ModelNetworkGate { offline in ModelHub.offlineMode = offline }

    private let downloads = Mutex(0)
    private let setOffline: @Sendable (Bool) -> Void

    /// `setOffline` receives every change of the switch, under the gate's lock.
    public init(setOffline: @escaping @Sendable (Bool) -> Void) {
        self.setOffline = setOffline
    }

    /// Whether a download holds the network open now.
    public var isOpen: Bool { downloads.withLock { $0 > 0 } }

    /// Turns the network off unless a download runs.
    public func close() {
        downloads.withLock { count in if count == 0 { setOffline(true) } }
    }

    /// Runs `body` with downloads allowed; the network closes again once no download runs.
    public func allowingDownloads<T>(isolation: isolated (any Actor)? = #isolation,
                                     _ body: () async throws -> T) async throws -> T {
        open()
        defer { leave() }
        return try await body()
    }

    private func open() {
        downloads.withLock { count in
            count += 1
            if count == 1 { setOffline(false) }
        }
    }

    private func leave() {
        downloads.withLock { count in
            count -= 1
            if count == 0 { setOffline(true) }
        }
    }
}
