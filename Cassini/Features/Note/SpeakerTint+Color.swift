import SwiftUI
import CassiniNotebook

extension SpeakerTint {
    private var paletteIndex: Int? { Self.namedCycle.firstIndex(of: self) }
    var color: Color { paletteIndex.map { Color.speakerTints[$0] } ?? .unnamedSpeakerTint }
    var wash: Color { paletteIndex.map { Color.speakerWashes[$0] } ?? .unnamedSpeakerWash }
}
