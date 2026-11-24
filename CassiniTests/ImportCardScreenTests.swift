import SwiftUI
import XCTest
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import Cassini

private actor ImportScreenGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor final class ImportCardScreenTests: XCTestCase {
    func testImportingAndFailedCardsRenderInBothThemesAndAccessibleTextSizes() async throws {
        let tracker = ImportTracker(clock: FakeClock())
        let gate = ImportScreenGate()
        let task = tracker.start(displayName: "Audio.ogg", source: URL(filePath: "/Audio.ogg")) {
            await gate.wait(); return .rejected(.cannotOpen)
        }
        let active = try XCTUnwrap(tracker.cards.first)
        XCTAssertNil(active.failure)
        for theme in [ColorScheme.light, .dark] {
            for type in [DynamicTypeSize.large, .accessibility5] {
                let host = UIHostingController(rootView: ImportCardView(card: active, retry: {}, dismiss: {})
                    .environment(\.colorScheme, theme).dynamicTypeSize(type))
                host.loadViewIfNeeded()
                let size = host.sizeThatFits(in: CGSize(width: 320, height: 2000))
                XCTAssertGreaterThan(size.height, 60)
                XCTAssertLessThanOrEqual(size.width, 320.5)
            }
        }
        await gate.release(); _ = await task.value
        let failed = try XCTUnwrap(tracker.cards.first)
        XCTAssertEqual(failed.id, active.id)
        XCTAssertEqual(failed.failure, .cannotOpen)
        let host = UIHostingController(rootView: ImportCardView(card: failed, retry: {}, dismiss: {}))
        host.loadViewIfNeeded()
        XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: 320, height: 2000)).height, 60)
        XCTAssertEqual(StatusBadgeCopy.template("states.badge.importing", language: "en"), "Importing…")
        XCTAssertEqual(StatusBadgeCopy.template("states.badge.needsAttention", language: "en"), "Needs attention")
        XCTAssertEqual(LibraryPhase1Copy.tryAgain, LibraryCopy.tryAgain)
    }

    func testCancellingAColdImportForwardsCancellationAndLeavesNoFailureOrMeeting() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        // Startup is the event gate: no service or file access can begin until graph.start returns.
        let task = test.graph.imports.importFile(test.root.appendingPathComponent("Cancelled.wav"), opensNote: false)
        XCTAssertEqual(test.graph.imports.tracker.cards.count, 1)
        task.cancel()
        await test.graph.start()
        let outcome = await task.value
        XCTAssertNil(outcome)
        XCTAssertTrue(test.graph.imports.tracker.cards.isEmpty)
        XCTAssertNil(test.graph.imports.tracker.failure)
        XCTAssertTrue(test.graph.library.notes.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: test.root.path).filter { UUID(uuidString: $0) != nil }, [])
    }

    func testPickerContainsOnlyDecidedAudioTypesAndZIP() {
        XCTAssertEqual(Set(ImportStore.contentTypes.map(\.identifier)), Set(ImportPolicy.utis + ["public.zip-archive"]))
        XCTAssertFalse(ImportStore.contentTypes.contains(.audio))
    }
}
