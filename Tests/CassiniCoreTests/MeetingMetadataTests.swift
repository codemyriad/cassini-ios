@testable import CassiniCore
import Foundation
import Testing

struct MeetingMetadataTests {
    let words = Transcript([Word("spk_1", 0, 20, "Hello")])

    private func write(_ bytes: [UInt8], to folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("English meeting.opus")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func metadataReaderVerifiesManifestWithoutOpeningAnyTranscriptPayload() throws {
        try withTemporaryDirectory { folder in
            let original = try CassiniDocument.create(silence(), transcript: words, title: "English meeting", processing: JSONObject(),
                recordedAt: Date(timeIntervalSince1970: 1_794_211_200))
            let sealed = CassiniDocument.read(original)
            // The TX body is deliberately invalid gzip/base64. A full reader tries it and reports unavailable words;
            // a metadata reader must leave that payload entirely unopened, retaining only its descriptor.
            let comments = sealed.comments.map { comment -> String in
                let name = CassiniDocument.tagName(comment)
                return name.hasPrefix("CASSINI_TX_") && name.hasSuffix("_PAYLOAD_000") ? "\(name)=not-base64url!" : comment
            }
            let bytes = try OggOpus.mux(OggOpus.read(original), tags: CassiniDocument.tagsPacket(comments))
            let source = try write(bytes, to: folder)
            let full = CassiniDocument.readChecked(source, verify: false)
            #expect(full.variants.first?.error != nil)
            let metadata = CassiniDocument.readMetadataChecked(source)
            #expect(metadata.state == .unverified)
            #expect(metadata.manifest == sealed.manifest)
            #expect(metadata.variants.map(\.id) == sealed.variants.map(\.id))
            #expect(metadata.variants.allSatisfy { $0.body == nil && $0.transcript == nil && $0.error == nil })
            #expect(try Data(contentsOf: source) == Data(bytes))
        }
    }

    @Test func metadataReaderPreservesManifestPayloadValidationAndUnknownMajorStates() throws {
        try withTemporaryDirectory { folder in
            let original = try CassiniDocument.create(silence(), transcript: words, title: "English meeting", processing: JSONObject())
            let sealed = CassiniDocument.read(original)
            for unknownMajor in [false, true] {
                let comments = sealed.comments.map { comment -> String in
                    if unknownMajor, CassiniDocument.tagName(comment) == "CASSINI_FORMAT" { return "CASSINI_FORMAT=org.cassini.portable-meeting/99" }
                    if !unknownMajor, CassiniDocument.tagName(comment) == "CASSINI_PAYLOAD_SHA256" { return "CASSINI_PAYLOAD_SHA256=" + String(repeating: "0", count: 64) }
                    return comment
                }
                let bytes = try OggOpus.mux(OggOpus.read(original), tags: CassiniDocument.tagsPacket(comments))
                let source = try write(bytes, to: folder)
                let metadata = CassiniDocument.readMetadataChecked(source)
                #expect(metadata.state == (unknownMajor ? .unknownFormat : .invalidMetadata))
                #expect(metadata.manifest == nil)
                #expect(metadata.variants.isEmpty)
            }
            #expect(CassiniDocument.readMetadataChecked(folder.appendingPathComponent("missing.opus")).state == .unreadable)
        }
    }

    @Test func metadataReaderStillRequiresTheManifestSchema() throws {
        try withTemporaryDirectory { folder in
            let original = try CassiniDocument.create(silence(), transcript: words, title: "English meeting", processing: JSONObject())
            let sealed = CassiniDocument.read(original)
            var manifest = try #require(sealed.manifest)
            var meeting = try manifest.object("meeting")
            meeting["id"] = nil
            manifest["meeting"] = .object(meeting)
            let comments = sealed.comments.filter { !CassiniDocument.isManifestTag(CassiniDocument.tagName($0)) }
                + (try CassiniDocument.manifestTags(manifest))
            let bytes = try OggOpus.mux(OggOpus.read(original), tags: CassiniDocument.tagsPacket(comments))
            let source = try write(bytes, to: folder)
            let metadata = CassiniDocument.readMetadataChecked(source)
            #expect(metadata.state == .invalidMetadata)
            #expect(metadata.manifest == nil)
        }
    }

    @Test func metadataReadDoesNotScanAudioOrElevateTrust() throws {
        try withTemporaryDirectory { folder in
            let original = try CassiniDocument.create(silence(), transcript: words, title: "English meeting", processing: JSONObject())
            let stream = try OggOpus.read(original)
            let other = OggOpus.Stream(head: stream.head, tags: stream.tags,
                                      audio: [[0xF8, 0xFF, 0xFE], [0xF8, 0xFF, 0xFE]], finalGranule: 1920, validFraming: true)
            let stale = try OggOpus.mux(other, tags: stream.tags)
            let source = try write(stale, to: folder)
            #expect(CassiniDocument.readChecked(source).state == .staleAudio)
            let metadata = CassiniDocument.readMetadataChecked(source)
            #expect(metadata.state == .unverified)
            #expect(metadata.manifest == CassiniDocument.read(original).manifest)
            #expect(metadata.variants.allSatisfy { $0.body == nil && $0.transcript == nil })
        }
    }
}
