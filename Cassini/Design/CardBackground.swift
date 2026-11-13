import SwiftUI

/// The card surface: fill, corner radius and a hairline edge.
struct CardBackground: ViewModifier {
    var radius = Radius.card
    var outlined = true
    func body(content: Content) -> some View {
        content
            .background(Color.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                if outlined { RoundedRectangle(cornerRadius: radius).stroke(Color.lineSoft, lineWidth: 1) }
            }
    }
}

extension View {
    func cardBackground(radius: CGFloat = Radius.card, outlined: Bool = true) -> some View {
        modifier(CardBackground(radius: radius, outlined: outlined))
    }
}

extension View {
    /// A list or form on the paper ground, as every screen of Cassini, rather than the system's grouped grey.
    func paperListBackground() -> some View {
        scrollContentBackground(.hidden).background(Color.paper)
    }
}
