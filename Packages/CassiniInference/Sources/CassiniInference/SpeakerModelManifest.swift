import Foundation
import CryptoKit

/// The speaker models Cassini installs, pinned to one Hugging Face revision, with the size and SHA-256 of every file
/// the offline diarizer reads. An install counts as ready only when the revision marker and every file match.
///
/// FluidAudio (pinned in `Package.swift`) downloads `FluidInference/speaker-diarization-coreml` at the same revision;
/// the hashes were taken from that revision's files and match the `provenance.json` it ships.
public struct SpeakerModelManifest: Hashable, Sendable {
    public struct File: Hashable, Sendable {
        /// Relative to the model folder.
        public var path: String
        public var bytes: Int64
        public var sha256: String
        public init(_ path: String, bytes: Int64, sha256: String) { self.path = path; self.bytes = bytes; self.sha256 = sha256 }
    }

    /// What a check of the installed files found.
    public enum Check: Hashable, Sendable {
        case ready
        /// No file of the manifest is there.
        case missing
        /// Some files are there and match, but not all of them (or the marker is not written yet): an interrupted
        /// install, which the next fetch resumes.
        case incomplete
        /// The marker names another revision, or a file is there with the wrong size or hash: a changed or damaged
        /// install, whose wrong files must go before the next fetch (FluidAudio keeps any file it finds).
        case mismatch
    }

    public var repository: String
    public var revision: String
    /// The folder under the models directory, as FluidAudio names it.
    public var folder: String
    /// FluidAudio's revision marker in the folder.
    public var marker: String
    public var files: [File]

    public init(repository: String, revision: String, folder: String, marker: String, files: [File]) {
        self.repository = repository; self.revision = revision; self.folder = folder; self.marker = marker
        self.files = files
    }

    /// Free space an install asks for beyond the files themselves, for FluidAudio's partial files and the move into
    /// place.
    public static let installHeadroom: Int64 = 32 * 1024 * 1024

    /// The hosts the downloads normally use: Hugging Face, and the storage its redirects go to. FluidAudio owns its
    /// URLSessions, so no redirect policy holds them to these hosts; integrity rests on the pinned revision and the
    /// per-file SHA-256 check.
    public static let downloadHosts = ["huggingface.co", "*.huggingface.co", "*.hf.co"]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// The free space to have before the first byte: the files and `installHeadroom`.
    public var requiredFreeBytes: Int64 { totalBytes + Self.installHeadroom }

    /// The pinned URL of each file.
    public var downloads: [(name: String, url: URL)] {
        files.compactMap { file in
            URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)").map { (file.path, $0) }
        }
    }

    /// Checks the files under `directory/folder` against the manifest: the marker names the revision, and each file
    /// has its size and hash. Hashes every file that is there.
    public func check(in directory: URL) -> Check {
        let root = directory.appendingPathComponent(folder, isDirectory: true)
        let present = files.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.path).path) }
        if present.isEmpty { return .missing }
        if markedWithOtherRevision(root) { return .mismatch }
        for file in present where !Self.matches(file, at: root.appendingPathComponent(file.path)) { return .mismatch }
        return present.count == files.count && markerMatches(in: root) ? .ready : .incomplete
    }

    /// The cheap check of an install already found ready: the marker and every file's size, no hashes.
    public func looksReady(in directory: URL) -> Bool {
        let root = directory.appendingPathComponent(folder, isDirectory: true)
        return markerMatches(in: root) && files.allSatisfy { Self.size(at: root.appendingPathComponent($0.path)) == $0.bytes }
    }

    /// Removes what a fetch must not keep: the whole folder when its marker names another revision, else each file
    /// whose size or hash is wrong. Missing files and FluidAudio's `.partial` files stay, so the fetch resumes.
    public func removeDamaged(in directory: URL) {
        let root = directory.appendingPathComponent(folder, isDirectory: true)
        if markedWithOtherRevision(root) {
            try? FileManager.default.removeItem(at: root)
            return
        }
        for file in files {
            let url = root.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: url.path), !Self.matches(file, at: url) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func marker(in root: URL) -> String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(marker)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func markerMatches(in root: URL) -> Bool { marker(in: root) == revision }

    private func markedWithOtherRevision(_ root: URL) -> Bool { marker(in: root).map { $0 != revision } ?? false }

    private static func size(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    private static func matches(_ file: File, at url: URL) -> Bool {
        guard size(at: url) == file.bytes, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }
}

extension SpeakerModelManifest {
    /// pyannote community-1 segmentation, WeSpeaker embedding and the VBx PLDA, converted to Core ML by FluidInference
    /// (CC-BY-4.0).
    public static let diarizer = SpeakerModelManifest(
        repository: "FluidInference/speaker-diarization-coreml",
        revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232",
        folder: "speaker-diarization",
        marker: ".fluidaudio-revision",
        files: [
            File("Embedding.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
            File("Embedding.mlmodelc/coremldata.bin", bytes: 704, sha256: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
            File("Embedding.mlmodelc/metadata.json", bytes: 2818, sha256: "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"),
            File("Embedding.mlmodelc/model.mil", bytes: 78432, sha256: "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"),
            File("Embedding.mlmodelc/weights/weight.bin", bytes: 13412288, sha256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
            File("FBank.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
            File("FBank.mlmodelc/coremldata.bin", bytes: 853, sha256: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
            File("FBank.mlmodelc/metadata.json", bytes: 3409, sha256: "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"),
            File("FBank.mlmodelc/model.mil", bytes: 15667, sha256: "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"),
            File("FBank.mlmodelc/weights/weight.bin", bytes: 1776896, sha256: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
            File("PldaRho.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"),
            File("PldaRho.mlmodelc/coremldata.bin", bytes: 763, sha256: "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"),
            File("PldaRho.mlmodelc/metadata.json", bytes: 2749, sha256: "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"),
            File("PldaRho.mlmodelc/model.mil", bytes: 7613, sha256: "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"),
            File("PldaRho.mlmodelc/weights/weight.bin", bytes: 200192, sha256: "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"),
            File("Segmentation.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
            File("Segmentation.mlmodelc/coremldata.bin", bytes: 812, sha256: "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
            File("Segmentation.mlmodelc/metadata.json", bytes: 3410, sha256: "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"),
            File("Segmentation.mlmodelc/model.mil", bytes: 43063, sha256: "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"),
            File("Segmentation.mlmodelc/weights/weight.bin", bytes: 5959360, sha256: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"),
            File("plda-parameters.json", bytes: 89416, sha256: "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"),
        ])
}
