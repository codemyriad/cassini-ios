import SwiftUI

struct LibraryEmptyState: View {
    let query: String
    let favoritesOnly: Bool
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(Color.ember.opacity(0.06)).frame(width: 148, height: 148)
                Circle().stroke(Color.ember.opacity(0.1), lineWidth: 1).frame(width: 180, height: 180)
                OrbitMark(size: 88)
            }.padding(.top, 24)
            VStack(spacing: 10) {
                Text(query.isEmpty ? (favoritesOnly ? "Keep your favorites close." : "Good conversations\ndeserve to be kept.") : "No matching recordings.")
                    .font(.system(.title2, design: .serif)).multilineTextAlignment(.center).foregroundStyle(Color.ink)
                Text(query.isEmpty ? (favoritesOnly ? "Star a recording to find it here." : "Record a thought, an interview, or a meeting.\nTurn it into words you can come back to.") : "Try a different word or recording title.")
                    .font(.subheadline).foregroundStyle(Color.muted).multilineTextAlignment(.center)
            }
            if query.isEmpty && !favoritesOnly {
                HStack(spacing: 20) {
                    Label("Record", systemImage: "waveform")
                    Label("Transcribe", systemImage: "text.alignleft")
                    Label("Revisit", systemImage: "bookmark")
                }.font(.caption).foregroundStyle(Color.ember).padding(.top, 6)
            }
        }.frame(maxWidth: .infinity).padding(.bottom, 22)
    }
}
