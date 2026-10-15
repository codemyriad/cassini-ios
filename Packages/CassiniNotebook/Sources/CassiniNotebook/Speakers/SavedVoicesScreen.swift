import Foundation

/// One saved person as Saved voices lists it.
public struct SavedVoiceSummary: Hashable, Sendable, Identifiable {
    public var voice: SavedVoice
    /// Notes in the library (not in Recently Deleted) with a speaker linked to this person, automatically or confirmed.
    public var notes: Int
    /// "Name them again in a note to keep recognising them".
    public var stale: Bool
    public var id: UUID { voice.id }
    public var name: String { voice.name }
    public var confirmedSeconds: Double { voice.confirmedSpeech }
}

public enum SavedVoiceList {
    /// The saved voices sorted by notes, then confirmed seconds, then name.
    public static func summaries(_ voices: [SavedVoice], notes: [Note], model: String?,
                                 dimension: Int? = nil) -> [SavedVoiceSummary] {
        var counts: [UUID: Int] = [:]
        for note in notes where note.trashedAt == nil {
            for voice in Set((note.speakers ?? []).compactMap(\.linkedVoiceID)) { counts[voice, default: 0] += 1 }
        }
        return voices.map {
            SavedVoiceSummary(voice: $0, notes: counts[$0.id] ?? 0,
                              stale: VoiceStaleness.isStale($0, model: model, dimension: dimension))
        }
            .sorted { a, b in
                if a.notes != b.notes { return a.notes > b.notes }
                if a.confirmedSeconds != b.confirmedSeconds { return a.confirmedSeconds > b.confirmedSeconds }
                return NameMatch.alphabetical(a.voice, b.voice)
            }
    }

    /// Whole minutes of `seconds`, floored, for "22 min confirmed speech": nil below a minute ("under 1 min").
    public static func roughMinutes(_ seconds: Double) -> Int64? {
        let minutes = Int64(max(0, seconds) / 60)
        return minutes == 0 ? nil : minutes
    }
}

/// The dialogs of Saved voices.
public enum SavedVoicesDialog: Hashable, Sendable {
    /// Rename (at most 80 characters); `name` is the current name.
    case rename(UUID, name: String)
    /// "Forget <name>?".
    case forget(UUID, name: String)
    /// "Forget everyone?" with the number of saved voices.
    case forgetEveryone(count: Int)
}

/// What Saved voices asks for.
public enum SavedVoicesEvent: Hashable, Sendable {
    case rename(UUID)
    case forget(UUID)
    case forgetEveryone
    case renameConfirmed(UUID, name: String)
    /// The confirm button of a Forget or Forget everyone dialog.
    case confirmDialog
    case dismissDialog
}

/// An edit Saved voices asks the app to make.
public enum SavedVoicesAction: Hashable, Sendable {
    case rename(UUID, name: String)
    case forget(UUID)
    case forgetEveryone
}

/// Saved voices: the open dialog, kept as a key (`dialog`) so that it can be saved with the scene and comes back after
/// the app was closed; the dialog's name and count come from the list. While the list is read-only every edit is
/// ignored.
public struct SavedVoicesScreen: Hashable, Sendable {
    /// "rename:<id>", "forget:<id>" or "everyone".
    public var dialog: String?

    public init(dialog: String? = nil) { self.dialog = dialog }

    /// The open dialog, while its person is still in `people`.
    public func dialog(people: [SavedVoiceSummary], readOnly: Bool) -> SavedVoicesDialog? {
        guard !readOnly, let key = dialog else { return nil }
        if key == Self.everyone { return people.isEmpty ? nil : .forgetEveryone(count: people.count) }
        func person(_ prefix: String) -> SavedVoiceSummary? {
            guard key.hasPrefix(prefix), let id = UUID(uuidString: String(key.dropFirst(prefix.count))) else { return nil }
            return people.first { $0.id == id }
        }
        if let rename = person(Self.renamePrefix) { return .rename(rename.id, name: rename.name) }
        if let forget = person(Self.forgetPrefix) { return .forget(forget.id, name: forget.name) }
        return nil
    }

    /// One event: the screen after it and the edit to make, if any.
    public mutating func reduce(_ event: SavedVoicesEvent, readOnly: Bool) -> SavedVoicesAction? {
        switch event {
        case .rename(let id): if !readOnly { dialog = Self.renamePrefix + id.uuidString }
        case .forget(let id): if !readOnly { dialog = Self.forgetPrefix + id.uuidString }
        case .forgetEveryone: if !readOnly { dialog = Self.everyone }
        case .renameConfirmed(let id, let name):
            dialog = nil
            if !readOnly { return .rename(id, name: name) }
        case .confirmDialog:
            let key = dialog
            dialog = nil
            guard !readOnly, let key else { return nil }
            if key == Self.everyone { return .forgetEveryone }
            if key.hasPrefix(Self.forgetPrefix), let id = UUID(uuidString: String(key.dropFirst(Self.forgetPrefix.count))) {
                return .forget(id)
            }
        case .dismissDialog: dialog = nil
        }
        return nil
    }

    private static let renamePrefix = "rename:"
    private static let forgetPrefix = "forget:"
    private static let everyone = "everyone"
}
