import Foundation
import CassiniNotebook

public enum CaptureEvent: Hashable, Sendable {
    /// The input level, 0...1, about ten times a second while capturing.
    case level(Float)
    /// Another app took the audio session; the capture is paused.
    case interrupted
    /// The input in use went away; the capture is paused.
    case routeLost
    /// The capture stopped on its own (an encoder error); what was written is kept.
    case failed
    /// The media services were reset; the capture cannot continue.
    case mediaReset
}

public struct CaptureResult: Hashable, Sendable {
    public var duration: TimeInterval
    public init(duration: TimeInterval) { self.duration = duration }
}

/// The microphone, writing one file per recording.
@MainActor public protocol AudioCapture: AnyObject {
    var events: AsyncStream<CaptureEvent> { get }
    /// Asks for microphone access when needed, then starts writing `url`.
    func start(url: URL) async throws -> CaptureFormat
    func pause()
    func resume() throws
    func stop() async throws -> CaptureResult
    /// UTC instant at position zero, captured after permission/session preparation.
    var recordedAt: Date? { get }
    var elapsed: TimeInterval { get }
    var fileBytes: Int64 { get }
}

extension AudioCapture {
    public var recordedAt: Date? { nil }
}
