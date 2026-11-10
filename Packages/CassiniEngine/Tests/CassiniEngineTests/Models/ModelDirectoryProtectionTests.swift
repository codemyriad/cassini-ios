import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting

@Suite struct ModelDirectoryProtectionTests {
    @Test(arguments: [false, true])
    func newAndResumedDirectoriesGetProtectionBeforeFirstLockedUse(_ existing: Bool) throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let directory = folder.root.appendingPathComponent("models/model/.revision.staging")
        let prefix = directory.appendingPathComponent("resume.part")
        if existing {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("prefix".utf8).write(to: prefix)
        }
        let files = ProtectionFiles()
        try ModelRepository.prepareDirectory(directory, using: files)
        let observed = Set(files.protectedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        let expected = Set((existing ? [directory, prefix] : [directory]).map { $0.resolvingSymlinksInPath().path })
        #expect(observed == expected,
                "An old partial needs its own migration; changing only the parent does not change its class")
        #expect(files.protection == .completeUntilFirstUserAuthentication)
        #expect(files.existedWhenProtected)
        if existing { #expect(try Data(contentsOf: prefix) == Data("prefix".utf8)) }
    }

    @Test func aProtectionFailureCannotBeIgnored() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let files = ProtectionFiles(failProtection: true)
        #expect(throws: CocoaError.self) {
            try ModelRepository.prepareDirectory(folder.root.appendingPathComponent("models"), using: files)
        }
        #expect(files.protectedPaths.count == 1)
    }
}

/// Observes the real FileManager boundary without depending on macOS exposing iOS Data Protection attributes.
private final class ProtectionFiles: FileManager, @unchecked Sendable {
    private struct State {
        var paths: [String] = []
        var protection: FileProtectionType?
        var existed = false
    }
    private let state = Mutex(State())
    private let failProtection: Bool
    init(failProtection: Bool = false) { self.failProtection = failProtection; super.init() }
    var protectedPaths: [String] { state.withLock { $0.paths } }
    var protection: FileProtectionType? { state.withLock { $0.protection } }
    var existedWhenProtected: Bool { state.withLock { $0.existed } }
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        state.withLock {
            $0.paths.append(path)
            $0.protection = attributes[.protectionKey] as? FileProtectionType
            $0.existed = FileManager.default.fileExists(atPath: path)
        }
        if failProtection { throw CocoaError(.fileWriteNoPermission) }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
