import SwiftUI
import CassiniNotebook

struct TrashView: View {
    @Environment(TrashStore.self) private var trash
    @State private var pendingDelete: Note?
    @State private var emptying = false

    var body: some View {
        let notes = trash.notes
        Group {
            if notes.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "trash", description: Text("Deleted recordings can be restored for 30 days."))
            } else {
                List {
                    Section {
                        ForEach(notes) { note in TrashCard(note: note) { pendingDelete = note } }
                    } footer: { Text("Recordings expire after 30 days. Permanent deletion removes audio, transcripts, and voice samples from this recording.") }
                }.scrollContentBackground(.hidden)
            }
        }
        .background(Color.paper).navigationTitle("Recently Deleted").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if !notes.isEmpty { Button("Empty", role: .destructive) { emptying = true } } } }
        .task { await trash.purgeExpired() }
        .alert("Empty Recently Deleted?", isPresented: $emptying) {
            Button("Cancel", role: .cancel) {}
            Button("Delete all forever", role: .destructive) { Task { await trash.emptyTrash() } }
        } message: { Text("Permanently deletes all \(notes.count) recordings in Recently Deleted and their voice samples. This cannot be undone.") }
        .alert("Delete recording forever?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete forever", role: .destructive) {
                if let note = pendingDelete { Task { await trash.deletePermanently(note.id) } }
                pendingDelete = nil
            }
        } message: { Text("“\(pendingDelete?.title ?? "")” and its transcript will be permanently deleted. This cannot be undone.") }
    }
}
