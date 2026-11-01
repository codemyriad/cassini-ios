import Foundation
import CassiniNotebook

/// A pinned file: `size` bytes with SHA-256 `sha256` (Android's `Artifact`). `download` is the seekable Zstandard copy
/// that is fetched in its place, with its own pins, at `url` on the model host; the app fetches the URL that the host's
/// manifest gives (`DistManifest`), which must be this one. A file without `download` is not fetched by the app (tests).
public struct Artifact: Hashable, Sendable {
    public var name: String
    public var size: Int64
    public var sha256: String
    public var url: String
    /// An array holds the optional download, because a struct cannot hold a value of its own type.
    private var downloads: [Artifact]

    public init(_ name: String, _ size: Int64, _ sha256: String, _ url: String = "", download: Artifact? = nil) {
        self.name = name; self.size = size; self.sha256 = sha256; self.url = url
        downloads = download.map { [$0] } ?? []
    }

    public var download: Artifact? {
        get { downloads.first }
        set { downloads = newValue.map { [$0] } ?? [] }
    }
}

/// One installed model, identified by its pinned pair on the model host: the manifest `id` and the SHA-256 of its
/// source, `sourceSha256` (D4, D53.1). Its `artifacts` live in `<root>/models/<id>/<sourceSha256>/` (`directory`),
/// with the host's `NOTICE.txt` beside them.
///
/// The revision directory appears only by renaming a complete staging directory (`ModelRepository.installModel`), so
/// its name is the pin and no marker file is needed: the model is ready when the directory has every artifact at its
/// pinned size and a `NOTICE.txt`. Every byte was checked before the rename; `ModelVerifier` checks them again before
/// the first use in each session.
public struct ModelDescriptor: Hashable, Sendable {
    /// The directory under the model root that holds every model, as on the desktop.
    public static let modelsDirectory = "models"
    /// The model host's notices, kept in each revision directory (D4: "ship NOTICE.txt with downloaded models").
    public static let noticeFile = "NOTICE.txt"

    public var id: String
    public var sourceSha256: String
    public var artifacts: [Artifact]

    public init(_ id: String, _ sourceSha256: String, _ artifacts: [Artifact]) {
        self.id = id; self.sourceSha256 = sourceSha256; self.artifacts = artifacts
    }

    /// `<id>@<sourceSha256>`, as provenance names a model (D16 §5).
    public var pin: String { "\(id)@\(sourceSha256)" }

    /// The revision directory under the model root.
    public var directory: String { "\(Self.modelsDirectory)/\(id)/\(sourceSha256)" }

    public func directory(in root: URL) -> URL { root.appendingPathComponent(directory, isDirectory: true) }

    public func path(in root: URL, _ name: String) -> String { directory(in: root).appendingPathComponent(name).path }

    /// Where an install collects and checks the files before it renames the directory into place: beside the revision,
    /// named after it, so a later install resumes its `.part` files and keeps its checked files.
    public func staging(in root: URL) -> URL {
        root.appendingPathComponent("\(Self.modelsDirectory)/\(id)/.\(sourceSha256).staging", isDirectory: true)
    }

    public func ready(in root: URL) -> Bool { complete(directory(in: root)) }

    /// Whether `directory` has every artifact at its pinned size and a notice that is not empty.
    public func complete(_ directory: URL) -> Bool {
        artifacts.allSatisfy { ModelFiles.length(of: directory.appendingPathComponent($0.name)) == $0.size }
            && ModelFiles.length(of: directory.appendingPathComponent(Self.noticeFile)) > 0
    }

    /// Bytes fetched over the network to install this model from nothing: the compressed files.
    public var downloadBytes: Int64 { artifacts.reduce(0) { $0 + ($1.download?.size ?? $1.size) } }

    /// Bytes of the installed files.
    public var artifactBytes: Int64 { artifacts.reduce(0) { $0 + $1.size } }

    /// The largest compressed download of one file; 0 when no file is compressed.
    public var largestDownloadBytes: Int64 { artifacts.map { $0.download?.size ?? 0 }.max() ?? 0 }

    /// Bytes on disk at most while installing: the files are fetched one at a time, and a compressed download is
    /// deleted as soon as its decompressed file is in place. So the peak is every installed file plus the one download
    /// that is being decompressed, at most `largestDownloadBytes`.
    public var installBytes: Int64 { artifactBytes + largestDownloadBytes }
}

