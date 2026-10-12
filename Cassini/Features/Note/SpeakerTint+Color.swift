import SwiftUI
import CassiniNotebook

extension SpeakerTint {
    /// The speaker label's colour, from the speaker tints of the palette.
    var color: Color {
        switch self {
        case .blue: Color.speakerTints[1]
        case .teal: Color.speakerTints[5]
        case .violet: Color.speakerTints[3]
        case .amber: Color.speakerTints[4]
        }
    }
}
