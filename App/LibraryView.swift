import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @State private var query = ""
    @State private var importing = false

    private var shown: [Note] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? library.notes : library.notes.filter { $0.searchText.contains(q) }
    }

    var body: some View {
        NavigationView {
            Group {
                if library.notes.isEmpty {
                    VStack(spacing: 12) {
                        Text("library.empty").font(.title2.weight(.semibold)).foregroundColor(Deck.paper)
                        Text("library.empty.hint").foregroundColor(Deck.muted).multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    List {
                        ForEach(shown) { note in
                            NavigationLink(destination: NoteView(url: note.url)) { NoteRow(note: note) }
                                .listRowBackground(Deck.surface)
                        }
                        .onDelete { offsets in for note in offsets.map({ shown[$0] }) { library.delete(note) } }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $query, prompt: Text("library.search"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Deck.ink.ignoresSafeArea())
            .navigationTitle("Cassini")
            .toolbar {
                Button { importing = true } label: { Label("library.import", systemImage: "square.and.arrow.down") }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "opus") ?? .audio, .audio],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { for url in urls { library.importFile(url) } }
            }
            .alert("library.error", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(library.error ?? "") }
        }
        .navigationViewStyle(.automatic)
    }
}

private struct NoteRow: View {
    let note: Note
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title).font(.headline).foregroundColor(Deck.paper)
            Text(note.modified, style: .date).font(.caption.monospaced()).foregroundColor(Deck.muted)
            if !note.preview.isEmpty {
                Text(note.preview).font(.subheadline).foregroundColor(Deck.muted).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
