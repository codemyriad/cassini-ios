import AVFoundation
import CassiniEngine

/// Microphone access through `AVAudioApplication`.
@MainActor final class AVMicrophonePermission: MicrophonePermission {
    var access: MicrophoneAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    func request() async -> Bool { await AVAudioApplication.requestRecordPermission() }
}
