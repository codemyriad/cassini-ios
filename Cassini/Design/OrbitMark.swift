import SwiftUI

/// The product's name wherever the app names itself (the shared catalogue's `app.name`, D45): the Library's wordmark,
/// About, the app's own licence and Now Playing. The same in every language. Running sentences keep the short form
/// "Cassini" ("Open Cassini to resume."), and the home-screen name is CFBundleDisplayName in the Info.plists.
enum ProductName {
    static let full = "Cassini talk"
}

struct OrbitMark: View {
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.accentInk, lineWidth: 2).frame(width: size * 0.63, height: size * 0.63)
            Ellipse().stroke(Color.accentInk, lineWidth: 1.7).frame(width: size, height: size * 0.35).rotationEffect(.degrees(-32))
            Circle().fill(Color.accentInk).frame(width: size * 0.13).offset(x: size * 0.34, y: -size * 0.2)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
