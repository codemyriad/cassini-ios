import SwiftUI
import CassiniNotebook

struct StatusPill: View {
    let status: NoteStatus
    private var tone: Tone {
        switch status {
        case .ready: .ok
        case .failed, .recording: .error
        case .transcribing, .queued: .info
        case .audioOnly: .plain
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            if status == .ready { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            if status == .recording { Circle().fill(tone.color).frame(width: 5, height: 5) }
            Text(status.label).font(.caption.weight(.medium))
        }.foregroundStyle(tone.color).padding(.horizontal, 8).padding(.vertical, 4).background(tone.background, in: Capsule())
    }
}
