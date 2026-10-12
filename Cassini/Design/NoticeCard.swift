import SwiftUI

struct NoticeCard: View {
    let title: String
    var symbol = "info.circle"
    var body: some View {
        Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color.ember.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.control))
    }
}
