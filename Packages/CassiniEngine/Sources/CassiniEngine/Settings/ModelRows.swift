import Foundation
import CassiniNotebook

/// The status text of an On-device models row.
public enum ModelRowStatus: Hashable, Sendable {
    /// "Ready".
    case ready
    /// "Downloading 46%".
    case downloading(percent: Int)
    /// "Checking files".
    case checking
    /// "Downloads with next transcription": missing, and the download is agreed to.
    case pending
    /// "Not downloaded": missing and not agreed to; the row opens the model download screen.
    case notDownloaded
    /// "Download failed — tries again next time"; the row opens the model download screen.
    case failed
    /// "Not available": the device or the speech language cannot use the part (iOS only).
    case unavailable

    /// Only a Not downloaded and a Failed row are buttons: they open the model download screen, with no note.
    public var opensModelDownload: Bool { self == .notDownloaded || self == .failed }

    /// The status's tone (Android `SettingsScreen`): Ready teal, Downloading and Checking blue, Pending amber, Failed
    /// red, the rest plain.
    public var tone: Tone {
        switch self {
        case .ready: .ok
        case .downloading, .checking: .info
        case .pending: .warn
        case .failed: .error
        case .notDownloaded, .unavailable: .plain
        }
    }
}

/// How big a part is, for its row's subtitle.
public enum ModelSize: Hashable, Sendable {
    /// Apple's speech assets: iOS downloads and keeps them, and does not tell their size first.
    case managedBySystem
    case bytes(Int64)
    /// Installed with another part's models.
    case includedWith(ModelPart)
}

/// One On-device models row.
public struct ModelRow: Hashable, Sendable, Identifiable {
    public var part: ModelPart
    public var size: ModelSize
    public var status: ModelRowStatus
    public var id: ModelPart { part }
    public init(part: ModelPart, size: ModelSize, status: ModelRowStatus) {
        self.part = part; self.size = size; self.status = status
    }
}

public enum ModelRows {
    /// The rows in `ModelPart` order; a part whose status is not known yet is left out.
    public static func rows(_ statuses: [ModelPart: ModelPartStatus], consented: (ModelPart) -> Bool,
                            size: (ModelPart) -> ModelSize) -> [ModelRow] {
        ModelPart.allCases.compactMap { part in
            statuses[part].map { ModelRow(part: part, size: size(part), status: status($0, consented: consented(part))) }
        }
    }

    public static func status(_ status: ModelPartStatus, consented: Bool) -> ModelRowStatus {
        switch status {
        case .ready: .ready
        case .downloading(let fraction): .downloading(percent: Int((min(max(fraction ?? 0, 0), 1) * 100).rounded(.down)))
        case .checking: .checking
        case .notDownloaded: consented ? .pending : .notDownloaded
        case .failed: .failed
        case .unsupported: .unavailable
        }
    }

    /// A running job's model download, as the status of the part it installs.
    public static func status(of progress: DownloadProgress) -> ModelPartStatus {
        progress.verifying ? .checking : .downloading(Double(progress.percent) / 100)
    }
}
