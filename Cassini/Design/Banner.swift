import SwiftUI
import CassiniNotebook

/// A catalogue banner with the copy, tone and actions of `spec` (Android `Banner`): a tone dot, the title as a
/// heading, the body and up to two actions, the first filled and the second outlined. A dismissible spec with an
/// `onDismiss` gets a 44 pt close button labelled "Dismiss". A spec that announces is read by VoiceOver when it
/// appears.
struct Banner: View {
    let spec: BannerSpec
    var style: BannerStyle = .standard
    var onAction: (BannerAction) -> Void = { _ in }
    var onDismiss: (() -> Void)?

    var body: some View {
        let tone = spec.kind.tone
        let title = BannerCopy.title(spec)
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(tone.color).frame(width: 10, height: 10).padding(.top, 5).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(tone.color)
                    .accessibilityAddTraits(.isHeader)
                if let body = BannerCopy.body(spec, locale: locale) {
                    Text(body).font(.subheadline).foregroundStyle(Color.ink)
                }
                if !spec.actions.isEmpty { actions.padding(.top, 6) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if spec.dismissible, let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(Color.muted)
                        .frame(width: HitTarget.minimum, height: HitTarget.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -12).padding(.trailing, -12)
                .accessibilityLabel(BannerCopy.dismiss)
                .accessibilityIdentifier("dismissBanner")
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, spec.actions.isEmpty ? 14 : 8)
        .background {
            let shape = RoundedRectangle(cornerRadius: Radius.control)
            ZStack {
                if style == .onDark { shape.fill(Color.card) }
                shape.fill(tone.background)
                if spec.kind.tone == .plain { shape.strokeBorder(Color.muted.opacity(0.25)) }
            }
        }
        // The dark Recording screen keeps the light tones.
        .environment(\.colorScheme, style == .onDark ? .light : colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("banner.\(spec.kind.rawValue)")
        .onAppear { if spec.announce { AccessibilityNotification.Announcement(title).post() } }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    private var actions: some View {
        // Side by side, or one under the other when they do not fit (large text).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons }
            VStack(alignment: .leading, spacing: 4) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        ForEach(Array(spec.actions.enumerated()), id: \.element) { index, action in
            Button(BannerCopy.action(action)) { onAction(action) }
                .buttonStyle(BannerButtonStyle(filled: index == 0))
                .disabled(spec.disabledActions.contains(action))
                .accessibilityIdentifier("bannerAction.\(action.rawValue)")
        }
    }
}

/// Where a banner sits: on the paper of most screens, or on the always-dark Recording screen.
enum BannerStyle {
    case standard, onDark
}

/// The banner buttons: the first filled with ink, the others outlined; at least 44 pt tall to tap.
private struct BannerButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(filled ? Color.paper : Color.ink)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background {
                if filled { Capsule().fill(Color.ink) } else { Capsule().strokeBorder(Color.ink.opacity(0.35)) }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .frame(minHeight: HitTarget.minimum)
            .contentShape(Rectangle())
    }
}

/// A screen's banner list, one under the other.
struct BannerList: View {
    let specs: [BannerSpec]
    var style: BannerStyle = .standard
    var onAction: (BannerSpec, BannerAction) -> Void
    var onDismiss: (BannerSpec) -> Void

    var body: some View {
        if !specs.isEmpty {
            VStack(spacing: Spacing.row) {
                ForEach(specs) { spec in
                    Banner(spec: spec, style: style, onAction: { onAction(spec, $0) }, onDismiss: { onDismiss(spec) })
                }
            }
        }
    }
}
