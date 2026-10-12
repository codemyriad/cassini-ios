import Foundation

/// The semantic values a banner's copy needs; `BannerKind.uses` says which ones a kind reads. Durations are
/// milliseconds and sizes bytes, so the copy formats them in the shown language.
///
/// `part` names the model a download banner downloads. `bySystem` says that iOS, not the user or the connection, stopped
/// a transcription or a download. PLAIN_AUDIO reads `text` as the reason why the note has no transcript.
public struct BannerArgs: Hashable, Sendable {
    public var count: Int
    public var text: String?
    public var ms1: Int64
    public var ms2: Int64
    public var bytes: Int64
    public var bytes2: Int64
    public var percent: Int?
    public var part: ModelPart?
    public var bySystem: Bool

    public init(count: Int = 0, text: String? = nil, ms1: Int64 = 0, ms2: Int64 = 0, bytes: Int64 = 0, bytes2: Int64 = 0,
                percent: Int? = nil, part: ModelPart? = nil, bySystem: Bool = false) {
        self.count = count; self.text = text; self.ms1 = ms1; self.ms2 = ms2; self.bytes = bytes; self.bytes2 = bytes2
        self.percent = percent; self.part = part; self.bySystem = bySystem
    }

    /// `percent`, or the share of `bytes` in `bytes2` when it is nil.
    public var downloadPercent: Int {
        if let percent { return percent }
        guard bytes2 > 0 else { return 0 }
        return Int(min(max(bytes * 100 / bytes2, 0), 100))
    }
}

/// One banner to show. `actions` default to the kind's catalogue actions; `dismissible` adds the close button;
/// `announce` makes VoiceOver read it when it appears.
///
/// `id` names the banner in its list, so it must be unique there. It defaults to the kind; when two banners of one kind
/// can show together, the screen sets its own id.
public struct BannerSpec: Hashable, Sendable, Identifiable {
    public var kind: BannerKind
    public var args: BannerArgs
    public var actions: [BannerAction]
    public var announce: Bool
    public var dismissible: Bool
    public var id: String

    public init(_ kind: BannerKind, _ args: BannerArgs = BannerArgs(), actions: [BannerAction]? = nil,
                announce: Bool = false, dismissible: Bool? = nil, id: String? = nil) {
        self.kind = kind; self.args = args
        self.actions = actions ?? kind.actions
        self.announce = announce
        self.dismissible = dismissible ?? kind.dismissible
        self.id = id ?? kind.rawValue
    }
}
