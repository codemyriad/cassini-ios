import Foundation
import Testing
@testable import CassiniWhistle

struct WhistleRuntimeLocationTests {
    private func fixture(_ check: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Cassini.app")
        let binary = app.appendingPathComponent("Frameworks/CassiniWhistleRuntime.framework/CassiniWhistleRuntime")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("opaque Apple-processed executable".utf8).write(to: binary)
        try check(root, app, binary)
    }

    @Test func locatesOpaqueRuntimeWithoutParsingOrChangingItsCode() throws {
        try fixture { _, app, binary in
            let before = try Data(contentsOf: binary)
            let located = try WhistleRuntimeLocation.binary(application: app, trustedApplication: app)
            #expect(located == binary.resolvingSymlinksInPath().standardizedFileURL)
            #expect(try Data(contentsOf: located) == before)
            // Location is not authentication. The unchanged image is handed to iOS's signed-code loader later.
        }
    }

    @Test func rejectsAnotherApplicationEvenWithTheSamePathPrefix() throws {
        try fixture { root, app, _ in
            let other = root.appendingPathComponent("Cassini.app.extra")
            #expect(throws: WhistleError.integrity) {
                try WhistleRuntimeLocation.binary(application: other, trustedApplication: app)
            }
        }
    }

    @Test func rejectsMissingRuntimeAndDirectoryInItsPlace() throws {
        try fixture { _, app, binary in
            try FileManager.default.removeItem(at: binary)
            #expect(throws: WhistleError.integrity) {
                try WhistleRuntimeLocation.binary(application: app, trustedApplication: app)
            }
            try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: false)
            #expect(throws: WhistleError.integrity) {
                try WhistleRuntimeLocation.binary(application: app, trustedApplication: app)
            }
        }
    }

    @Test func rejectsRuntimeSymlinkOutsideTheSignedApplication() throws {
        try fixture { root, app, binary in
            let outside = root.appendingPathComponent("external-runtime")
            try Data("untrusted".utf8).write(to: outside)
            try FileManager.default.removeItem(at: binary)
            try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: outside)
            #expect(throws: WhistleError.integrity) {
                try WhistleRuntimeLocation.binary(application: app, trustedApplication: app)
            }
        }
    }

    @Test func rejectsFrameworkDirectorySymlink() throws {
        try fixture { root, app, binary in
            let framework = binary.deletingLastPathComponent()
            let moved = root.appendingPathComponent("external.framework")
            try FileManager.default.moveItem(at: framework, to: moved)
            try FileManager.default.createSymbolicLink(at: framework, withDestinationURL: moved)
            #expect(throws: WhistleError.integrity) {
                try WhistleRuntimeLocation.binary(application: app, trustedApplication: app)
            }
        }
    }
}
