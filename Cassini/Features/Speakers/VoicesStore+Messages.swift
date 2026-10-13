import Foundation
import CassiniEngine

extension VoicesStore.SaveFailure {
    /// The failure as the speaker sheets word it.
    var message: String {
        switch reason {
        case .voicesReadOnly: SpeakersCopy.voicesReadOnly
        case .tooLittleSpeech: SpeakersCopy.tooLittleSpeech
        case .noteNotSaved: SpeakersCopy.noteNotSaved
        case .voiceNotSaved(let error): SpeakersCopy.voiceNotSaved(FailureReason.of(error))
        }
    }
}
