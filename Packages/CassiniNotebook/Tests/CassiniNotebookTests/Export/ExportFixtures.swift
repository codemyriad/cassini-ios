import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

func w(_ speaker: String, _ startMs: Int64, _ endMs: Int64, _ text: String) -> Word { Word(speaker, startMs, endMs, text) }

/// Words of `speaker` from `text`, each `stepMs` apart and lasting `stepMs` - 100.
func said(_ speaker: String, _ startMs: Int64, _ text: String, stepMs: Int64 = 400) -> [Word] {
    text.split(separator: " ").enumerated().map { i, word in
        w(speaker, startMs + Int64(i) * stepMs, startMs + Int64(i + 1) * stepMs - 100, String(word))
    }
}

func transcript(_ words: [Word],
                labels: [String: String] = ["spk_0": "Paolo", "spk_1": "Speaker 2", "spk_2": "Élodie"],
                durationMs: Int64 = 23 * 60_000 + 50_000,
                title: String = "Call with supplier") -> ExportTranscript {
    ExportTranscript(title: title, durationMs: durationMs, words: words, labels: labels)
}

/// A golden file copied from Android's `core/src/test/resources/export/`.
func resource(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "export"), "Missing \(name)")
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

/// UTF-8 without BOM, `\n` line endings and exactly one trailing `\n`.
func expectExportShape(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!text.hasPrefix("\u{FEFF}"), "BOM", sourceLocation: sourceLocation)
    #expect(!text.unicodeScalars.contains("\r"), "CR", sourceLocation: sourceLocation)
    #expect(text.hasSuffix("\n"), "trailing newline", sourceLocation: sourceLocation)
    #expect(!text.hasSuffix("\n\n"), "two trailing newlines", sourceLocation: sourceLocation)
}

/// `actual` equals `expected` byte for byte and has the shape every export has.
func expectExport(_ expected: String, _ actual: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(Array(actual.utf8) == Array(expected.utf8), "Expected: \(expected)\nActual: \(actual)", sourceLocation: sourceLocation)
    expectExportShape(actual, sourceLocation: sourceLocation)
}
