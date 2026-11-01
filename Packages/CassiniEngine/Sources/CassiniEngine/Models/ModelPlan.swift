import Foundation
import CassiniNotebook

/// The three things a model download installs, as Android's `ModelPart` describes them. A part is ready when its
/// `primary` model is ready; `extras` are best-effort models fetched with it (Silero VAD with speech recognition)
/// whose absence never makes the part missing.
extension ModelPart {
    /// The model that makes the part ready: Parakeet, the Nemotron diarizer, the CAM++ voiceprint model.
    public var primary: ModelDescriptor {
        switch self {
        case .speech: ModelCatalog.parakeet
        case .speakers: ModelCatalog.diarization
        case .voices: ModelCatalog.voiceprint
        }
    }

    public var extras: [ModelDescriptor] { self == .speech ? [ModelCatalog.vad] : [] }

    /// Every model of this part, the primary first.
    public var models: [ModelDescriptor] { [primary] + extras }
}

/// What a model download still has to install, with the sizes the Model download screen shows and the free space it
/// checks before the first byte (Android's `ModelPlan`).
///
/// A part is missing when its primary model is not ready. A missing part brings every one of its models that is not
/// ready, extras included; an extra missing from a ready part is not in the plan (it is best effort).
public struct ModelPlan: Hashable, Sendable {
    /// One missing `part` and the `models` of it still to install.
    public struct Item: Hashable, Sendable {
        public var part: ModelPart
        public var models: [ModelDescriptor]
        public init(_ part: ModelPart, _ models: [ModelDescriptor]) { self.part = part; self.models = models }

        /// Bytes fetched over the network.
        public var downloadBytes: Int64 { models.reduce(0) { $0 + $1.downloadBytes } }

        /// Bytes on disk at most while installing: the models install one after another, so every installed file plus
        /// the largest single download being decompressed (`ModelDescriptor.installBytes`).
        public var installBytes: Int64 {
            models.reduce(0) { $0 + $1.artifactBytes } + (models.map(\.largestDownloadBytes).max() ?? 0)
        }

        /// The size shown next to the part: `downloadBytes` in whole MiB as `ModelCatalog.mebibytes` rounds it.
        public var mebibytes: Int64 { ModelCatalog.mebibytes(downloadBytes) }
    }

    public var missing: [Item]
    public init(_ missing: [Item]) { self.missing = missing }

    public var parts: [ModelPart] { missing.map(\.part) }

    public var isEmpty: Bool { missing.isEmpty }

    /// Download bytes of each missing part.
    public var downloadBytes: [ModelPart: Int64] {
        missing.reduce(into: [:]) { $0[$1.part] = $1.downloadBytes }
    }

    /// Every byte the plan fetches over the network.
    public var totalBytes: Int64 { missing.reduce(0) { $0 + $1.downloadBytes } }

    /// The total the screen shows: the sum of the rounded part sizes, so the numbers on screen add up (440 + 62 + 26 =
    /// 528 for a fresh install; `mebibytes(totalBytes)` would round the same bytes to 530).
    public var totalMebibytes: Int64 { missing.reduce(0) { $0 + $1.mebibytes } }

    /// Free space needed before the first byte: every file of the missing parts, plus the largest single download (the
    /// parts install one after another, and each download is deleted once its file is in place), plus
    /// `ArtifactFetcher.slackBytes`; 0 when nothing is missing. Kept `.part` files are not subtracted;
    /// `ArtifactFetcher` checks each file again with what it still has to fetch.
    public var requiredFreeBytes: Int64 {
        guard !missing.isEmpty else { return 0 }
        let models = missing.flatMap(\.models)
        let largest = models.map(\.largestDownloadBytes).max() ?? 0
        return models.reduce(0) { $0 + $1.artifactBytes } + largest + ArtifactFetcher.slackBytes
    }

    /// `requiredFreeBytes` as the "Needs about 1230 MB free" figure, rounded like every size on the screen (a fresh
    /// install needs about 1231 MiB and shows 1230; the space check itself compares bytes).
    public var requiredFreeMebibytes: Int64 { missing.isEmpty ? 0 : ModelCatalog.mebibytes(requiredFreeBytes) }

    /// The plan for the models `ready` reports, in `ModelPart` order.
    public static func of(ready: (ModelDescriptor) -> Bool) -> ModelPlan {
        ModelPlan(ModelPart.allCases.filter { !ready($0.primary) }.map { Item($0, $0.models.filter { !ready($0) }) })
    }

    /// The plan for the models installed under `root`.
    public static func of(root: URL) -> ModelPlan { of { $0.ready(in: root) } }
}

/// A model install that failed, as Android's `UserFacingException` carries it: the core failure (`DOWNLOAD`,
/// `VERIFY`, `SPACE`, `INSTALL` or `CANCELLED`) and a diagnostic that is never shown.
public struct ModelError: Error, Hashable, Sendable, CustomStringConvertible {
    public var failure: JobFailure
    public var message: String

    public init(_ failure: JobFailure, _ message: String? = nil) {
        self.failure = failure
        self.message = message ?? failure.code
    }

    public var description: String { "\(failure.code): \(message)" }

    /// Throws `ModelError(failure)` unless `condition` holds (Android's `requireUser`).
    static func require(_ condition: Bool, _ failure: JobFailure) throws {
        if !condition { throw ModelError(failure) }
    }
}
