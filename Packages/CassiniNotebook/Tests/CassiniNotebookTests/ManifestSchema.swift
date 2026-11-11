#if os(macOS)
import CryptoKit
import Foundation
import CassiniCore

/// Independent producer-output validation against cassini-format 32f37a6's complete pinned schema.
/// `scripts/test.sh` prepares the interpreter. For standalone `swift test`, set CASSINI_CONFORMANCE and run:
/// `export CASSINI_SCHEMA_PYTHON="$(scripts/prepare-schema-tests.sh "$CASSINI_TEST_CACHE")"`.
/// No dependency installation or network access occurs inside a unit test.
enum ManifestSchema {
    private static let schema = Conformance.directory
        .appendingPathComponent("../cassini-portable-meeting-manifest-v1.schema.json").standardized
    private static let sha256 = "1effc7095228c5b8df61754b80f401cb9b4c9ddf24fca45bab7a4f703589ad31"

    static func check(_ document: CassiniDocument) throws {
        guard let python = ProcessInfo.processInfo.environment["CASSINI_SCHEMA_PYTHON"], !python.isEmpty else {
            throw Failure("Schema validator is not prepared. Run scripts/test.sh fast, or export CASSINI_SCHEMA_PYTHON "
                          + "from scripts/prepare-schema-tests.sh with CASSINI_TEST_CACHE before standalone swift test.")
        }
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw Failure("CASSINI_SCHEMA_PYTHON is not an executable interpreter: \(python)")
        }
        let bytes = try Data(contentsOf: schema)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard hash == sha256 else { throw Failure("Manifest schema does not match the pinned cassini-format 32f37a6 SHA-256.") }
        guard let manifest = document.manifest else { throw Failure("Exported document has no manifest to validate.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-manifest-schema-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("manifest.json")
        try Data(manifest.serialized().utf8).write(to: input)
        let validator = #"""
        import json, sys
        try:
            from jsonschema import Draft202012Validator, FormatChecker
        except ImportError as error:
            sys.exit('Schema-test dependency missing: ' + str(error) + '. Run scripts/prepare-schema-tests.sh; tests never install packages.')
        with open(sys.argv[1], encoding='utf-8') as source:
            schema = json.load(source)
        with open(sys.argv[2], encoding='utf-8') as source:
            manifest = json.load(source)
        Draft202012Validator.check_schema(schema)
        checker = FormatChecker()
        assert 'date-time' in checker.checkers, 'date-time checker is not registered'
        assert checker.conforms('2026-11-09T09:31:48Z', 'date-time')
        assert not checker.conforms('2026-02-30T09:31:48Z', 'date-time'), 'date-time checking is inactive'
        errors = list(Draft202012Validator(schema, format_checker=checker).iter_errors(manifest))
        for error in errors[:10]:
            print('/' + '/'.join(map(str, error.absolute_path)) + ': ' + error.message, file=sys.stderr)
        sys.exit(1 if errors else 0)
        """#
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", "-B", "-c", validator, schema.path, input.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let diagnostic = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit() // Completion event; the test runner supplies the outer hang guard.
        guard process.terminationStatus == 0 else {
            throw Failure("Pinned JSON Schema rejected the exported manifest:\n" + String(decoding: diagnostic, as: UTF8.self))
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif
