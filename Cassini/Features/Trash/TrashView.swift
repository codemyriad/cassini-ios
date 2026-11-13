import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Recently Deleted: an intro and a card per note, oldest deletion first, or a plain card when there are none. The
/// notes whose 30 days are over go when it opens. Delete now and Empty ask first; the open confirmation is kept with
/// the scene and goes away when its note leaves Recently Deleted.
struct TrashView: View {
    @Environment(TrashService.self) private var trash
    @Environment(ErrorPresenter.self) private var errors
    @Environment(\.restoresSceneState) private var restoresSceneState
    @SceneStorage("trash.dialog") private var savedDialog: Data?
    @State private var dialogs = TrashDialogs()

    var body: some View {
        let items = trash.items
        let dialog = dialogs.dialog(in: items)
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                if items.isEmpty {
                    TrashEmptyCard()
                } else {
                    Text(TrashCopy.intro).font(.subheadline).foregroundStyle(Color.muted)
                        .padding(.horizontal, 4).padding(.bottom, 6)
                    ForEach(items) { item in
                        TrashCard(item: item, restore: { trash.restore(item.id) }, deleteNow: { dialogs.askDeleteNow(item.id) })
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 24)
            .readableWidth()
        }
        .background(Color.paper)
        .navigationTitle(TrashCopy.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(TrashCopy.empty, role: .destructive) { dialogs.askEmpty(items: items) }
                        .buttonStyle(.borderedProminent).tint(Color.errorFill).foregroundStyle(Color.onRecord)
                }
            }
        }
        .task { _ = try? await trash.purgeExpired() }
        .alert(dialog.map(Self.title) ?? "", isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialogs.dismiss() } }),
               presenting: dialog) { dialog in
            Button(TrashCopy.cancel, role: .cancel) { dialogs.dismiss() }
            Button(TrashCopy.delete, role: .destructive) { confirm(dialog) }
        } message: { dialog in
            switch dialog {
            case .delete: Text(TrashCopy.deleteBody)
            case .emptyAll: Text(TrashCopy.deleteAllBody)
            }
        }
        .onAppear {
            if restoresSceneState { dialogs.request = savedDialog.flatMap { try? JSONDecoder().decode(TrashDialogRequest.self, from: $0) } }
        }
        .onChange(of: dialogs.request) { _, request in
            if restoresSceneState { savedDialog = request.flatMap { try? JSONEncoder().encode($0) } }
        }
    }

    private static func title(_ dialog: TrashDialog) -> String {
        switch dialog {
        case .delete(_, let title): TrashCopy.deleteTitle(title)
        case .emptyAll(let count): TrashCopy.deleteAllTitle(count)
        }
    }

    private func confirm(_ dialog: TrashDialog) {
        Task {
            do throws(TrashError) {
                try await dialogs.confirm(dialog, with: trash)
            } catch {
                switch error {
                case .deleteFailed(let ids): errors.present(TrashCopy.notDeleted(ids, in: trash.items))
                case .voicesUnavailable: errors.present(TrashCopy.voicesUnavailable)
                }
            }
        }
    }
}

/// Recently Deleted with no notes.
private struct TrashEmptyCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TrashCopy.isEmpty).font(.headline).foregroundStyle(Color.ink)
            Text(TrashCopy.isEmptyBody).font(.subheadline).foregroundStyle(Color.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Tone.plain.background, in: RoundedRectangle(cornerRadius: Radius.control))
        .accessibilityElement(children: .combine)
    }
}
