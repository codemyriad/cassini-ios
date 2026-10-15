import Foundation

/// Which redirects a download follows (Android's `RedirectPolicy`). The `HTTPTransport` never follows a redirect
/// itself; `ArtifactFetcher` asks `next` for each `Location`, so a model download can reach only `hosts`, over HTTPS
/// when `httpsOnly`, in at most `maxRedirects` hops. The start URL is not checked here: it comes from `ModelCatalog`.
///
/// Host entries follow `ModelCatalog.downloadHosts`: `*.example.com` matches subdomains only, anything else matches
/// the whole host. Matching ignores case and a trailing dot.
public struct RedirectPolicy: Hashable, Sendable {
    public static let maxRedirectsDefault = 5

    /// The policy for model downloads: HTTPS to `ModelCatalog.downloadHosts`, at most 5 hops.
    public static let downloads = RedirectPolicy(hosts: ModelCatalog.downloadHosts)

    /// The end of the message for a redirect to a host or scheme the policy does not allow; `ModelInstaller` reads it
    /// as `HOST_NOT_ALLOWED`.
    static let refusedSuffix = "is not allowed"

    /// The schemes `java.net.URL` knows, so a location with another scheme is a bad location as on Android.
    private static let knownSchemes: Set<String> = ["http", "https", "ftp", "file", "jar", "mailto"]

    public var hosts: [String]
    public var httpsOnly: Bool
    public var maxRedirects: Int

    public init(hosts: [String], httpsOnly: Bool = true, maxRedirects: Int = RedirectPolicy.maxRedirectsDefault) {
        self.hosts = hosts; self.httpsOnly = httpsOnly; self.maxRedirects = maxRedirects
    }

    /// Whether `url` is a target this policy allows.
    public func allows(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        let schemeAllowed = scheme == "https" || (!httpsOnly && scheme == "http")
        return schemeAllowed && hostAllowed(url.host(percentEncoded: false))
    }

    public func hostAllowed(_ host: String?) -> Bool {
        var name = (host ?? "").lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty else { return false }
        return hosts.contains { entry in
            let pattern = entry.lowercased()
            return pattern.hasPrefix("*.") ? name.hasSuffix(pattern.dropFirst()) : name == pattern
        }
    }

    /// The URL redirect number `hop` (from 1) leads to: `location` resolved against `from`. Throws a `DOWNLOAD`
    /// `ModelError` when there is no usable location, when `hop` is past `maxRedirects`, or when the target is not
    /// allowed (another host, or plain HTTP).
    public func next(from: URL, location: String?, hop: Int) throws -> URL {
        let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = trimmed.isEmpty ? nil : Self.resolve(from, trimmed)
        let refusal: String? = if hop > maxRedirects {
            "More than \(maxRedirects) redirects"
        } else if trimmed.isEmpty {
            "Redirect without a location"
        } else if let target {
            allows(target) ? nil
                : "Redirect to \(target.scheme ?? "")://\(target.host(percentEncoded: false) ?? "") \(Self.refusedSuffix)"
        } else {
            "Bad redirect location"
        }
        if let refusal { throw ModelError(.modelDownload, refusal) }
        guard let target else { throw ModelError(.modelDownload, "Redirect") }
        return target
    }

    private static func resolve(_ from: URL, _ location: String) -> URL? {
        guard let url = URL(string: location, relativeTo: from)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), knownSchemes.contains(scheme) else { return nil }
        return url
    }
}
