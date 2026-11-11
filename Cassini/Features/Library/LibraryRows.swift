import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Read the live row projection in this view's body, rather than capturing it outside LazyVStack.
/// iOS 18 can retain that earlier closure while the recording sheet is open, leaving rows at their
/// pre-capture status even though the independently observed recording card is current.
struct LibraryRows: View {
    @Environment(LibraryScreenModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.calendar) private var calendar

    @ViewBuilder var body: some View {
        let content = model.content
        if !content.loading || content.emptyState == .unavailable {
            if content.emptyState == .noStarred { NoStarredState().padding(.top, 8) }
            if let results = content.results {
                ForEach(results) { row($0, day: $0.day ?? .today) }
            } else {
                ForEach(content.sections) { section in
                    Text(LibraryFormat(calendar: calendar).day(section.key).uppercased())
                        .font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(Color.muted)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 14)
                    ForEach(section.rows) { row($0, day: section.key) }
                }
            }
        }
    }

    private func row(_ row: LibraryRow, day: DayKey) -> some View {
        NoteRow(row: row, day: day, selected: router.selectedNoteID == row.id) { action in
            switch action {
            case .open: model.open(row.id)
            case .resume: Task { await model.resume(row.id) }
            case .rename: Task { await model.perform(.rename, on: row.id) }
            case .trash: Task { await model.perform(.moveToTrash, on: row.id) }
            }
        }
        .contextMenu { NoteActionsMenu(noteID: row.id) }
    }
}
