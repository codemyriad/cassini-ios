import SwiftUI

@main
struct CassiniApp: App {
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .onOpenURL { url in library.importFile(url) }
        }
    }
}

/** Tape-deck colours shared with Cassini for Android. */
enum Deck {
    static let ink = Color(red: 16 / 255, green: 18 / 255, blue: 15 / 255)
    static let surface = Color(red: 27 / 255, green: 30 / 255, blue: 24 / 255)
    static let paper = Color(red: 232 / 255, green: 229 / 255, blue: 217 / 255)
    static let muted = Color(red: 169 / 255, green: 176 / 255, blue: 159 / 255)
    static let amber = Color(red: 244 / 255, green: 197 / 255, blue: 106 / 255)
    static let warning = Color(red: 255 / 255, green: 161 / 255, blue: 142 / 255)
}
