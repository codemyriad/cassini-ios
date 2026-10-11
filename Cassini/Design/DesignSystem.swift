import SwiftUI
import CassiniNotebook

extension Color {
    static let paper = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.075, green: 0.085, blue: 0.095, alpha: 1) : UIColor(red: 0.975, green: 0.965, blue: 0.941, alpha: 1) })
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.135, blue: 0.145, alpha: 1) : .white })
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1) : UIColor(red: 0.12, green: 0.17, blue: 0.19, alpha: 1) })
    static let ember = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.49, blue: 0.32, alpha: 1) : UIColor(red: 0.76, green: 0.22, blue: 0.10, alpha: 1) })
    static let muted = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.67, green: 0.71, blue: 0.73, alpha: 1) : UIColor(red: 0.40, green: 0.44, blue: 0.46, alpha: 1) })
    static let transcriptReady = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.40, green: 0.80, blue: 0.72, alpha: 1) : UIColor(red: 0.13, green: 0.40, blue: 0.35, alpha: 1) })
}

struct OrbitMark: View {
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.ember, lineWidth: 2).frame(width: size * 0.63, height: size * 0.63)
            Ellipse().stroke(Color.ember, lineWidth: 1.7).frame(width: size, height: size * 0.35).rotationEffect(.degrees(-32))
            Circle().fill(Color.ember).frame(width: size * 0.13).offset(x: size * 0.34, y: -size * 0.2)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

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

struct StatusPill: View {
    let status: NoteStatus
    private var color: Color {
        switch status { case .ready: .transcriptReady; case .failed, .recording: .ember; case .transcribing, .queued: .blue; case .audioOnly: .muted }
    }
    var body: some View {
        HStack(spacing: 5) {
            if status == .ready { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            if status == .recording { Circle().fill(color).frame(width: 5, height: 5) }
            Text(status.label).font(.caption.weight(.medium))
        }.foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.09), in: Capsule())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(.white).padding(.horizontal, 22).padding(.vertical, 17)
            .frame(maxWidth: .infinity).background(Color.ember, in: Capsule()).opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct NoticeCard: View {
    let title: String
    var symbol = "info.circle"
    var body: some View {
        Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color.ember.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}
