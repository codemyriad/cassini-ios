import Foundation
import CoreGraphics
import Testing

struct RowScrollGeometryTests {
    let band = CGRect(x: 0, y: 100, width: 320, height: 600)

    @Test func measuredCorrectionEndsTheOldFullSwipeOscillation() throws {
        let below = CGRect(x: 0, y: 640, width: 320, height: 140)
        let above = below.offsetBy(dx: 0, dy: -600)
        #expect(above.minY < band.minY)
        #expect(above.offsetBy(dx: 0, dy: 600) == below)
        let correction = try #require(RowScrollGeometry.correction(for: below, within: band))
        #expect(correction == -80)
        let placed = below.offsetBy(dx: 0, dy: correction)
        #expect(RowScrollGeometry.correction(for: placed, within: band) == 0)
        #expect(placed.minY >= band.minY && placed.maxY <= band.maxY)
    }

    @Test func gesturesStayWithinTheClearBandAndConvergeInBothDirections() throws {
        let positions: [CGFloat] = [-800, 40, 100, 560, 640, 1600]
        for initialY in positions {
            var row = CGRect(x: 0, y: initialY, width: 320, height: 140)
            for _ in 0..<12 {
                let movement = try #require(RowScrollGeometry.correction(for: row, within: band))
                if movement == 0 { break }
                #expect(abs(movement) < band.height / 2)
                #expect(band.midY + movement > band.minY && band.midY + movement < band.maxY)
                row = row.offsetBy(dx: 0, dy: movement)
            }
            #expect(row.minY >= band.minY && row.maxY <= band.maxY)
        }
    }

    @Test func shortCorrectionsCrossTheDragThresholdWithoutHidingTheRow() throws {
        for row in [CGRect(x: 0, y: 86.3, width: 320, height: 140),
                    CGRect(x: 0, y: 573.7, width: 320, height: 140)] {
            let movement = try #require(RowScrollGeometry.correction(for: row, within: band))
            #expect(abs(movement) == 32)
            let placed = row.offsetBy(dx: 0, dy: movement)
            #expect(placed.minY >= band.minY && placed.maxY <= band.maxY)
            #expect(RowScrollGeometry.correction(for: placed, within: band) == 0)
        }
        let almostFull = CGRect(x: 0, y: 99, width: 320, height: 596)
        let movement = try #require(RowScrollGeometry.correction(for: almostFull, within: band))
        #expect(movement == 4, "Never overshoot the spare clearance")
        #expect(RowScrollGeometry.correction(for: almostFull.offsetBy(dx: 0, dy: movement), within: band) == 0)
    }

    @Test func impossibleGeometryFailsRatherThanDroppingTheClearanceRequirement() {
        #expect(RowScrollGeometry.correction(for: .zero, within: band) == nil)
        #expect(RowScrollGeometry.correction(for: band, within: .zero) == nil)
        #expect(RowScrollGeometry.correction(for: band.insetBy(dx: 0, dy: -1), within: band) == nil)
    }

    @Test func subpixelSnapshotNoiseDoesNotCauseAnotherGesture() {
        let row = CGRect(x: 0, y: band.minY - 0.00001, width: 320, height: band.height)
        #expect(RowScrollGeometry.correction(for: row, within: band) == 0)
    }
}
