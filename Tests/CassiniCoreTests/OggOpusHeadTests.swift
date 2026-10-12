@testable import CassiniCore
import Testing

@Suite struct OggOpusHeadTests {
    func page(_ magic: [UInt8]) -> [UInt8] {
        var page = [UInt8](repeating: 0, count: OggOpus.headBytes)
        page.replaceSubrange(0..<4, with: Array("OggS".utf8))
        page[26] = 1
        page.replaceSubrange(28..<(28 + magic.count), with: magic)
        return page
    }

    // ports: OggOpusHeadTest#recognisesOpusFirstPage
    @Test func recognisesOpusFirstPage() {
        #expect(OggOpus.looksLikeOpus(page(Array("OpusHead".utf8))))
    }

    // ports: OggOpusHeadTest#rejectsVorbisWavAndShortInput
    @Test func rejectsVorbisWavAndShortInput() {
        #expect(!OggOpus.looksLikeOpus(page([1] + Array("vorbis".utf8) + [0])))
        let wav = Array("RIFF\0\0\0\0WAVE".utf8)
        #expect(!OggOpus.looksLikeOpus(wav + [UInt8](repeating: 0, count: OggOpus.headBytes - wav.count)))
        #expect(!OggOpus.looksLikeOpus(Array(page(Array("OpusHead".utf8)).prefix(20))))
    }
}
