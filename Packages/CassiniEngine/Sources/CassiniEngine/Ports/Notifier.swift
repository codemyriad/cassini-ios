import Foundation
import CassiniNotebook

public enum NotificationAuth: Hashable, Sendable {
    case notDetermined, denied, authorized
}

public struct ResultNotification: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case transcribed(speakers: Int, duration: TimeInterval)
        case failed(JobFailure)
        case readyToTranscribe
        case pausedBySystem
        case transcriptionStopped
        case recordingStopped
        case microphoneFailed
    }
    public var noteID: UUID
    public var title: String
    public var kind: Kind
    public init(noteID: UUID, title: String, kind: Kind) { self.noteID = noteID; self.title = title; self.kind = kind }
}

public protocol Notifier: Sendable {
    func authorizationStatus() async -> NotificationAuth
    /// Asks for permission the first time only.
    func requestOnce() async
    /// Replaces any earlier notification of the same note.
    func post(_ notification: ResultNotification) async
    func remove(noteID: UUID) async
}
