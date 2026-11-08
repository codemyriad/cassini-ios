import Foundation

/// Locate only this app's sealed, private framework. This is a path check, not a code-signature verifier.
/// iOS authenticates executable code at load; its App Store encryption is opaque to the application.
public enum WhistleRuntimeLocation {
    public static func binary(application: URL, trustedApplication: URL) throws -> URL {
        guard application.isFileURL, trustedApplication.isFileURL else { throw WhistleError.integrity }
        let trusted = trustedApplication.resolvingSymlinksInPath().standardizedFileURL
        guard application.resolvingSymlinksInPath().standardizedFileURL == trusted else {
            throw WhistleError.integrity
        }
        let relative = "Frameworks/CassiniWhistleRuntime.framework/CassiniWhistleRuntime"
        let expected = trusted.appendingPathComponent(relative).standardizedFileURL
        let actual = application.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard actual == expected,
              (try? actual.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw WhistleError.integrity
        }
        return actual
    }
}
