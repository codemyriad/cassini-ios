import SwiftUI

/// The Starred filter with no starred notes (iOS extra). An empty library, a search that found nothing and a library
/// that could not be opened are the Library's banners (LIB_EMPTY, LIB_NO_MATCH, LIB_UNAVAILABLE), as on Android.
struct NoStarredState: View {
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.ember.opacity(0.06)).frame(width: 148, height: 148)
                Circle().stroke(Color.ember.opacity(0.1), lineWidth: 1).frame(width: 180, height: 180)
                OrbitMark(size: 88)
            }
            .padding(.top, 24).accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(LibraryCopy.noStarredTitle).font(.system(.title2, design: .serif)).foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(LibraryCopy.noStarredBody).font(.subheadline).foregroundStyle(Color.muted)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.bottom, 22)
    }
}
