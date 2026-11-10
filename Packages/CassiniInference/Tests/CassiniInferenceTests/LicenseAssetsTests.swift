import Foundation
import Testing
import CassiniEngine
import CassiniInference
import CassiniNotebook

/// The app bundles copies of the licence, the notices and the privacy text that Licenses shows; they must not drift
/// from the repository, the packages Cassini links or the models it downloads.
@Suite struct LicenseAssetsTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let licenses = root.appendingPathComponent("Cassini/Resources/Licenses", isDirectory: true)

    private static func read(_ name: String) throws -> String {
        try String(contentsOf: licenses.appendingPathComponent(name), encoding: .utf8)
    }

    /// The host's notices as an installed model keeps them (a stand-in: the file is downloaded, never bundled).
    private static let notice = "Parakeet Ultra 0.6B\n==================\nCC BY 4.0\n\nOpenMDW License Agreement, version 1.1"

    private let texts = LicenseTexts(downloads: ModelCatalog.downloads, notice: { LicenseAssetsTests.notice },
                                     read: LicenseAssetsTests.read)

    // ports: LicenseAssetsTest#thirdPartyNoticesMatchTheRepository (iOS bundles the licence, not the notices, twice)
    @Test func theBundledLicenceIsTheRepositorysLicense() throws {
        let repository = try String(contentsOf: Self.root.appendingPathComponent("LICENSE"), encoding: .utf8)
        #expect(try Self.read(LicenseTexts.gpl) == repository)
    }

    // ports: LicenseAssetsTest#privacyPolicyListsEachDownloadHost
    @Test func thePrivacyTextListsEachDownloadHost() throws {
        let privacy = try Self.read(LicenseTexts.privacy)
        for host in ModelCatalog.downloadHosts { #expect(privacy.contains("- `\(host)`"), "\(host)") }
    }

    // ports: LicenseAssetsTest#nativeDependenciesMatchTheBuildManifest
    @Test func theNoticesNameEveryPackageCassiniLinks() throws {
        let notices = try Self.read(LicenseTexts.notices)
        let resolved = try String(contentsOf: Self.root.appendingPathComponent("Package.resolved"), encoding: .utf8)
        let identities = resolved.components(separatedBy: "\"identity\" : \"").dropFirst()
            .compactMap { $0.split(separator: "\"").first.map(String.init) }
        #expect(!identities.isEmpty)
        for identity in identities {
            #expect(notices.lowercased().contains(identity), "ThirdPartyNotices.txt does not name \(identity)")
        }
        #expect(notices.contains("libopus"))
    }

    /// Every entry of the native lock is in the runtime the app links (sherpa-onnx and the sources it is built from,
    /// ONNX Runtime), so the notices name each one, and each source archive's version; an `-ios` entry is the iOS
    /// build of the entry without the suffix. ONNX Runtime's own notices, for the libraries inside it, are bundled.
    @Test func theNoticesNameEveryNativeComponentTheRuntimeContains() throws {
        let notices = try Self.read(LicenseTexts.notices)
        let data = try Data(contentsOf: Self.root.appendingPathComponent("scripts/native-dependencies.json"))
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(entries.count >= 12)
        for entry in entries {
            let name = try #require(entry["name"])
            let component = name.hasSuffix("-ios") ? String(name.dropLast(4)) : name
            #expect(notices.lowercased().contains(component), "ThirdPartyNotices.txt does not name \(component)")
            guard entry["file"] != nil, !name.hasSuffix("-ios"), var version = entry["version"] else { continue }
            if version.hasPrefix("\(name)-") { version.removeFirst(name.count + 1) }
            if version.hasPrefix("v") { version.removeFirst() }
            #expect(notices.contains(version), "ThirdPartyNotices.txt does not give \(name)'s version \(version)")
        }
        let onnx = try Self.read(LicenseTexts.onnxRuntimeNotices)
        #expect(onnx.hasPrefix("THIRD PARTY SOFTWARE NOTICES AND INFORMATION"))
        for library in ["protobuf", "abseil", "re2", "flatbuffers", "cpuinfo"] {
            #expect(onnx.lowercased().contains(library), "ONNX Runtime's notices do not name \(library)")
        }
    }

    /// The diarization provenance names the sherpa-onnx release the runtime is built from (the lock), and the notices
    /// name the Zstandard release Package.swift pins.
    @Test func theDiarizationBackendNamesThePinnedRuntime() throws {
        let lock = try String(contentsOf: Self.root.appendingPathComponent("scripts/native-dependencies.json"), encoding: .utf8)
        // The D16 fork's tag, 1.13.7-cassini-parakeet-ultra-v1 at 0c2ee3f.
        #expect(lock.contains("\"version\": \"\(TranscriptProvenance.sherpaVersion)-cassini-"))
        #expect(TranscriptProvenance.SpeakerDiarization.sortformerBackend.hasPrefix("sherpa-onnx \(TranscriptProvenance.sherpaVersion) "))
        let package = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(package.contains("facebook/zstd.git\", revision: \"\(ZstdDecompressor.revision)\""))
        #expect(try Self.read(LicenseTexts.notices).contains("Zstandard 1.5.7"))
        #expect(!package.contains("FluidAudio"))
    }

    /// D4: the model host's NOTICE.txt comes with the downloaded models and is reachable from About. "Model notices"
    /// shows it from an installed revision, after the notices' own sections; before the first download it is not
    /// there, and the section says where it will come from.
    @Test func theModelNoticesAreTheHostsNoticeOfAnInstalledModel() throws {
        let models = try texts.text(.models)
        #expect(models.hasSuffix(Self.notice))
        let before = try LicenseTexts(downloads: ModelCatalog.downloads, read: Self.read).text(.models)
        #expect(!before.contains(Self.notice))
        #expect(before.contains("Downloaded models\n"))
        #expect(before.contains("NOTICE.txt") && before.contains("dist.gocassini.com"))
    }

    /// The notices are read from the newest installed revision under the model root, and none is there before a model
    /// is installed.
    @Test func theNoticeShownIsAnInstalledRevisionsCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ModelCatalog.installedNotice(in: root) == nil)
        let model = ModelCatalog.vad
        let directory = model.directory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for artifact in model.artifacts {
            let url = directory.appendingPathComponent(artifact.name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(artifact.size))
            try handle.close()
        }
        #expect(ModelCatalog.installedNotice(in: root) == nil, "no notices, no install")
        try Data(Self.notice.utf8).write(to: directory.appendingPathComponent(ModelDescriptor.noticeFile))
        #expect(ModelCatalog.installedNotice(in: root)?.path == model.path(in: root, ModelDescriptor.noticeFile))
    }

    /// D53.1: the models come only from the model host. No URL Cassini downloads, no host it may reach and no line of
    /// the privacy text's network section names Hugging Face or GitHub; the CI list agrees.
    @Test func noModelIsDownloadedFromHuggingFaceOrGitHub() throws {
        let former = ["huggingface.co", "hf.co", "github.com", "githubusercontent.com"]
        for download in ModelCatalog.downloads {
            #expect(download.url.host() == ModelCatalog.distHost, "\(download.url)")
        }
        #expect(ModelCatalog.downloadHosts == [ModelCatalog.distHost])
        let network = LicenseTexts.section(try Self.read(LicenseTexts.privacy), heading: LicenseTexts.networkHeading)
        let ci = try String(contentsOf: Self.root.appendingPathComponent("scripts/ci-models.json"), encoding: .utf8)
        for host in former {
            #expect(!network.contains(host), "Privacy.txt names \(host)")
            #expect(!ci.contains(host), "ci-models.json names \(host)")
        }
        let sources = try texts.text(.modelSources)
        for host in former { #expect(!sources.contains("://\(host)") && !sources.contains(".\(host)/"), "\(host)") }
    }

    // ports: LicensesViewModelTest#everyRowHasItsTextFromTheAssets
    @Test func everyRowHasItsTextFromTheBundledFiles() throws {
        #expect(try texts.text(.cassini).contains("GNU GENERAL PUBLIC LICENSE"))
        let thirdParty = try texts.text(.thirdParty)
        #expect(thirdParty.hasPrefix("sherpa-onnx"))
        for name in ["ONNX Runtime", "Zstandard", "swift-opus", "libopus", "Eigen", "Mozilla Public License", "KISS FFT"] {
            #expect(thirdParty.contains(name), "\(name)")
        }
        #expect(thirdParty.contains("ONNX Runtime third-party notices\n\nTHIRD PARTY SOFTWARE NOTICES"), "ONNX Runtime's own")
        #expect(!thirdParty.contains("Downloaded models"), "the model notices have their own row")
        #expect(!thirdParty.contains("OpenMDW"), "the diarizer's licence comes with the host's notices")
        let models = try texts.text(.models)
        #expect(models.hasPrefix("Speech recognition models\n"))
        #expect(models.contains("Downloaded models\n"))
        #expect(models.contains("Included in the app\n\n") && models.contains("Whistle weights and Needle engine"),
                "the bundled models")
        #expect(!thirdParty.contains("Included in the app") && !thirdParty.contains("Whistle weights"))
        #expect(models.contains("OpenMDW License Agreement"), "from the installed notices")
        #expect(!thirdParty.contains("FluidAudio") && !models.contains("pyannote"))
        let sources = try texts.text(.modelSources)
        #expect(sources.hasPrefix("Network\n"))
        for host in ModelCatalog.downloadHosts { #expect(sources.contains(host)) }
        for download in ModelCatalog.downloads { #expect(sources.contains(download.url.absoluteString)) }
        #expect(sources.contains(ModelCatalog.manifestURL) && sources.contains(ModelCatalog.noticeURL))
        let privacy = try texts.text(.privacy)
        #expect(privacy.hasPrefix("Privacy\n"))
        #expect(!privacy.contains("## "))
        #expect(try texts.text(.sourceCode) == sourceCodeURL.absoluteString)
    }
}
