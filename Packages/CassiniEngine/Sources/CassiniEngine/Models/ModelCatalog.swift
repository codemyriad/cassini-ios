import Foundation
import CassiniNotebook

/// A pinned file: `size` bytes with SHA-256 `sha256`, fetched from `url` (empty for a file produced on the phone).
public struct Artifact: Hashable, Sendable {
    public var name: String
    public var size: Int64
    public var sha256: String
    public var url: String

    public init(_ name: String, _ size: Int64, _ sha256: String, _ url: String = "") {
        self.name = name; self.size = size; self.sha256 = sha256; self.url = url
    }
}

/// One installed model: the `artifacts` in `<root>/<directory>`. It is ready when every artifact has its pinned size
/// and the marker file `markerFile` holds `markerValue`; the marker is written only after every artifact verified.
/// `download` is the compressed file fetched in place of the single artifact, when there is one.
public struct ModelDescriptor: Hashable, Sendable {
    public var directory: String
    public var artifacts: [Artifact]
    public var markerFile: String
    public var markerValue: String
    public var download: Artifact?

    public init(_ directory: String, _ artifacts: [Artifact], _ markerFile: String, _ markerValue: String,
                download: Artifact? = nil) {
        self.directory = directory; self.artifacts = artifacts; self.markerFile = markerFile
        self.markerValue = markerValue; self.download = download
    }

    public func directory(in root: URL) -> URL { root.appendingPathComponent(directory, isDirectory: true) }

    public func path(in root: URL, _ name: String) -> String { directory(in: root).appendingPathComponent(name).path }

    public func ready(in root: URL) -> Bool {
        let home = directory(in: root)
        let marker = home.appendingPathComponent(markerFile)
        guard artifacts.allSatisfy({ ModelFiles.length(of: home.appendingPathComponent($0.name)) == $0.size }),
              ModelFiles.isFile(marker) else { return false }
        return (try? String(contentsOf: marker, encoding: .utf8)) == markerValue
    }

    /// Bytes fetched over the network to install this model from nothing.
    public var downloadBytes: Int64 { download?.size ?? artifacts.reduce(0) { $0 + $1.size } }

    /// Bytes of the installed files.
    public var artifactBytes: Int64 { artifacts.reduce(0) { $0 + $1.size } }
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
}

/// Every model Cassini installs itself, with Android's exact pins, URLs, directory names and marker semantics
/// (`ModelCatalog.kt`). Changing a pin, a directory or a marker value makes installed models look missing or, worse,
/// look ready when they are not. The sizes are pinned data; `scripts/ci-models.json` lists the same values
/// (`ModelCatalogTests.theCiModelListIsTheCatalog`).
///
/// The speaker models (Nemotron Sortformer and CAM++) are listed as Android lists them. On devices that fall back to
/// Apple Speech (decision D2) the speech part is Apple's assets, which AssetInventory owns; nothing here describes
/// them.
public enum ModelCatalog {
    /// Parakeet Ultra INT8 on Hugging Face: tpmaerk's sherpa-onnx `nemo_transducer` export of moondream/parakeet-ultra
    /// (revision 73175eb7), a post-train of NVIDIA Parakeet TDT 0.6B v3. The export changes only the format; the token
    /// table is the one of v3. Its marker `parakeet-ultra/verified` holds this revision.
    public static let parakeetRevision = "b86784a3a5356cbd126f710b61cd90c5fe5898f1"
    public static let parakeetRepository = "tpmaerk/parakeet-ultra-sherpa-onnx-int8"
    public static let parakeetPrecision = "INT8"

    /// The model id that a document's provenance names (`<id> <precision>`), and the name the app shows for it.
    public static let parakeetModelID = "moondream/parakeet-ultra"
    public static let parakeetDisplayName = "Parakeet Ultra"

    /// Parakeet TDT 0.6B v3 INT8 (csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8), Android's speech model of
    /// 0.1.0 to 0.2.0. No build installs it; documents and checkpoints made with it keep its id and revision.
    public static let parakeetV3Revision = "2bda32ec70b097a55adaa07d9a7173915b43cc78"
    public static let parakeetV3ModelID = "nvidia/parakeet-tdt-0.6b-v3"
    public static let parakeetV3DisplayName = "Parakeet TDT 0.6B v3"

    /// The name the app shows for each speech model id that a document's provenance can name: this build's model and
    /// the earlier ones, so a document keeps its true model name.
    public static let speechModelNames: [String: String] = [
        parakeetModelID: parakeetDisplayName,
        parakeetV3ModelID: parakeetV3DisplayName,
    ]

