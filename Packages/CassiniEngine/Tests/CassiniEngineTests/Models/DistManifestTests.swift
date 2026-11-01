import Foundation
import Testing
@testable import CassiniEngine
import CassiniNotebook

/// The model host's manifest against the compiled pins (Android's DistManifestTest). `manifest-2026-10-27.json` is the
/// published manifest of that day, byte for byte (the same file as Android's fixture): every model of the catalog must
/// resolve in it, and any change to a pinned pair or file must refuse the download with PIN_UNAVAILABLE, never with
/// File check failed (no file was checked) and never with a Retry that cannot help.
@Suite struct DistManifestTests {
    private static let published: Data = {
        let url = Bundle.module.url(forResource: "manifest-2026-10-27", withExtension: "json", subdirectory: "model-host")!
        return try! Data(contentsOf: url)
    }()

    /// The refusal of `data` for `model`; records an issue when the manifest is taken.
    private func refusal(_ data: Data, _ model: ModelDescriptor, _ policy: RedirectPolicy = .downloads) -> ModelError? {
        do {
            _ = try DistManifest.parse(data).urls(model, allowed: policy)
            Issue.record("The manifest must refuse \(model.pin)")
        } catch let error as ModelError {
            return error
        } catch {
            Issue.record("Expected a ModelError, got \(error)")
        }
        return nil
    }

    private func refused(_ data: Data, _ model: ModelDescriptor, _ comment: Comment? = nil) {
        #expect(refusal(data, model)?.failure == .download(.pinUnavailable), comment)
    }

    /// The published manifest with `change` applied to its JSON.
    private func edited(_ change: (inout [String: Any]) -> Void) -> Data {
        var json = try! JSONSerialization.jsonObject(with: Self.published) as! [String: Any]
        change(&json)
        return try! JSONSerialization.data(withJSONObject: json)
    }

    /// Applies `change` to the model row `id` of `json`.
    private static func model(_ json: inout [String: Any], _ id: String, _ change: (inout [String: Any]) -> Void) {
        var models = json["models"] as! [[String: Any]]
        let index = models.firstIndex { $0["id"] as? String == id }!
        change(&models[index])
        json["models"] = models
    }

    /// Applies `change` to the artifact entry whose compressed SHA-256 is `sha`.
    private static func artifact(_ json: inout [String: Any], _ sha: String, _ change: (inout [String: Any]) -> Void) {
        var artifacts = json["artifacts"] as! [[String: Any]]
        let index = artifacts.firstIndex { $0["sha256"] as? String == sha }!
        change(&artifacts[index])
        json["artifacts"] = artifacts
    }

    // ports: DistManifestTest#everyPinnedModelResolvesToItsFilesOnTheModelHost
    @Test func everyPinnedModelResolvesToItsFilesOnTheModelHost() throws {
        let manifest = try DistManifest.parse(Self.published)
        for model in ModelCatalog.all {
            let urls = try manifest.urls(model)
            #expect(Set(urls.keys) == Set(model.artifacts.map(\.name)))
            for artifact in model.artifacts {
                // The manifest's URL is the content-addressed location the catalog names for the notices and CI.
                #expect(urls[artifact.name] == artifact.download?.url)
                #expect(urls[artifact.name]?.hasPrefix("https://dist.gocassini.com/models/files/") == true)
            }
        }
    }

    // ports: DistManifestTest#aPairTheManifestNoLongerListsIsNotDownloaded
    @Test func aPairTheManifestNoLongerListsIsNotDownloaded() throws {
        // A newer export under the same id: the app keeps its pinned source hash and refuses; there is no "latest".
        let newer = edited { Self.model(&$0, "silero-vad") { $0["source_sha256"] = String(repeating: "0", count: 64) } }
        let error = refusal(newer, ModelCatalog.vad)
        #expect(error?.failure == .download(.pinUnavailable))
        #expect(error?.message.contains("does not list silero-vad@") == true)
        let gone = edited { json in
            json["models"] = (json["models"] as! [[String: Any]]).filter { $0["id"] as? String != "silero-vad" }
        }
        refused(gone, ModelCatalog.vad)
        // Other models are not affected.
        _ = try DistManifest.parse(gone).urls(ModelCatalog.parakeet)
        // Two rows with the pinned pair are not one pin either.
        let twice = edited { json in
            let row = (json["models"] as! [[String: Any]]).first { $0["id"] as? String == "silero-vad" }!
            json["models"] = (json["models"] as! [[String: Any]]) + [row]
        }
        refused(twice, ModelCatalog.vad)
    }

