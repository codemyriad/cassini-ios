import Foundation

/// W0.4's portable presentation. Phone-specific applicability stays in the app adapter.
public struct BadgePresentation: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, CaseIterable, Sendable {
        case recording, importing, saving, transcribing, needsAttention, interrupted, received
    }
    public enum Tint: String, Codable, Hashable, CaseIterable, Sendable { case red, neutral, amber, outline }
    public enum Glyph: String, Codable, Hashable, CaseIterable, Sendable { case dot, spinner, alert, incoming }

    public var kind: Kind
    public var text: String
    public var tint: Tint
    public var glyph: Glyph

    public init(kind: Kind, text: String, tint: Tint, glyph: Glyph) {
        self.kind = kind; self.text = text; self.tint = tint; self.glyph = glyph
    }
}

/// Shared persisted-meeting facts, not the iOS job/row-status enum or an importing lifecycle.
/// The reader still rejects schema-invalid metadata before constructing these display facts.
public struct BadgeFields: Codable, Hashable, Sendable {
    public enum Lifecycle: String, Codable, Hashable, Sendable { case recording, saving, saved }
    public enum Origin: String, Codable, Hashable, Sendable { case own, received }
    public enum Transcript: String, Codable, Hashable, Sendable { case none, queued, running, done, failed, damaged }
    public struct Failure: Codable, Hashable, Sendable {
        public var id: String?
        public var action: String?
        public init(id: String? = nil, action: String? = nil) { self.id = id; self.action = action }
    }
    public var lifecycle: Lifecycle
    public var origin: Origin
    public var transcript: Transcript
    public var liveMs: Int64?
    public var durationMs: Int64?
    public var etaMinutes: Int?
    public var interruptedAtMs: Int64?
    public var error: Failure?

    public init(lifecycle: Lifecycle = .saved, origin: Origin = .own, transcript: Transcript = .none,
                liveMs: Int64? = nil, durationMs: Int64? = nil, etaMinutes: Int? = nil,
                interruptedAtMs: Int64? = nil, error: Failure? = nil) {
        self.lifecycle = lifecycle; self.origin = origin; self.transcript = transcript
        self.liveMs = liveMs; self.durationMs = durationMs; self.etaMinutes = etaMinutes
        self.interruptedAtMs = interruptedAtMs; self.error = error
    }
}

/// Wordings come only from the caller's pinned catalog templates (compiled xcstrings in the app).
public enum StatusBadges {
    public typealias Text = (String) -> String

    public static func meeting(_ fields: BadgeFields, text: Text) -> BadgePresentation? {
        if fields.lifecycle == .recording {
            return output(.recording, tint: .red, glyph: .dot, text: text,
                          arguments: ["liveBadge": liveClock(milliseconds: fields.liveMs ?? fields.durationMs ?? 0)])
        }
        if fields.lifecycle == .saving { return output(.saving, tint: .neutral, glyph: .spinner, text: text) }
        if fields.transcript == .queued || fields.transcript == .running {
            return transcribing(etaMinutes: fields.etaMinutes, text: text)
        }
        if fields.error?.action != nil { return output(.needsAttention, tint: .amber, glyph: .alert, text: text) }
        if fields.interruptedAtMs != nil { return output(.interrupted, tint: .amber, glyph: .alert, text: text) }
        if fields.origin == .received { return output(.received, tint: .outline, glyph: .incoming, text: text) }
        return nil
    }

    /// An active transient import entry has no shared priority against a persisted meeting.
    public static func entry(importing: Bool, text: Text) -> BadgePresentation? {
        importing ? output(.importing, tint: .neutral, glyph: .spinner, text: text) : nil
    }

    public static func canWriteDown(_ fields: BadgeFields) -> Bool {
        fields.lifecycle == .saved && (fields.transcript == .none || fields.transcript == .failed)
    }

    public static func transcribing(etaMinutes: Int?, text: Text) -> BadgePresentation {
        let suffix: String
        if let etaMinutes, etaMinutes >= 0 { suffix = etaMinutes == 0 ? ".underMinute" : "" }
        else { suffix = ".noEta" }
        return output(.transcribing, key: "states.badge.transcribing" + suffix, tint: .neutral, glyph: .spinner,
                      text: text, arguments: etaMinutes.map { ["n": String($0)] } ?? [:])
    }

    /// Shared format-v5 live badge timer: unpadded minutes below one hour, hours from one hour onward.
    public static func liveClock(milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds) / 1000
        let hours = seconds / 3600, minutes = seconds / 60 % 60
        func two(_ value: Int64) -> String { value < 10 ? "0\(value)" : String(value) }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(seconds % 60))" : "\(seconds / 60):\(two(seconds % 60))"
    }

    /// The position-bearing detail sentence deliberately remains separate from the Interrupted badge.
    public static func interruptedAt(position: String, text: Text) -> String {
        interpolate(text("meeting.interruptedAt"), arguments: ["position": position])
    }

    private static func output(_ kind: BadgePresentation.Kind, key: String? = nil,
                               tint: BadgePresentation.Tint, glyph: BadgePresentation.Glyph,
                               text: Text, arguments: [String: String] = [:]) -> BadgePresentation {
        BadgePresentation(kind: kind, text: interpolate(text(key ?? "states.badge." + kind.rawValue), arguments: arguments),
                          tint: tint, glyph: glyph)
    }
    private static func interpolate(_ template: String, arguments: [String: String]) -> String {
        arguments.keys.sorted().reduce(template) { result, key in
            result.replacingOccurrences(of: "{\(key)}", with: arguments[key]!)
        }
    }
}
