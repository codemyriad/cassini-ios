import SwiftUI

/// The notices of the software Cassini includes.
struct LicensesView: View {
    @State private var notices = ""
    var body: some View {
        ScrollView {
            Text(notices).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.gutter)
        }
        .background(Color.paper)
        .navigationTitle("Licenses").navigationBarTitleDisplayMode(.inline)
        .task {
            guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return }
            notices = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }
}
