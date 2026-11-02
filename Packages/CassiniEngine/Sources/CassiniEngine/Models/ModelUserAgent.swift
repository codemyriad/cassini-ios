import Foundation

/// The User-Agent of every model request (D54): `CassiniTalk/<marketing version> (iOS <version>; build <build>)`, for
/// example `CassiniTalk/0.1.0 (iOS 26.1; build 2)`. The app builds it once, from its bundle and the system version, and
/// hands it to the transport, which sends it on the manifest, every artifact, `NOTICE.txt` and every redirect hop. It
/// names nothing that identifies a person or a device: no device name or model, no locale, no install id.
public enum ModelUserAgent {
    /// `version` is `CFBundleShortVersionString`, `build` is `CFBundleVersion`, `system` the iOS version.
    public static func string(version: String, system: OperatingSystemVersion, build: String) -> String {
        "CassiniTalk/\(version) (iOS \(systemVersion(system)); build \(build))"
    }

    /// `major.minor`, and `.patch` when there is one, as iOS writes its own version ("26.1", "26.0.1").
    public static func systemVersion(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }
}
