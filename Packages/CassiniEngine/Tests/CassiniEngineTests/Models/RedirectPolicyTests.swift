import Foundation
import Testing
@testable import CassiniEngine
import CassiniNotebook

@Suite struct RedirectPolicyTests {
    private let policy = RedirectPolicy.downloads
    private let start = URL(string: "https://dist.gocassini.com/models/files/x/encoder.int8.onnx.zst")!

    /// The message of the refusal of `location`; records an issue when it is followed.
    @discardableResult private func refused(_ location: String?, hop: Int = 1, by: RedirectPolicy? = nil) -> String {
        do {
            let next = try (by ?? policy).next(from: start, location: location, hop: hop)
            Issue.record("Expected \(location ?? "nil") to be refused, got \(next)")
        } catch let error as ModelError {
            #expect(error.failure == .modelDownload)
            return error.message
        } catch {
            Issue.record("Expected a ModelError, got \(error)")
        }
        return ""
    }

    // ports: RedirectPolicyTest#onlyTheModelHostIsAllowed
    @Test func onlyTheModelHostIsAllowed() throws {
        let target = "https://dist.gocassini.com/models/files/x/model.int8.onnx.zst"
        #expect(try policy.next(from: start, location: target, hop: 1).absoluteString == target)
        #expect(policy.hosts == ["dist.gocassini.com"])
    }

    // ports: RedirectPolicyTest#aRelativeLocationStaysOnTheSameHost
    @Test func aRelativeLocationStaysOnTheSameHost() throws {
        let next = try policy.next(from: start, location: "/models/files/y/tokens.txt.zst?x=1", hop: 1)
        #expect(next.absoluteString == "https://dist.gocassini.com/models/files/y/tokens.txt.zst?x=1")
    }

    // ports: RedirectPolicyTest#everyCatalogueUrlStartsOnAnAllowedHttpsHost
    @Test func everyCatalogueUrlStartsOnAnAllowedHttpsHost() {
        let urls = ModelCatalog.all.flatMap(\.artifacts).compactMap(\.download).map(\.url)
            + [ModelCatalog.manifestURL, ModelCatalog.noticeURL]
        #expect(urls.count == 9)
        for url in urls { #expect(policy.allows(URL(string: url)!), "\(url)") }
    }

    // ports: RedirectPolicyTest#otherHostsAreRefused (the former model hosts of D53.1 among them)
    @Test func otherHostsAreRefused() {
        for target in [
            "https://example.com/model",
            "https://huggingface.co/repo/resolve/rev/encoder.int8.onnx",
            "https://us.aws.cdn.hf.co/xet-bridge-us/a",
            "https://cdn-lfs.huggingface.co/repos/a",
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
            "https://release-assets.githubusercontent.com/github-production-release-asset/x",
            "https://objects.githubusercontent.com/github-production-release-asset-2e65be/x",
            "https://gocassini.com/model",
            "https://other.gocassini.com/model",
            "https://dist.gocassini.com.example.com/model",
            "https://127.0.0.1/model",
        ] {
            refused(target)
        }
    }

    // ports: RedirectPolicyTest#aWildcardEntryMatchesSubdomainsOnly
    @Test func aWildcardEntryMatchesSubdomainsOnly() {
        let wildcard = RedirectPolicy(hosts: ["*.example.com"])
        #expect(wildcard.hostAllowed("cdn.example.com"))
        #expect(wildcard.hostAllowed("a.b.example.com"))
        #expect(!wildcard.hostAllowed("example.com"))
        #expect(!wildcard.hostAllowed("evilexample.com"))
        refused("https://example.com/model", by: wildcard)
    }

    // ports: RedirectPolicyTest#plainHttpIsRefusedEvenToAnAllowedHost
    @Test func plainHttpIsRefusedEvenToAnAllowedHost() {
        #expect(refused("http://dist.gocassini.com/x").contains("http://dist.gocassini.com"))
        refused("ftp://dist.gocassini.com/x")
    }

    // ports: RedirectPolicyTest#aMissingOrBadLocationIsRefused
    @Test func aMissingOrBadLocationIsRefused() {
        refused(nil)
        refused("  ")
        refused("notascheme://x")
    }

    // ports: RedirectPolicyTest#theSixthRedirectIsRefused
    @Test func theSixthRedirectIsRefused() throws {
        _ = try policy.next(from: start, location: "https://dist.gocassini.com/a", hop: RedirectPolicy.maxRedirectsDefault)
        #expect(refused("https://dist.gocassini.com/a", hop: RedirectPolicy.maxRedirectsDefault + 1).contains("More than 5"))
    }

    // ports: RedirectPolicyTest#hostsMatchWithoutCaseOrATrailingDot
    @Test func hostsMatchWithoutCaseOrATrailingDot() {
        #expect(policy.hostAllowed("DIST.GOCASSINI.COM"))
        #expect(policy.hostAllowed("dist.gocassini.com."))
        #expect(!policy.hostAllowed(""))
        #expect(!policy.hostAllowed(nil))
    }
}
