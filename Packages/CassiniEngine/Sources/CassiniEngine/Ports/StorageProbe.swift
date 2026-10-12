import Foundation

public protocol StorageProbe: Sendable {
    /// Free bytes on the volume of `url` for important use; `Int64.max` when the volume does not say.
    func availableBytes(at url: URL) -> Int64
}
