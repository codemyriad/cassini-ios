import SwiftUI

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