    // ports: DistManifestTest#anArtifactThatDisagreesWithAnyPinIsNotDownloaded (iOS also checks the URL, the
    // encoding and the format version of each entry)
    @Test func anArtifactThatDisagreesWithAnyPinIsNotDownloaded() throws {
        let encoder = ModelCatalog.parakeetArtifacts[0]
        let sha = try #require(encoder.download).sha256
        let changes: [(String, (inout [String: Any]) -> Void)] = [
            ("size", { $0["size"] = 452_306_706 }),
            ("sha256", { $0["sha256"] = String(repeating: "1", count: 64) }),
            ("uncompressed_size", { $0["uncompressed_size"] = encoder.size - 1 }),
            ("uncompressed_sha256", { $0["uncompressed_sha256"] = String(repeating: "2", count: 64) }),
            ("no uncompressed_sha256", { $0["uncompressed_sha256"] = nil }),
            ("url", { $0["url"] = "https://dist.gocassini.com/models/files/\(sha)/other.onnx.zst" }),
            ("encoding", { $0["encoding"] = "zstd" }),
            ("format_version", { $0["format_version"] = "0.2.0" }),
            ("key", { $0["key"] = "models/files/\(sha)/other.onnx.zst" }),
        ]
        for (name, change) in changes {
            refused(edited { Self.artifact(&$0, sha, change) }, ModelCatalog.parakeet, "\(name)")
        }
    }

    // ports: DistManifestTest#aFileListThatDiffersFromThePinsIsNotDownloaded
    @Test func aFileListThatDiffersFromThePinsIsNotDownloaded() throws {
        let otherArtifact = edited { json in
            Self.model(&json, "parakeet-ultra-0.6b-int8") { row in
                var files = row["files"] as! [[String: Any]]
                files[0]["artifact"] = "models/files/\(String(repeating: "3", count: 64))/encoder.int8.onnx.zst"
                row["files"] = files
            }
        }
        refused(otherArtifact, ModelCatalog.parakeet)
        func extra(required: Bool) -> Data {
            edited { json in
                Self.model(&json, "silero-vad") { row in
                    row["files"] = (row["files"] as! [[String: Any]])
                        + [["path": "extra.onnx", "artifact": "models/files/x/extra.onnx.zst", "required": required]]
                }
            }
        }
        refused(extra(required: true), ModelCatalog.vad)
        _ = try DistManifest.parse(extra(required: false)).urls(ModelCatalog.vad)
        let missing = edited { json in
            Self.model(&json, "parakeet-ultra-0.6b-int8") { row in
                row["files"] = Array((row["files"] as! [[String: Any]]).dropLast())
            }
        }
        refused(missing, ModelCatalog.parakeet)
    }

    // ports: DistManifestTest#aFileElsewhereThanTheModelHostIsNotDownloaded
    @Test func aFileElsewhereThanTheModelHostIsNotDownloaded() throws {
        let sha = try #require(ModelCatalog.sileroVad.download).sha256
        for url in [
            "http://dist.gocassini.com/models/files/\(sha)/silero_vad.onnx.zst",
            "https://example.com/models/files/\(sha)/silero_vad.onnx.zst",
            "https://dist.gocassini.com.example.com/models/files/\(sha)/silero_vad.onnx.zst",
            "https://huggingface.co/models/files/\(sha)/silero_vad.onnx.zst",
            "not a url",
        ] {
            refused(edited { Self.artifact(&$0, sha) { $0["url"] = url } }, ModelCatalog.vad, "\(url)")
        }
        // A manifest whose files are on the host but a download policy that does not allow it.
        #expect(refusal(Self.published, ModelCatalog.vad, RedirectPolicy(hosts: ["example.com"]))?.failure
                == .download(.pinUnavailable))
    }

    // ports: DistManifestTest#onlyASchemaTwoManifestIsRead (iOS also requires the host's base_url and a manifest
    // under 1 MiB)
    @Test func onlyASchemaTwoManifestIsRead() throws {
        for data in [
            edited { $0["schema_version"] = 3 },
            edited { $0["schema_version"] = nil },
            edited { $0["base_url"] = "https://example.com" },
            Data("<html>".utf8),
            Data(count: Int(DistManifest.maxBytes) + 1),
        ] {
            do {
                _ = try DistManifest.parse(data)
                Issue.record("Read \(data.count) bytes")
            } catch let error as ModelError {
                #expect(error.failure == .download(.pinUnavailable))
            }
        }
        refused(edited { $0["artifacts"] = nil }, ModelCatalog.vad)
    }

    /// The refusal maps to its own banner, not File check failed (D53.1: only an update of Cassini helps).
    @Test func aRefusalIsPinUnavailableNotAFailedFileCheck() throws {
        let error = try #require(refusal(edited { $0["models"] = [] }, ModelCatalog.parakeet))
        #expect(ModelInstaller.downloadError(error, online: { true }) == .pinUnavailable)
        #expect(Notices.download(.pinUnavailable).kind == .dlPinUnavailable)
        #expect(Notices.download(.pinUnavailable).actions.isEmpty)
    }
}
