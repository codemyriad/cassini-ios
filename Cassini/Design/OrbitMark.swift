import SwiftUI
import UIKit

/// The app/store name remains distinct from the approved in-app wordmark (L-15).
enum ProductName {
    static let full = "Cassini talk"
    static let wordmark = "cassini.talk"
}

struct OrbitMark: View {
    var size: CGFloat = 36
    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Image(decorative: "SaturnNav").renderingMode(.original).resizable().scaledToFit()
            } else {
                FixedSaturnImage(size: size)
            }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// iOS 18's preserved-vector image needs an explicit fixed-icon sizing policy. The native view keeps the same
/// original asset and aspect fit without enlarging its intrinsic dimensions at accessibility content sizes.
private struct FixedSaturnImage: UIViewRepresentable {
    let size: CGFloat

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: UIImage(named: "SaturnNav")?.withRenderingMode(.alwaysOriginal))
        view.contentMode = .scaleAspectFit
        view.adjustsImageSizeForAccessibilityContentSizeCategory = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? size, height: proposal.height ?? size)
    }
}
