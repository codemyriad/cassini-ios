import Foundation

public struct ImportedFile: Hashable, Sendable {
    public var displayName: String
    public var byteCount: Int64
    public var sha256: String
    public init(displayName: String, byteCount: Int64, sha256: String) {
        self.displayName = displayName; self.byteCount = byteCount; self.sha256 = sha256
    }
}

public enum FileImportError: Error, Hashable {
    case tooLarge
    case noSpace(bytesNeeded: Int64)
    case cannotOpen
}

/// Reads a file another app offered, with coordinated and security-scoped access.
public protocol FileImporting: Sendable {
    /// Copies `source` to `destination`, hashing as it goes. Stops with `tooLarge` past `maxBytes`, and with `noSpace`
    /// when less than `reserveBytes` would stay free. Nothing is left at `destination` after an error.
    func copy(from source: URL, to destination: URL, maxBytes: Int64, reserveBytes: Int64) async throws -> ImportedFile
}
