import Testing
import CassiniNotebook

/// The shared size rule against the `size` vectors of `ux-draft/format-vectors.json` v4 in cassini-coordination
/// (sha256 8d9449e3…cc791), copied here entry for entry.
@Suite struct SizeTextTests {
    static let vectors: [(bytes: Int64, approx: Bool, out: String)] = [
        (25_165_824, true, "about 24 MB"),
        (17_825_792, false, "17 MB"),
        (671_088_640, false, "640 MB"),
        (1_288_490_189, false, "1.2 GB"),
        (24_641_536, true, "about 24 MB"),
        (1_047_527_424, false, "999 MB"),
        (1_048_051_712, false, "1.0 GB"),
        (1_342_177_280, false, "1.3 GB"),
        (464_519_168, false, "443 MB"),
        (524_288, false, "512 KB"),
        (1_536, false, "2 KB"),
        (469_000, true, "about 458 KB"),
        (100, false, "1 KB"),
        (0, false, "0 KB"),
        (1_023_999, false, "1 MB"),
        (1_048_576, false, "1 MB"),
    ]

    @Test(arguments: vectors.indices) func theSharedVectors(index: Int) {
        let vector = Self.vectors[index]
        #expect(SizeText(bytes: vector.bytes).english(approx: vector.approx) == vector.out)
    }

    /// D4 and D16: the downloads read as the model host's compressed sizes.
    @Test func theModelDownloadsReadAsTheDecisionsWriteThem() {
        #expect(SizeText(bytes: 464_908_884).english() == "443 MB", "Parakeet Ultra")
        #expect(SizeText(bytes: 64_915_668).english() == "62 MB", "Nemotron diarizer")
        #expect(SizeText(bytes: 27_138_478).english() == "26 MB", "CAM++")
        #expect(SizeText(bytes: 469_349).english() == "458 KB", "Silero VAD")
    }

    @Test func aNegativeSizeIsZero() {
        #expect(SizeText(bytes: -5) == .kilobytes(0))
    }
}
