import SwiftUI
import Testing
import CryptoKit
@testable import Cassini

@MainActor @Suite struct BrandTokenTests {
    private struct Pin: Decodable { let repository: String; let commit: String; let path: String; let sha256: String }
    private struct Value: Decodable { let light: String; let dark: String; let status: String }
    private struct Sheet: Decodable { let tokens: [String: Value] }

    @Test func speakerAndAvatarRolesUseTheDecidedSixPlusStonePalette() {
        for scheme in [ColorScheme.light, .dark] {
            for ordinal in 0..<13 {
                let slot = ordinal % 6 + 1
                let expected = CassiniTokens.color(CassiniTokens.Role(rawValue: "speaker-\(slot)")!)
                let wash = CassiniTokens.color(CassiniTokens.Role(rawValue: "avatar-\(slot)")!)
                for (actual, reference) in [(SpeakerAvatar.tint(name: "Mira", ordinal: ordinal), expected),
                                            (SpeakerAvatar.wash(name: "Mira", ordinal: ordinal), wash),
                                            (SpeakerAvatar.tint(name: "Speaker 2", ordinal: ordinal), CassiniTokens.color(.speaker0)),
                                            (SpeakerAvatar.wash(name: "Speaker 2", ordinal: ordinal), CassiniTokens.color(.avatar0))] {
                    let a = ContrastTests.resolved(actual, scheme), b = ContrastTests.resolved(reference, scheme)
                    #expect(a.red == b.red && a.green == b.green && a.blue == b.blue && a.opacity == b.opacity)
                }
            }
        }
    }

    @Test func forcedDarkRecordingUsesOnlyTheDarkBrandRolesInEitherAppearance() {
        let pairs: [(Color, CassiniTokens.Role)] = [(.recordingBackground, .ground), (.recordingText, .ink),
            (.recordingSecondary, .ink2), (.recordingButtonWash, .neutralTint), (.recordingLine, .line),
            (.recordingAccent, .recordInk), (RecordingActivityColors.background, .ground),
            (RecordingActivityColors.secondary, .ink2), (RecordingActivityColors.button, .neutralTint)]
        for scheme in [ColorScheme.light, .dark] {
            for (color, role) in pairs {
                let actual = ContrastTests.resolved(color, scheme)
                let expected = ContrastTests.resolved(CassiniTokens.color(role), .dark)
                #expect(actual.red == expected.red && actual.green == expected.green
                    && actual.blue == expected.blue && actual.opacity == expected.opacity)
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
        #expect(pin.path == "brand/tokens.json")
        #expect(pin.commit == "e244ad6a830e4ef77d87fb452143f7100c767139")
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == pin.sha256)
        let sheet = try JSONDecoder().decode(Sheet.self, from: data)
        let active = sheet.tokens.filter { $0.value.status == "decided" }
        #expect(active.count == 49 && active.count == sheet.tokens.count, "All 49 pinned roles are decided")
        #expect(Set(CassiniTokens.Role.allCases.map(\.rawValue)) == Set(active.keys), "No missing or extra decided roles")
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