/// The few file facts the models need, as `java.io.File` gives them on Android: a missing file has length 0.
enum ModelFiles {
    static func length(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func isFile(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// Writes `url` (a file or a directory) through to storage: `F_FULLFSYNC` on Darwin, which also flushes the
    /// device's cache, else `fsync`. Throws the POSIX error when neither works.
    static func sync(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 { return }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// Renames `source` to `destination`, which must not exist (`RENAME_EXCL`).
    static func renameExclusive(_ source: URL, _ destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Removes `directory` so that no half of it is ever read as a model: it is renamed to `.remove-<UUID>` beside
    /// itself first (only this can fail), then deleted; what a crash leaves of it is deleted by
    /// `ModelRepository.prune`. Nothing happens when it does not exist.
    static func retire(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let retired = directory.deletingLastPathComponent().appendingPathComponent(".remove-\(UUID().uuidString)")
        try renameExclusive(directory, retired)
        try? sync(directory.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: retired)
    }
}

/// Every model Cassini installs itself, pinned as the model host `dist.gocassini.com` publishes it (manifest schema 2
/// of 2026-10-27; D4, D16, D53.1): each model by its pair (manifest id, source SHA-256), each file by its decompressed
/// size and SHA-256 and by the size and SHA-256 of its seekable Zstandard download. The app never follows a newer entry
/// of the manifest: a model whose pair or files the manifest no longer lists as pinned here is not downloaded
/// (`DistManifest`). Changing a pin changes the model's directory, so installed models look missing; the directories of
/// earlier development builds are deleted, not read (D51, `ModelRepository.prune`). `scripts/ci-models.json` lists the
/// same values (`ModelCatalogTests.theCiModelListIsTheCatalog`).
///
/// On devices that fall back to Apple Speech (decision D2) the speech part is Apple's assets, which AssetInventory owns;
/// nothing here describes them.
public enum ModelCatalog {
    /// The model host. Every model file, the manifest and the notices come from it, and from nowhere else.
    public static let distHost = "dist.gocassini.com"
    public static let distBase = "https://\(distHost)"
    /// The manifest of the model host, read before each model download to find the pinned files.
    public static let manifestURL = "\(distBase)/manifest.json"
    /// The host's notices for every model it publishes, downloaded into each installed revision.
    public static let noticeURL = "\(distBase)/NOTICE.txt"

    /// A decompressed file `name` and its download at the content-addressed path of the model host.
    private static func dist(_ name: String, _ size: Int64, _ sha256: String, _ compressedSize: Int64,
                             _ compressedSha256: String) -> Artifact {
        Artifact(name, size, sha256, download: Artifact("\(name).zst", compressedSize, compressedSha256,
                                                        "\(distBase)/models/files/\(compressedSha256)/\(name).zst"))
    }

    /// Parakeet Ultra INT8 on the model host (`parakeet-ultra-0.6b-int8`): the codemyriad sherpa-onnx
    /// `nemo_transducer` export of moondream/parakeet-ultra, a post-train of NVIDIA Parakeet TDT 0.6B v3, used exactly
    /// as downloaded (D16 §2). It needs the codemyriad sherpa-onnx fork. Its revision, which provenance and checkpoints
    /// name, is the source SHA-256.
    public static let parakeetDistID = "parakeet-ultra-0.6b-int8"
    public static let parakeetRevision = "18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9"
    public static let parakeetPrecision = "INT8"

    /// The model id of Android's provenance (`<id> <precision>`) and the name the app shows for it.
    public static let parakeetModelID = "moondream/parakeet-ultra"
    public static let parakeetDisplayName = "Parakeet Ultra"

    public static let parakeetArtifacts: [Artifact] = [
        dist("encoder.int8.onnx", 652_282_922, "299617fefd4664d1c115b691dcb6413cabcdbcc694cdf3cb4464b72c5fc3ae69",
             452_306_705, "caf7a38f2ad3224c1863564fb6e975a11aa3ae6ad1e7ad0bee5c4f5e018babb4"),
        dist("decoder.int8.onnx", 11_845_274, "1fab98fe6c12aded87d2da66272cc9e148d0a0044ce3850a12fe56302ec4a922",
             8_841_708, "69e2e91d01225bc552f8b0113630562fc52622cb2a3c61ef4445ee779f06b295"),
        dist("joiner.int8.onnx", 6_355_277, "8a71aaccfdba3d451775507a889afd2257d2e754463fd81095a8c8f290f924c2",
             3_714_640, "639fda62a71242a8d7cefb6647f2094eb8ac783925ce91cbd047a0de6988f396"),
        dist("tokens.txt", 93_939, "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d",
             45_831, "5b3811f0c23fefc86835981f0a23ecfb817999df272ad744c597e5b669ea1b4a"),
    ]

    public static let parakeet = ModelDescriptor(parakeetDistID, parakeetRevision, parakeetArtifacts)

    /// What a Parakeet transcript's provenance names as its model: `<id>@<source_sha256>` (D16 §5).
    public static var parakeetProvenanceModel: String { parakeet.pin }

    /// The name the app shows for the speech model of this build, by the model string iOS writes (its pin, D16 §5) and
    /// by the one Android writes. Earlier models have no entry (D51).
    public static let speechModelNames: [String: String] = [
        parakeet.pin: parakeetDisplayName,
        parakeetModelID: parakeetDisplayName,
    ]

    /// Silero VAD for chunked decoding (`silero-vad`), installed on its own: Parakeet is ready without it.
    public static let sileroVad = dist("silero_vad.onnx", 643_854,
                                       "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
                                       469_349, "dad26acf8515705fed5510d847c69366cb2710681ec4f87484a2de65ca855a3c")
    public static let vad = ModelDescriptor("silero-vad", sileroVad.sha256, [sileroVad])

    /// NVIDIA Nemotron-3-Diarization (`nemotron-3-diarization-int8`), exported to INT8 ONNX (interface v2) for
    /// sherpa-onnx's Sortformer runtime. `diarizationSourceRevision` is the Hugging Face revision that the manifest's
    /// `source_url` names; the source SHA-256 is the export's own hash.
    public static let diarizationSourceRevision = "f667ed73aee57d40cc39428eb768b4fd87a0a29e"
    public static let diarizationModel = dist("model.int8.onnx", 103_967_426,
                                              "47c221ea9b4d4e7f6c108bd098e769bc706cdc986c29f6133c93cae335fe6779",
                                              64_915_668, "794720a59892189484d38a186d2b350018b4194cae55292f501b2849d6313290")
    public static let diarization = ModelDescriptor("nemotron-3-diarization-int8", diarizationModel.sha256,
                                                    [diarizationModel])

    /// CAM++ speaker embeddings (`campplus-voxceleb-16k`), the sherpa-onnx release's file byte for byte. Its SHA-256 is
    /// the model identity of every saved voice (`VoiceprintModel`), so it must not change.
    public static let voiceprintModel = dist("3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx", 29_596_978,
                                             "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b",
                                             27_138_478, "c310f60acec22ce27d78bd37736e40015af6473a1e3482224e81434aca5557b0")

    /// The length of a CAM++ print from `voiceprintModel`. A saved voice whose mean has another length cannot be
    /// compared and is stale.
    public static let voiceprintDim = 512

    public static let voiceprint = ModelDescriptor("campplus-voxceleb-16k", voiceprintModel.sha256, [voiceprintModel])

    /// The models one consented download installs, in install order. The detector is fetched separately.
    public static let consented: [ModelDescriptor] = [parakeet, diarization, voiceprint]

    /// Every model of the catalog.
    public static let all: [ModelDescriptor] = [parakeet, vad, diarization, voiceprint]

    /// The hosts a model download may reach (`RedirectPolicy`): the model host alone. An entry `*.example.com` would
    /// match every subdomain of example.com but not example.com itself; any other entry matches exactly. The manifest,
    /// the notices and every file URL the manifest gives must be HTTPS on these hosts, and so must each redirect.
    /// Privacy.txt lists the same entries (`LicenseAssetsTests.thePrivacyTextListsEachDownloadHost`).
    ///
    /// Recorded on 2026-11-01: the manifest, the notices and the model files answer 200 without a redirect, the files
    /// with `ETag: "<SHA-256 of the compressed file>"` and `Accept-Ranges: bytes`.
    public static let downloadHosts = [distHost]

    /// Each URL Cassini downloads models from, as "Where the models come from" lists them: the manifest, the notices,
    /// then every file of every model.
    public static var downloads: [(name: String, url: URL)] {
        [("manifest.json", URL(string: manifestURL)!), (ModelDescriptor.noticeFile, URL(string: noticeURL)!)]
            + all.flatMap(\.artifacts).compactMap(\.download).map { ($0.name, URL(string: $0.url)!) }
    }

    /// The model host's notices in an installed revision under `root` (the newest, when several are installed); nil
    /// before the first model is installed.
    public static func installedNotice(in root: URL) -> URL? {
        all.filter { $0.ready(in: root) }
            .map { URL(fileURLWithPath: $0.path(in: root, ModelDescriptor.noticeFile)) }
            .max { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Bytes fetched over the network for each part, which is what the consent screen quotes.
    public static let parakeetBytes = parakeet.downloadBytes
    public static let speakerBytes = diarization.downloadBytes
    public static let voiceprintBytes = voiceprint.downloadBytes
    public static let totalBytes = parakeetBytes + speakerBytes + voiceprintBytes

    /// Whole MiB, rounded to tens from 100 MiB up, as Android writes `models_size`.
    public static func mebibytes(_ bytes: Int64) -> Int64 {
        let mib = Double(bytes) / 1_048_576
        return mib < 100 ? max(1, Int64(mib.rounded())) : Int64((mib / 10).rounded()) * 10
    }

    /// Where the models live: Application Support/CassiniModels, excluded from backups. It stays apart from
    /// Application Support/Cassini, which holds the note folders and is backed up.
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("CassiniModels", isDirectory: true)
    }
}
