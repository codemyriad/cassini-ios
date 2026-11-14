import SwiftUI
import Testing
import CryptoKit
import CassiniNotebook
@testable import Cassini

@MainActor @Suite struct BrandTokenTests {
    private struct Pin: Decodable { let repository: String; let commit: String; let path: String; let sha256: String; let files: [String: String] }
    private struct Value: Decodable { let light: String; let dark: String; let status: String }
    private struct Sheet: Decodable { let tokens: [String: Value]; let derived: [String: Value] }

    @Test func speakerAndAvatarRolesUseTheDecidedSixPlusStonePalette() {
        for scheme in [ColorScheme.light, .dark] {
            for ordinal in 0..<13 {
                let slot = ordinal % 6 + 1
                let expected = CassiniTokens.color(CassiniTokens.Role(rawValue: "speaker-\(slot)")!)
                let wash = CassiniTokens.color(CassiniTokens.Role(rawValue: "avatar-\(slot)")!)
                for (actual, reference) in [(SpeakerAvatar(name: "Mira", tint: SpeakerTint.named(ordinal)).tint, expected),
                                            (SpeakerAvatar(name: "Mira", tint: SpeakerTint.named(ordinal)).wash, wash),
                                            (SpeakerAvatar(name: "Speaker 2", tint: SpeakerTint.stone).tint, CassiniTokens.color(.speaker0)),
                                            (SpeakerAvatar(name: "Speaker 2", tint: SpeakerTint.stone).wash, CassiniTokens.color(.avatar0))] {
                    let a = ContrastTests.resolved(actual, scheme), b = ContrastTests.resolved(reference, scheme)
                    #expect(a.red == b.red && a.green == b.green && a.blue == b.blue && a.opacity == b.opacity)
                }
            }
        }
    }

    @Test func forcedDarkRecordingUsesOnlyTheDarkBrandRolesInEitherAppearance() {
        let pairs: [(Color, CassiniTokens.Role)] = [(.recordingBackground, .ground), (.recordingText, .ink),
            (.recordingSecondary, .ink2), (.recordingLine, .line),
            (.recordingAccent, .recordInk), (RecordingActivityColors.background, .ground),
            (RecordingActivityColors.secondary, .ink2)]
        for scheme in [ColorScheme.light, .dark] {
            let wash = CassiniTokens.color(.ink, forcedDark: true).opacity(0.1)
            #expect(ContrastTests.resolved(Color.recordingButtonWash, scheme) == ContrastTests.resolved(wash, scheme))
            #expect(ContrastTests.resolved(RecordingActivityColors.button, scheme) == ContrastTests.resolved(wash, scheme))
            // L-08: the night ground is the canonical dark ground #0D1015 in both appearances.
            let ground = ContrastTests.resolved(Color.recordingBackground, scheme)
            #expect(Int((ground.red * 255).rounded()) == 0x0D && Int((ground.green * 255).rounded()) == 0x10
                && Int((ground.blue * 255).rounded()) == 0x15)
            for (color, role) in pairs {
                let actual = ContrastTests.resolved(color, scheme)
                let expected = ContrastTests.resolved(CassiniTokens.color(role), .dark)
                #expect(actual.red == expected.red && actual.green == expected.green
                    && actual.blue == expected.blue && actual.opacity == expected.opacity)
            }
        }
    }


    @Test func derivedRestingCardAndNeutralPillsUseTheDecidedRoles() throws {
        let file = try #require(CassiniTokens.bundle.url(forResource: "tokens", withExtension: "json"))
        let sheet = try JSONDecoder().decode(Sheet.self, from: Data(contentsOf: file))
        #expect(Set(sheet.derived.keys) == ["card-rest"])
        let card = try #require(sheet.derived["card-rest"])
        #expect(card.status == "decided")
        for (scheme, hex) in [(ColorScheme.light, card.light), (.dark, card.dark)] {
            let actual = ContrastTests.resolved(Color.cardRest, scheme)
            let raw = Array(hex.dropFirst())
            let bytes = try stride(from: 0, to: raw.count, by: 2).map { offset in
                try #require(UInt8(String(raw[offset..<(offset + 2)]), radix: 16))
            }
            for (component, byte) in zip([actual.red, actual.green, actual.blue], bytes) {
                #expect(abs(Double(component) - Double(byte) / 255) < 0.0001)
            }
            #expect(actual.opacity == 1)
            for status in [LibraryRow.Status.transcribing, .queued, .audioOnly] {
                let pill = PhoneStatusBadgeView(status: status).colors
                #expect(ContrastTests.resolved(pill.tint, scheme) == ContrastTests.resolved(Color.ink.opacity(0.1), scheme))
                #expect(ContrastTests.contrast(pill.ink, on: [Color.cardRest, pill.tint], scheme) >= 4.5)
            }
            let outline = PhoneStatusBadgeView(status: .newerFormat).colors
            #expect(ContrastTests.resolved(outline.tint, scheme).opacity == 0)
            #expect(ContrastTests.resolved(outline.ink, scheme) == ContrastTests.resolved(Color.ink2, scheme))
            for status in [LibraryRow.Status.failed, .unplayable, .unreadable] {
                let problem = PhoneStatusBadgeView(status: status).colors
                #expect(ContrastTests.resolved(problem.ink, scheme) == ContrastTests.resolved(Color.error, scheme))
                #expect(ContrastTests.resolved(problem.tint, scheme) == ContrastTests.resolved(Color.errorTint, scheme))
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
        #expect(pin.commit == "5e0c34e0f1bb390298dabdf4eedc494e933fd329")
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == pin.sha256)
        let markURL = try #require(bundle.url(forResource: "saturn-nav", withExtension: "svg"))
        let mark = try Data(contentsOf: markURL)
        #expect(SHA256.hash(data: mark).map { String(format: "%02x", $0) }.joined() == pin.files["brand/mark/saturn-nav.svg"])
        #expect(UIImage(named: "SaturnNav", in: bundle, compatibleWith: nil) != nil)
        let sheet = try JSONDecoder().decode(Sheet.self, from: data)
        let active = sheet.tokens.filter { $0.value.status == "decided" }
        #expect(active.count == 53 && active.count == sheet.tokens.count, "All 53 pinned roles are decided")
        #expect(Set(CassiniTokens.Role.allCases.map(\.rawValue)) == Set(active.keys), "No missing or extra decided roles")
        // These four desktop roles are generated/tested but unused by iOS/iPadOS, by name, never a wildcard.
        let desktopUnused: Set<CassiniTokens.Role> = [.sidebar, .sidebarMac, .field, .fieldLine]
        #expect(desktopUnused.count == 4 && desktopUnused.allSatisfy { active[$0.rawValue] != nil })
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
