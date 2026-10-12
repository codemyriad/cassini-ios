import SwiftUI

struct Waveform: View {
    let levels: [Float]
    var progress: Double = 0
    var activeColor: Color = .ember
    var inactiveColor: Color = .muted.opacity(0.22)
    var body: some View {
        Canvas { context, size in
            let values = levels.isEmpty ? Array(repeating: Float(0.06), count: 64) : levels
            let spacing = size.width / CGFloat(values.count)
            for (index, value) in values.enumerated() {
                let height = max(3, CGFloat(value) * size.height)
                let rect = CGRect(x: CGFloat(index) * spacing, y: (size.height - height) / 2, width: max(1.5, spacing * 0.48), height: height)
                let color = Double(index) / Double(values.count) <= progress ? activeColor : inactiveColor
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
        }.accessibilityHidden(true)
    }
}
