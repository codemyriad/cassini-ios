import SwiftUI

struct Waveform: View {
    let levels: [Float]
    var progress: Double = 0
    var activeColor: Color = .accentInk
    var inactiveColor: Color = .muted.opacity(0.22)
    var body: some View {
        Canvas { context, size in
            let count = levels.isEmpty ? 64 : levels.count
            let spacing = size.width / CGFloat(count)
            for index in 0..<count {
                let value: Float = levels.isEmpty ? 0.06 : levels[index]
                let height = max(3, CGFloat(value) * size.height)
                let rect = CGRect(x: CGFloat(index) * spacing, y: (size.height - height) / 2, width: max(1.5, spacing * 0.48), height: height)
                let color = Double(index) / Double(count) <= progress ? activeColor : inactiveColor
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
        }.accessibilityHidden(true)
    }
}