    private static func huggingFace(_ name: String) -> String {
        "https://huggingface.co/\(parakeetRepository)/resolve/\(parakeetRevision)/\(name)"
    }

    public static let parakeetArtifacts: [Artifact] = [
        Artifact("encoder.int8.onnx", 652_282_347,
                 "f4d06712d32431b1718eceba2153c314ac4425e8fe708a3534f5e56c5ad53697", huggingFace("encoder.int8.onnx")),
        Artifact("decoder.int8.onnx", 11_845_275,
                 "94373c6405c8149d1c9d1e9862514e0e3e88dab1c7de18fac9d5df9c6ba5efdd", huggingFace("decoder.int8.onnx")),
        Artifact("joiner.int8.onnx", 6_355_277,
                 "8a71aaccfdba3d451775507a889afd2257d2e754463fd81095a8c8f290f924c2", huggingFace("joiner.int8.onnx")),
        Artifact("tokens.txt", 93_939,
                 "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d", huggingFace("tokens.txt")),
    ]

    public static let parakeet = ModelDescriptor("parakeet-ultra", parakeetArtifacts, "verified", parakeetRevision)

    /// Silero VAD for chunked decoding, installed on its own so an existing Parakeet install stays ready without it.
    public static let sileroVadURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
    public static let sileroVad = Artifact("silero_vad.onnx", 643_854,
                                           "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
                                           sileroVadURL)
    public static let vad = ModelDescriptor("vad", [sileroVad], "verified", sileroVad.sha256)

    /// NVIDIA Nemotron-3-Diarization, exported to INT8 ONNX for sherpa-onnx's Sortformer runtime.
    public static let diarizationSourceRevision = "f667ed73aee57d40cc39428eb768b4fd87a0a29e"
    public static let diarizationURL = "https://dist.gocassini.com/models/files/"
        + "51249515e4cb49dc00c5d5dc0a41ac59aa91157d689ec9586b3f4bf567c3f602/model.int8.onnx.zst"
    public static let diarizationModel = Artifact("nemotron-3-diarization.int8.onnx", 103_941_758,
                                                  "01d1f893f394cc0418ae78425d216ed62c334c0125e650135332a7a8e595f168")

    /// Seekable Zstandard copy of `diarizationModel` on Cassini's model host, verified before decompression.
    public static let diarizationDownload = Artifact("nemotron-3-diarization.int8.onnx.zst", 64_982_914,
                                                     "51249515e4cb49dc00c5d5dc0a41ac59aa91157d689ec9586b3f4bf567c3f602",
                                                     diarizationURL)
    public static let diarization = ModelDescriptor("speaker-models", [diarizationModel], "verified",
                                                    diarizationModel.sha256, download: diarizationDownload)

    /// CAM++ speaker embeddings, fetched verbatim from the pinned sherpa-onnx release. Shares `speaker-models/`.
    public static let voiceprintURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/"
        + "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx"
    public static let voiceprintModel = Artifact("voiceprint-campplus.onnx", 29_596_978,
                                                 "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b",
                                                 voiceprintURL)

    /// The length of a CAM++ print from `voiceprintModel`. A saved voice whose mean has another length cannot be
    /// compared and is stale.
    public static let voiceprintDim = 512

    public static let voiceprint = ModelDescriptor("speaker-models", [voiceprintModel], "verified-voiceprint",
                                                   voiceprintModel.sha256)

    /// The models one consented download installs, in install order. The detector is fetched separately.
    public static let consented: [ModelDescriptor] = [parakeet, diarization, voiceprint]

    /// The hosts a model download may be redirected to (`RedirectPolicy`). An entry `*.example.com` matches every
    /// subdomain of example.com but not example.com itself; any other entry matches exactly. Downloads start only at
    /// the catalogue URLs (huggingface.co, github.com, dist.gocassini.com), and each redirect must be HTTPS to one of
    /// these hosts. Android recorded the redirects on 2026-10-09 (`ModelCatalog.kt`): Hugging Face's Xet CDN
    /// (`us.aws.cdn.hf.co`), its relative `/api/resolve-cache/` on huggingface.co, and GitHub's
    /// `release-assets.githubusercontent.com`; the subdomain entries are wider than that trace because the CDN host
    /// depends on the region.
    public static let downloadHosts = [
        "huggingface.co",
        "*.huggingface.co",
        "*.hf.co",
        "github.com",
        "*.githubusercontent.com",
        "dist.gocassini.com",
    ]

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

    /// Where the models live: Application Support/CassiniModels, excluded from backups (FluidAudio's speaker models
    /// share it until the speaker package replaces them).
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("CassiniModels", isDirectory: true)
    }
}
