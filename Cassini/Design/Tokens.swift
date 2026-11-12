import SwiftUI
import CassiniNotebook

extension Tone {
    var color: Color {
        switch self {
        case .ok: .toneOK
        case .info: .toneInfo
        case .warn: .toneWarn
        case .error: .toneError
        case .plain: .tonePlain
        }
    }

    var background: Color { color.opacity(0.09) }
}

enum Radius {
    static let chip: CGFloat = 8
    static let field: CGFloat = 14
    static let control: CGFloat = 16
    static let card: CGFloat = 20
}

enum Spacing {
    static let tight: CGFloat = 8
    static let row: CGFloat = 12
    static let card: CGFloat = 18
    static let section: CGFloat = 26
    static let gutter: CGFloat = 24
}

/// The widest a screen's content gets on a wide window, Android's `MaxContentWidth`: every screen caps its content
/// at it, centred, and its background still fills the window. On a phone it changes nothing.
enum ReadableWidth {
    static let content: CGFloat = 560
}

extension View {
    /// Caps the content at `ReadableWidth.content`, centred in the width it gets.
    func readableWidth() -> some View {
        frame(maxWidth: ReadableWidth.content).frame(maxWidth: .infinity)
    }

    /// Caps a list's or form's rows at `ReadableWidth.content` with side margins, so the list still scrolls (and
    /// shows its indicator) across the window.
    func readableListWidth() -> some View { modifier(ReadableListWidth()) }
}

private struct ReadableListWidth: ViewModifier {
    @State private var geometry = Geometry()

    /// The list's visible width and the insets beside it: in a split view the detail column's list runs under the
    /// sidebar, which is its leading safe-area inset.
    private struct Geometry: Equatable {
        var width: CGFloat = 0
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
    }

    /// Below this the list keeps its own margins (a phone).
    private static let minimumMargin: CGFloat = 20

    func body(content: Content) -> some View {
        let margin = (geometry.width - ReadableWidth.content) / 2
        Group {
            if margin > Self.minimumMargin {
                content
                    .contentMargins(.leading, geometry.leading + margin, for: .scrollContent)
                    .contentMargins(.trailing, geometry.trailing + margin, for: .scrollContent)
            } else {
                content
            }
        }
        .onGeometryChange(for: Geometry.self) { proxy in
            Geometry(width: proxy.size.width, leading: proxy.safeAreaInsets.leading, trailing: proxy.safeAreaInsets.trailing)
        } action: { geometry = $0 }
    }
}

/// The smallest tap target.
enum HitTarget {
    static let minimum: CGFloat = 44
}
