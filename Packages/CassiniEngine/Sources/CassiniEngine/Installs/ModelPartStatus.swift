import CassiniNotebook

/// Where one part of the on-device models stands, as `Transcribing.assetStatus` and `SpeakerAnalyzing.modelStatus`
/// report it and Settings shows it.
public enum ModelPartStatus: Hashable, Sendable {
    case ready
    case downloading(Double?)
    case checking
    case notDownloaded
    case failed(DownloadError)
    /// This device or language cannot use the part.
    case unsupported
}
