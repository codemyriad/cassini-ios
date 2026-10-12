import CassiniNotebook

extension JobProgress {
    /// The model install of the running job, while it downloads or checks one; the Settings rows show it.
    public var modelDownload: DownloadProgress? {
        switch phase {
        case .downloading(let progress): progress
        case .transcribing(let progress, _): progress.download
        case .starting, .waitingForPrevious, .stopping: nil
        }
    }
}
