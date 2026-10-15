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

    private let texts = LicenseTexts(downloads: SpeakerModels.downloads, read: LicenseAssetsTests.read)

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

    /// The diarization provenance names the sherpa-onnx release the runtime is built from (the lock), and the notices
    /// name the Zstandard release Package.swift pins.
    @Test func theDiarizationBackendNamesThePinnedRuntime() throws {
        let lock = try String(contentsOf: Self.root.appendingPathComponent("scripts/native-dependencies.json"), encoding: .utf8)
        #expect(lock.contains("\"version\": \"\(TranscriptProvenance.sherpaVersion)+"))
        #expect(TranscriptProvenance.SpeakerDiarization.sortformerBackend.hasPrefix("sherpa-onnx \(TranscriptProvenance.sherpaVersion) "))
        let package = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(package.contains("facebook/zstd.git\", revision: \"\(ZstdDecompressor.revision)\""))
        #expect(try Self.read(LicenseTexts.notices).contains("Zstandard 1.5.7"))
        #expect(!package.contains("FluidAudio"))
    }

    @Test func theModelNoticesNameThePinnedRevision() throws {
        let models = try texts.text(.models)
        #expect(models.contains(ModelCatalog.diarizationSourceRevision))
        #expect(models.contains("nvidia/Nemotron-3-Diarization"))
        #expect(models.contains("3dspeaker_speech_campplus_sv_en_voxceleb_16k"))
    }

    // ports: LicensesViewModelTest#everyRowHasItsTextFromTheAssets
    @Test func everyRowHasItsTextFromTheBundledFiles() throws {
        #expect(try texts.text(.cassini).contains("GNU GENERAL PUBLIC LICENSE"))
        let thirdParty = try texts.text(.thirdParty)
        #expect(thirdParty.hasPrefix("sherpa-onnx"))
        for name in ["ONNX Runtime", "Zstandard", "swift-opus", "libopus"] { #expect(thirdParty.contains(name), "\(name)") }
        #expect(!thirdParty.contains("Downloaded speaker models"), "the model notices have their own row")
        let models = try texts.text(.models)
        #expect(models.hasPrefix("Speech recognition models\n"))
        #expect(models.contains("Downloaded speaker models\n"))
        #expect(models.contains("OpenMDW License Agreement"))
        #expect(!thirdParty.contains("FluidAudio") && !models.contains("pyannote"))
        let sources = try texts.text(.modelSources)
        #expect(sources.hasPrefix("Network\n"))
        for host in ModelCatalog.downloadHosts { #expect(sources.contains(host)) }
        let first = try #require(SpeakerModels.downloads.first)
        #expect(sources.contains(first.url.absoluteString))
        let privacy = try texts.text(.privacy)
        #expect(privacy.hasPrefix("Privacy\n"))
        #expect(!privacy.contains("## "))
        #expect(try texts.text(.sourceCode) == sourceCodeURL.absoluteString)
    }
}
