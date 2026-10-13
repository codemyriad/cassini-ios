import SwiftUI
import CassiniNotebook

/// A note in Recently Deleted: its title and duration, "Deleted Oct 2 · 23 days left", then Restore and Delete now.
struct TrashCard: View {
    let item: TrashItem
    let restore: () -> Void
    let deleteNow: () -> Void
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title).font(.headline).foregroundStyle(Color.ink).frame(maxWidth: .infinity, alignment: .leading)
                Text(TimeText.clock(item.duration)).font(.caption.monospacedDigit()).foregroundStyle(Color.muted)
            }
            Text(meta).font(.caption).foregroundStyle(Color.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
        .cardBackground(radius: Radius.control)
    }

    private var meta: String {
        TrashCopy.deleted(item.deletedOn, calendar: calendar, locale: locale) + " · " + TrashCopy.daysLeft(item.daysLeft)
    }

    @ViewBuilder private var buttons: some View {
        Button(action: restore) {
            Text(TrashCopy.restore).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: HitTarget.minimum)
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.ink)
        Button(role: .destructive, action: deleteNow) {
            // The role's system red is too light on the card; ember keeps 4.5:1.
            Text(TrashCopy.deleteNow).font(.subheadline.weight(.semibold)).foregroundStyle(Color.toneError)
                .padding(.horizontal, 14).frame(minHeight: HitTarget.minimum)
        }
        .buttonStyle(.borderless)
    }
}
