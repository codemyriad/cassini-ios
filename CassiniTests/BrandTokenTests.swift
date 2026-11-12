import SwiftUI
import Testing
import CryptoKit
@testable import Cassini

@MainActor @Suite struct BrandTokenTests {
    private struct Pin: Decodable { let repository: String; let commit: String; let path: String; let sha256: String }
    private struct Value: Decodable { let light: String; let dark: String; let status: String }
    private struct Sheet: Decodable { let tokens: [String: Value] }

    @Test func changingStatusColoursDoesNotChangeTheOpenAvatarHues() {
        // Baseline avatar amber before W1: it must not follow the new warning role while L-14 is OPEN.
        for (scheme, expected) in [(ColorScheme.light, [0.55, 0.35, 0.02]), (.dark, [0.98, 0.76, 0.36])] {
            for color in [SpeakerAvatar.tint(name: "Speaker 2", ordinal: 1), Color.savedVoiceTints[2]] {
                let actual = ContrastTests.rgb(color, scheme)
                #expect(abs(actual.red - expected[0]) < 0.0001 && abs(actual.green - expected[1]) < 0.0001
                    && abs(actual.blue - expected[2]) < 0.0001)
            }
        }
    }

    @Test func systemAccentAssetMatchesThePinnedRoleInBothModes() {
        for scheme in [ColorScheme.light, .dark] {
            let asset = ContrastTests.resolved(Color("AccentColor", bundle: CassiniTokens.bundle), scheme)
            let role = ContrastTests.resolved(CassiniTokens.color(.accent), scheme)
            #expect(abs(asset.red - role.red) < 0.0001 && abs(asset.green - role.green) < 0.0001
                && abs(asset.blue - role.blue) < 0.0001 && asset.opacity == role.opacity)
        }
    }

    @Test func vendoredFileMatchesItsPinAndEveryActiveRoleInBothModes() throws {
        let bundle = CassiniTokens.bundle
        let file = try #require(bundle.url(forResource: "tokens", withExtension: "json"))
        let data = try Data(contentsOf: file)
        let pinURL = try #require(bundle.url(forResource: "UPSTREAM", withExtension: "json"))
        let pin = try JSONDecoder().decode(Pin.self, from: Data(contentsOf: pinURL))
        #expect(pin.repository == "https://github.com/codemyriad/cassini-ux")
        #expect(pin.path == "brand/tokens.json" && pin.commit.count == 40)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == pin.sha256)
        let sheet = try JSONDecoder().decode(Sheet.self, from: data)
        let active = sheet.tokens.filter { ["decided", "placeholder"].contains($0.value.status) }
        #expect(Set(CassiniTokens.Role.allCases.map(\.rawValue)) == Set(active.keys), "No missing roles or proposed hues")
        for role in CassiniTokens.Role.allCases {
            let value = try #require(active[role.rawValue])
            for (scheme, hex) in [(ColorScheme.light, value.light), (.dark, value.dark)] {
                let color = ContrastTests.resolved(CassiniTokens.color(role), scheme)
                let components = [color.red, color.green, color.blue, color.opacity]
                let raw = Array(hex.dropFirst())
                var bytes: [UInt8] = []
                for i in stride(from: 0, to: raw.count, by: 2) {
                    bytes.append(try #require(UInt8(String(raw[i..<(i + 2)]), radix: 16)))
                }
                if bytes.count == 3 { bytes.append(255) }
                #expect(components.count == bytes.count)
                for (actual, expected) in zip(components, bytes) {
                    #expect(abs(Double(actual) - Double(expected) / 255) < 0.0001, "\(role) \(scheme) \(hex)")
                }
            }
        }
    }
}
