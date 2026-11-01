import Foundation
import CassiniNotebook

/// The manifest of the model host (`ModelCatalog.manifestURL`, schema version 2), read before each model download to
/// find where the pinned files are (D4, D53.1; Android's `DistManifest`). It decides nothing else: a model is
/// installed by its pinned pair (`ModelDescriptor.id`, `ModelDescriptor.sourceSha256`) and its files by the pins
/// compiled into `ModelCatalog`, as the desktop does. The app never follows a newer entry.
///
/// `urls` refuses with `PIN_UNAVAILABLE` (`ModelError(.download(.pinUnavailable))`: only a newer Cassini can help, so
/// the banner offers no Retry) when the manifest does not list the pair, when it lists another set of required files
/// for it, when a file's artifact differs from the pins in its key, URL, compressed or decompressed size or SHA-256,
/// encoding or format, or when a file's URL is not one the download's `RedirectPolicy` allows. A manifest that is not
/// schema 2 of this host is refused the same way. The files are verified again after the download.
///
/// Schema 2: `models[]` gives `{id, source_sha256, files[{path, artifact, required}]}`, where `artifact` is the key
/// `models/files/<compressed sha256>/<path>.zst`; `artifacts[]` gives `{key, url, size, sha256, uncompressed_size,
/// uncompressed_sha256, encoding, format_version}`.
public struct DistManifest: Sendable {
    public static let schemaVersion = 2
    /// The manifest is about 45 KB; a longer answer is not read past this (Android's limit).
    public static let maxBytes: Int64 = 1 << 20
    public static let encoding = "zstd-seekable"
    public static let formatVersion = "0.1.0"

    private struct Document: Decodable {
        var schema_version: Int?
        var base_url: String?
        var models: [Model]?
        var artifacts: [Entry]?
    }

    private struct Model: Decodable {
        var id: String?
        var source_sha256: String?
        var files: [File]?
    }

    private struct File: Decodable {
        var path: String?
        var artifact: String?
        var required: Bool?
    }

    private struct Entry: Decodable {
        var key: String?
        var url: String?
        var size: Int64?
        var sha256: String?
        var uncompressed_size: Int64?
        var uncompressed_sha256: String?
        var encoding: String?
        var format_version: String?
    }

    private let document: Document
    /// The origin every artifact URL starts with.
    public let base: String

    private init(document: Document, base: String) { self.document = document; self.base = base }

    /// The manifest in `data`, which must be a schema 2 manifest whose `base_url` is `base` (the model host; a test
    /// host in tests).
    public static func parse(_ data: Data, base: String = ModelCatalog.distBase) throws -> DistManifest {
        guard Int64(data.count) <= maxBytes else { throw refusal("Manifest of \(data.count) bytes") }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) } catch {
            throw refusal("Manifest: \(error)")
        }
        guard document.schema_version == schemaVersion else {
            throw refusal("Manifest schema \(document.schema_version.map(String.init) ?? "none")")
        }
        guard document.base_url == base else { throw refusal("Manifest base \(document.base_url ?? "none")") }
        return DistManifest(document: document, base: base)
    }

    /// The URL of each artifact of `model`, by artifact name, as the manifest gives it, once every check above passed.
    /// `allowed` is the policy of the download that follows.
    public func urls(_ model: ModelDescriptor, allowed: RedirectPolicy = .downloads) throws -> [String: String] {
        let pair = model.pin
        let rows = (document.models ?? []).filter { $0.id == model.id && $0.source_sha256 == model.sourceSha256 }
        guard rows.count == 1, let row = rows.first else { throw Self.refusal("The manifest does not list \(pair)") }
        let files = row.files ?? []
        let required = Set(files.filter { $0.required ?? true }.compactMap(\.path))
        let pinned = Set(model.artifacts.map(\.name))
        guard required == pinned else { throw Self.refusal("\(pair): the manifest lists \(required.sorted())") }
        let entries = Dictionary((document.artifacts ?? []).compactMap { entry in entry.key.map { ($0, entry) } },
                                 uniquingKeysWith: { first, _ in first })
        var urls: [String: String] = [:]
        for artifact in model.artifacts {
            guard let download = artifact.download else { throw Self.refusal("\(pair): \(artifact.name) has no download") }
            let listed = files.filter { $0.path == artifact.name }
            guard listed.count == 1, let file = listed.first else { throw Self.refusal("\(pair): no \(artifact.name)") }
            let key = "models/files/\(download.sha256)/\(artifact.name).zst"
            guard file.artifact == key else { throw Self.refusal("\(pair): \(artifact.name) is \(file.artifact ?? "none")") }
            guard let entry = entries[key] else { throw Self.refusal("\(pair): no artifact \(key)") }
            let url = entry.url ?? ""
            let matches = url == "\(base)/\(key)" && entry.size == download.size && entry.sha256 == download.sha256
                && entry.uncompressed_size == artifact.size && entry.uncompressed_sha256 == artifact.sha256
                && entry.encoding == Self.encoding && entry.format_version == Self.formatVersion
            guard matches else { throw Self.refusal("\(pair): \(artifact.name) differs from the pins") }
            guard let location = URL(string: url), allowed.allows(location) else {
                throw Self.refusal("\(pair): \(artifact.name) is at \(url)")
            }
            urls[artifact.name] = url
        }
        return urls
    }

    private static func refusal(_ reason: String) -> ModelError { ModelError(.download(.pinUnavailable), reason) }
}
