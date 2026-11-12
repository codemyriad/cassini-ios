import Foundation
import CoreGraphics

/// Test-only geometry, shared with the UI target. Positive movement drags content down.
enum RowScrollGeometry {
    static func correction(for row: CGRect, within clear: CGRect) -> CGFloat? {
        guard !row.isEmpty, !clear.isEmpty, row.minY.isFinite, row.maxY.isFinite,
              clear.minY.isFinite, clear.maxY.isFinite, clear.height > 2,
              row.height <= clear.height else { return nil }
        // The UI caller already leaves an eight-point buffer around the actual bars.
        let epsilon: CGFloat = 0.25
        let overflow: CGFloat
        if row.minY < clear.minY - epsilon { overflow = clear.minY - row.minY }
        else if row.maxY > clear.maxY + epsilon { overflow = clear.maxY - row.maxY }
        else { return 0 }
        let limit = clear.height / 2 - 1
        return max(-limit, min(limit, overflow))
    }
}
