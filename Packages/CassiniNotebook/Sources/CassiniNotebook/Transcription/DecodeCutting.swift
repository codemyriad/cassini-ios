import Foundation

/// How a recording is cut before decoding, with the provenance text `x-segmentation` records. Android's
/// `Parakeet.Cutting`; the strings are verbatim.
public enum DecodeCutting: String, CaseIterable, Hashable, Sendable {
    /// One decode of the whole recording: nothing is known until it returns.
    case whole = "WHOLE"
    /// The desktop's detector-free path: 15 s windows with 0.5 s overlap, reconciled at their seams.
    case fixed = "FIXED"
    /// No speech detector installed: the recording as one span, cut at its quiet points.
    case quiet = "QUIET"
    /// Speech spans found by the detector, each split by the `DecodePolicy`.
    case speech = "SPEECH"

    public var provenance: String {
        switch self {
        case .whole: "whole recording"
        case .fixed: "15 s windows, 0.5 s overlap, seams aligned by word"
        case .quiet: "pieces of 20 to 28 s cut at the quietest point with 1 s of recorded context, 0.5 s synthetic tail"
        case .speech: "Silero VAD 0.18 speech spans, cut at the quietest point with 1 s of recorded context when longer than 28 s, 0.5 s synthetic tail"
        }
    }

    /// A single decode's memory grows with its length; longer recordings are always cut.
    public static let wholeMaxMs: Int64 = 60_000

    /// SPEECH when the speech detector is installed, otherwise QUIET.
    public static func cutting(detectorReady: Bool) -> DecodeCutting { detectorReady ? .speech : .quiet }

    /// The text of the incremental decode, followed by the cutting of each window.
    public static let incrementalPrefix = "Incremental container decoding: 28 s PCM windows, 2 s recorded overlap, seams aligned by word; "

    public static func incrementalProvenance(detectorReady: Bool) -> String {
        incrementalPrefix + cutting(detectorReady: detectorReady).provenance
    }
}
