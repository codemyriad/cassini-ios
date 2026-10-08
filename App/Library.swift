import CassiniCore
import Foundation

/** One file in the library. The list reads headers only; the note screen verifies the audio. */
struct Note: Identifiable, Equatable {
    let url: URL
    let title: String
    let modified: Date
    let preview: String
    let searchText: String
    var id: URL { url }
}

/** Opus files in the app's Documents folder, which the Files app can also see. */
@MainActor
final class Library: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published var error: String?
    let folder: URL

    init() {
        folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // A launch argument lets screenshots and UI checks open a fixture without the file picker.
        if let path = ProcessInfo.processInfo.environment["CASSINI_IMPORT"] { importFile(URL(fileURLWithPath: path)) }
        refresh()
    }

    func refresh() {
        let folder = self.folder
        Task.detached(priority: .userInitiated) {
            let notes = Library.scan(folder)
            await MainActor.run { self.notes = notes }
        }
    }

    nonisolated static func scan(_ folder: URL) -> [Note] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "opus" }.map { url in
            let doc = CassiniDocument.read(url, verify: false)
            let words = doc.selected()?.transcript?.words.map { $0.text } ?? []
            let title = doc.title.isEmpty ? url.deletingPathExtension().lastPathComponent : doc.title
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return Note(url: url, title: title, modified: modified, preview: words.prefix(24).joined(separator: " "),
                        searchText: (title + " " + words.joined(separator: " ")).lowercased())
        }.sorted { $0.modified > $1.modified }
    }

    /** Copies [source] in under a name that does not overwrite an existing note. */
    func importFile(_ source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let base = source.deletingPathExtension().lastPathComponent
            var target = folder.appendingPathComponent(base).appendingPathExtension("opus")
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("opus"); n += 1
            }
            try FileManager.default.copyItem(at: source, to: target)
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ note: Note) {
        try? FileManager.default.removeItem(at: note.url)
        refresh()
    }
}
