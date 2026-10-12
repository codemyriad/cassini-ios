import CassiniNotebook

public enum ModelPartStatus: Hashable, Sendable {
    case ready
    case downloading(Double?)
    case checking
    case notDownloaded
    case failed(DownloadError)
    /// This device or language cannot use the part.
    case unsupported
}

public protocol ModelStatusProviding: Sendable {
    func status(of part: ModelPart) async -> ModelPartStatus
}
