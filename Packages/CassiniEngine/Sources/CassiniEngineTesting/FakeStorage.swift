import Foundation
import Synchronization
import CassiniEngine

public final class FakeStorage: StorageProbe {
    private let bytes: Mutex<Int64>
    public init(availableBytes: Int64 = 64 * 1024 * 1024 * 1024) { bytes = Mutex(availableBytes) }
    public func availableBytes(at url: URL) -> Int64 { bytes.withLock { $0 } }
    public func set(availableBytes: Int64) { bytes.withLock { $0 = availableBytes } }
}
