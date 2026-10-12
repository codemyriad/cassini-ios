import Foundation
import Testing
import CassiniEngine
import CassiniInference

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

    private let texts = LicenseTexts(downloads: SpeakerModelManifest.diarizer.downloads, read: LicenseAssetsTests.read)

    // ports: LicenseAssetsTest#thirdPartyNoticesMatchTheRepository (iOS bundles the licence, not the notices, twice)
    @Test func theBundledLicenceIsTheRepositorysLicense() throws {
        let repository = try String(contentsOf: Self.root.appendingPathComponent("LICENSE"), encoding: .utf8)
        #expect(try Self.read(LicenseTexts.gpl) == repository)
    }

    // ports: LicenseAssetsTest#privacyPolicyListsEachDownloadHost
    @Test func thePrivacyTextListsEachDownloadHost() throws {
        let privacy = try Self.read(LicenseTexts.privacy)
        for host in SpeakerModelManifest.downloadHosts { #expect(privacy.contains("- `\(host)`"), "\(host)") }
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

    @Test func theModelNoticesNameThePinnedRevision() throws {
        let models = try texts.text(.models)
        #expect(models.contains(SpeakerModelManifest.diarizer.revision))
        #expect(models.contains(SpeakerModelManifest.diarizer.repository))
    }

    // ports: LicensesViewModelTest#everyRowHasItsTextFromTheAssets
    @Test func everyRowHasItsTextFromTheBundledFiles() throws {
        #expect(try texts.text(.cassini).contains("GNU GENERAL PUBLIC LICENSE"))
        let thirdParty = try texts.text(.thirdParty)
        #expect(thirdParty.hasPrefix("FluidAudio"))
        for name in ["swift-opus", "libopus", "fastcluster", "VBx"] { #expect(thirdParty.contains(name), "\(name)") }
        #expect(!thirdParty.contains("Downloaded speaker models"), "the model notices have their own row")
        let models = try texts.text(.models)
        #expect(models.hasPrefix("Speech recognition models\n"))
        #expect(models.contains("Downloaded speaker models\n"))
        #expect(models.contains("creativecommons.org/licenses/by/4.0"))
        let sources = try texts.text(.modelSources)
        #expect(sources.hasPrefix("Network\n"))
        for host in SpeakerModelManifest.downloadHosts { #expect(sources.contains(host)) }
        let first = try #require(SpeakerModelManifest.diarizer.downloads.first)
        #expect(sources.contains(first.url.absoluteString))
        let privacy = try texts.text(.privacy)
        #expect(privacy.hasPrefix("Privacy\n"))
        #expect(!privacy.contains("## "))
        #expect(try texts.text(.sourceCode) == sourceCodeURL.absoluteString)
    }
}
