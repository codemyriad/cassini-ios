import Foundation
import CassiniCore
import CassiniNotebook

/// A guided sample uses diarizer-confirmed single-speaker speech, with the same four-second threshold as a clip.
/// The extent is only a window-selection hint; no synthetic transcript is persisted or exported.
public enum VoiceEnrollment {
    public enum Invalid: Error, Equatable { case tooShort, ambiguous, invalidName }

    public static func analyze(url: URL, duration: Double, analyzer: any SpeakerAnalyzing) async throws -> SpeakerPrint {
        guard duration.isFinite, duration >= 4 else { throw Invalid.tooShort }
        let extent = Word("", 0, Int64(min(duration, 45) * 1000), "")
        let analysis = try await analyzer.analyze(url: url, words: [extent], allowDownload: false, progress: { _ in })
        guard analysis.prints.count == 1, let print = analysis.prints.first else { throw Invalid.ambiguous }
        try validate(print)
        return print
    }

    public static func validate(_ print: SpeakerPrint) throws {
        guard print.speechSeconds.isFinite, print.speechSeconds >= 4 else { throw Invalid.tooShort }
        guard print.model == VoiceprintModel.sha256, print.vector.count == VoiceprintModel.dimension,
              VoiceMatcher.normalized(print.vector) != nil else { throw Invalid.ambiguous }
    }
}
