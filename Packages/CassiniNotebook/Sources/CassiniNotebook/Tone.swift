import Foundation

/// The tone of a status or a notice (Android `Tone`): it picks the colours of a banner, a row's status chip and a model
/// row's status, and a banner's place in a list. The app gives each tone its colours.
public enum Tone: String, CaseIterable, Hashable, Sendable {
    case ok, info, warn, error, plain
}
