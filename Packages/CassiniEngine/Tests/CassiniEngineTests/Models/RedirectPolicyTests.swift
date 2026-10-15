import Foundation
import Testing
@testable import CassiniEngine
import CassiniNotebook

@Suite struct RedirectPolicyTests {
    private let policy = RedirectPolicy.downloads
    private let start = URL(string: "https://huggingface.co/repo/resolve/rev/encoder.int8.onnx")!

    /// The message of the refusal of `location`; records an issue when it is followed.
    @discardableResult private func refused(_ location: String?, hop: Int = 1) -> String {
        do {
            let next = try policy.next(from: start, location: location, hop: hop)
            Issue.record("Expected \(location ?? "nil") to be refused, got \(next)")
        } catch let error as ModelError {
            #expect(error.failure == .modelDownload)
            return error.message
        } catch {
            Issue.record("Expected a ModelError, got \(error)")
        }
        return ""
    }

    // ports: RedirectPolicyTest#theRecordedRedirectTargetsAreAllowed
    @Test func theRecordedRedirectTargetsAreAllowed() throws {
        for target in [
            "https://us.aws.cdn.hf.co/xet-bridge-us/68a0/bccb?Expires=1&Signature=x",
            "https://cas-bridge.xethub.hf.co/xet-bridge-us/a",
            "https://cdn-lfs.huggingface.co/repos/a",
            "https://release-assets.githubusercontent.com/github-production-release-asset/531380835/x",
            "https://objects.githubusercontent.com/github-production-release-asset-2e65be/x",
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
            "https://dist.gocassini.com/models/files/x/model.int8.onnx.zst",
        ] {
            #expect(try policy.next(from: start, location: target, hop: 1).absoluteString == target)
        }
    }

    // ports: RedirectPolicyTest#aRelativeLocationStaysOnTheSameHost
    @Test func aRelativeLocationStaysOnTheSameHost() throws {
        let next = try policy.next(from: start, location: "/api/resolve-cache/models/repo/rev/tokens.txt?x=1", hop: 1)
        #expect(next.absoluteString == "https://huggingface.co/api/resolve-cache/models/repo/rev/tokens.txt?x=1")
    }

    // ports: RedirectPolicyTest#everyCatalogueUrlStartsOnAnAllowedHttpsHost
    @Test func everyCatalogueUrlStartsOnAnAllowedHttpsHost() {
        let urls = (ModelCatalog.consented + [ModelCatalog.vad]).flatMap { $0.artifacts + [$0.download].compactMap { $0 } }
            .map(\.url).filter { !$0.isEmpty }
        #expect(urls.count == 7)
        for url in urls { #expect(policy.allows(URL(string: url)!), "\(url)") }
    }

    // ports: RedirectPolicyTest#otherHostsAreRefused
    @Test func otherHostsAreRefused() {
        for target in [
            "https://example.com/model",
            "https://evilhuggingface.co/model",
            "https://huggingface.co.example.com/model",
            "https://hf.co/model",
            "https://githubusercontent.com/model",
            "https://gocassini.com/model",
            "https://other.gocassini.com/model",
            "https://127.0.0.1/model",
        ] {
            refused(target)
        }
    }

    // ports: RedirectPolicyTest#plainHttpIsRefusedEvenToAnAllowedHost
    @Test func plainHttpIsRefusedEvenToAnAllowedHost() {
        #expect(refused("http://us.aws.cdn.hf.co/xet").contains("http://us.aws.cdn.hf.co"))
        refused("http://huggingface.co/repo")
        refused("ftp://huggingface.co/repo")
    }

    // ports: RedirectPolicyTest#aMissingOrBadLocationIsRefused
    @Test func aMissingOrBadLocationIsRefused() {
        refused(nil)
        refused("  ")
        refused("notascheme://x")
    }

    // ports: RedirectPolicyTest#theSixthRedirectIsRefused
    @Test func theSixthRedirectIsRefused() throws {
        _ = try policy.next(from: start, location: "https://us.aws.cdn.hf.co/a", hop: RedirectPolicy.maxRedirectsDefault)
        #expect(refused("https://us.aws.cdn.hf.co/a", hop: RedirectPolicy.maxRedirectsDefault + 1).contains("More than 5"))
    }

    // ports: RedirectPolicyTest#hostsMatchWithoutCaseOrATrailingDot
    @Test func hostsMatchWithoutCaseOrATrailingDot() {
        #expect(policy.hostAllowed("US.AWS.CDN.HF.CO"))
        #expect(policy.hostAllowed("dist.gocassini.com."))
        #expect(!policy.hostAllowed(""))
        #expect(!policy.hostAllowed(nil))
    }
}
