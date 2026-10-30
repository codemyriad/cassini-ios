import Foundation
import Testing
@testable import Cassini

/// What App Store Connect reads from the built app: the privacy manifests of the app and of its Live Activity
/// extension, and the export-compliance answer. An iOS-only check; Android has no counterpart.
@Suite struct AppStoreManifestTests {
    /// The required-reason API categories and reasons a bundle's `PrivacyInfo.xcprivacy` declares.
    static func reasons(in bundle: URL) throws -> [String: Set<String>] {
        let data = try Data(contentsOf: bundle.appendingPathComponent("PrivacyInfo.xcprivacy"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        let types = try #require(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var result: [String: Set<String>] = [:]
        for entry in types {
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            result[category] = Set(try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String]))
        }
        return result
    }

    @Test func theAppDeclaresEveryRequiredReasonItUses() throws {
        #expect(try Self.reasons(in: Bundle.main.bundleURL) == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1", "85F4.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]
        ])
    }

    @Test func theLiveActivityExtensionHasItsOwnManifest() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        #expect(try Self.reasons(in: plugins.appendingPathComponent("CassiniActivity.appex")) == [
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"]
        ])
    }

    /// HTTPS through URLSession and CryptoKit hashing only: exempt, so no export-compliance question per build.
    @Test func theAppUsesNoNonExemptEncryption() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool == false)
    }

    /// The home-screen name is the product's (D45), and so is the Live Activity extension's.
    @Test func theAppAndItsExtensionAreNamedCassiniTalk() throws {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Cassini talk")
        #expect(ProductName.full == "Cassini talk")
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let activity = try #require(Bundle(url: plugins.appendingPathComponent("CassiniActivity.appex")))
        #expect(activity.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Cassini talk")
    }
}
