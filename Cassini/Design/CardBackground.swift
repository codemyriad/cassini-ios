import SwiftUI

/// The card surface: fill, corner radius and a hairline edge.
struct CardBackground: ViewModifier {
    var radius = Radius.card
    var outlined = true
    func body(content: Content) -> some View {
        content
            .background(Color.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                if outlined { RoundedRectangle(cornerRadius: radius).stroke(Color.ink.opacity(0.055), lineWidth: 1) }
            }
    }
}

extension View {
    func cardBackground(radius: CGFloat = Radius.card, outlined: Bool = true) -> some View {
        modifier(CardBackground(radius: radius, outlined: outlined))
    }
}
