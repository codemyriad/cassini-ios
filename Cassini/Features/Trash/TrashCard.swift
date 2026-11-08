import SwiftUI
import CassiniNotebook

/// A note in Recently Deleted: its title and duration, "Deleted Oct 2 · 23 days left", then Restore and Delete now.
struct TrashCard: View {
    let item: TrashItem
    let restore: () -> Void
    let deleteNow: () -> Void
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerLayout {
                Text(item.title).font(.headline).foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(TimeText.clock(item.duration)).font(.caption.monospacedDigit()).foregroundStyle(Color.muted)
            }
            Text(meta).font(.caption).foregroundStyle(Color.muted)
            // Side by side, or one under the other at accessibility sizes. Not a ViewThatFits: at the largest size on an
            // iPad its unused row left the audit three clipped texts without an element.
            buttonsLayout { buttons }
            .padding(.top, 8)
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
        .cardBackground(radius: Radius.control)
    }

    private var headerLayout: AnyLayout {
        dynamicType.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
    }

    private var buttonsLayout: AnyLayout {
        dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
    }

    private var meta: String {
        TrashCopy.deleted(item.deletedOn, calendar: calendar) + " · " + TrashCopy.daysLeft(item.daysLeft)
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
