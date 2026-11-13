import SwiftUI

/// The app/store name remains distinct from the approved in-app wordmark (L-15).
enum ProductName {
    static let full = "Cassini talk"
    static let wordmark = "cassini.talk"
}

struct OrbitMark: View {
    var size: CGFloat = 36
    var body: some View {
        Image("SaturnNav").renderingMode(.original).resizable().scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}
