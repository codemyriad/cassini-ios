@testable import CassiniCore
import Foundation
import Testing

@Suite struct CassiniPayloadTests {
    // ports: CassiniDocumentTest#strictPayloadRejectsDuplicatesTrailingGzipAndBadLengths
    @Test func strictPayloadRejectsDuplicatesTrailingGzipAndBadLengths() throws {
        for text in [#"{"x":1,"x":2}"#, #"{"a":{"x":1,"x":2}}"#, #"{"x":NaN}"#, #"{"x":01}"#, "{'x':1}"] {
            #expect(throws: CassiniError.self, "\(text)") { try JSON.parseObject(text) }
        }
        let (ref, tags) = try CassiniPayload.encode(prefix: "TEST_", mime: CassiniPayload.mime, text: #"{"ok":true}"#)
        let chunk = String(tags.last!.split(separator: "=", maxSplits: 1)[1])
        #expect(try CassiniPayload.decode([chunk], rawBytes: ref.number("rawBytes"), gzipBytes: ref.number("gzipBytes"), sha256: ref.string("sha256")) == #"{"ok":true}"#)
        let compressed = try ref.number("gzipBytes")
        var standard = chunk.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        let raw = [UInt8](Data(base64Encoded: standard)!)
        let doubled = CassiniPayload.base64url(raw + raw)
        #expect(throws: CassiniError.self) {
            try CassiniPayload.decode([doubled], rawBytes: ref.number("rawBytes"), gzipBytes: compressed * 2, sha256: ref.string("sha256"))
        }
    }

    /** Swift reads "\r\n" as one Character, so a filter over Characters kept a lone LF or CR in the chunk text. */
    @Test(arguments: ["\n", "\r", "\r\n", " \t", "\n\n\r"])
    func whitespaceInsideChunksIsStripped(_ whitespace: String) throws {
        let text = #"{"words":["# + String(repeating: "\"ciao\",", count: 40) + #""fine"]}"#
        let (ref, tags) = try CassiniPayload.encode(prefix: "TEST_", mime: CassiniPayload.mime, text: text)
        let encoded = String(tags.last!.split(separator: "=", maxSplits: 1)[1])
        let chunks = stride(from: 0, to: encoded.count, by: 7).map { start -> String in
            let from = encoded.index(encoded.startIndex, offsetBy: start)
            return whitespace + String(encoded[from..<(encoded.index(from, offsetBy: 7, limitedBy: encoded.endIndex) ?? encoded.endIndex)])
        }
        #expect(try CassiniPayload.decode(chunks, rawBytes: ref.number("rawBytes"), gzipBytes: ref.number("gzipBytes"), sha256: ref.string("sha256")) == text)
    }

    @Test func aWrongDigestOrSizeSaysWhich() throws {
        let (ref, tags) = try CassiniPayload.encode(prefix: "TEST_", mime: CassiniPayload.mime, text: #"{"ok":true}"#)
        let chunk = String(tags.last!.split(separator: "=", maxSplits: 1)[1])
        let digest = String(repeating: "0", count: 64)
        let error = #expect(throws: CassiniError.self) {
            try CassiniPayload.decode([chunk], rawBytes: ref.number("rawBytes"), gzipBytes: ref.number("gzipBytes"), sha256: digest)
        }
        #expect(error?.message == "payload-sha256-mismatch")
    }
}

@Suite struct JSONTests {
    /** "é" precomposed and decomposed are canonically equivalent but different bytes: different keys to the format. */
    @Test func keysAndStringsCompareByTheirBytes() throws {
        let object = try JSON.parseObject("{\"\u{E9}\":1,\"e\u{301}\":2}")
        #expect(object.keys.count == 2)
        #expect(try object.number("\u{E9}") == 1)
        #expect(try object.number("e\u{301}") == 2)
        #expect(JSON.string("\u{E9}") != JSON.string("e\u{301}"))
        #expect(JSONObject([("\u{E9}", .int(1))]) != JSONObject([("e\u{301}", .int(1))]))
        #expect(JSONObject([("a", .int(1)), ("b", .int(2))]) == JSONObject([("b", .int(2)), ("a", .int(1))]))
    }
}
