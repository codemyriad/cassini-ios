import Foundation
import Observation

/// A row of "Source code and notices". `sourceCode` opens the browser; every other row opens its text.
public enum LicenseEntry: String, CaseIterable, Codable, Hashable, Sendable {
    case cassini, thirdParty, models, modelSources, privacy, sourceCode

    /// Licence texts are set in mono; the notices and the privacy text in body type.
    public var isLicenceText: Bool { self == .cassini || self == .thirdParty }
}

/// The text of an opened row.
public struct LicenseText: Hashable, Sendable {
    public var entry: LicenseEntry
    public var text: String
    public init(entry: LicenseEntry, text: String) { self.entry = entry; self.text = text }

    /// The text split at blank lines, each paragraph trimmed, for the text pane.
    public var paragraphs: [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// The repository the "Source code on GitHub" row opens.
public let sourceCodeURL = URL(string: "https://github.com/codemyriad/cassini-ios")!

/// The text of each row, from the app's bundled files:
///
/// - Cassini: the GPLv3 text (`Cassini-GPL-3.0.txt`, a copy of the repository's `LICENSE`).
/// - Third-party notices: `ThirdPartyNotices.txt` without its model notices, then ONNX Runtime's own third-party
///   notices (`ONNXRuntime-ThirdPartyNotices.txt`, upstream's file for the release the runtime links).
/// - Model notices: the notices' sections about the models, then the model host's `NOTICE.txt` as an installed model
///   keeps it (D4: the notices come with the downloaded models; before the first download there is none).
/// - Where the models come from: the Network section of `Privacy.txt`, then the URL of the manifest, of the notices
///   and of every file Cassini downloads.
/// - Privacy: `Privacy.txt`, its headings without their `#` marks.
///
/// The notices are sections that start with a title line and are separated by two blank lines.
public struct LicenseTexts: Sendable {
    public static let gpl = "Cassini-GPL-3.0.txt"
    public static let notices = "ThirdPartyNotices.txt"
    public static let onnxRuntimeNotices = "ONNXRuntime-ThirdPartyNotices.txt"
    public static let privacy = "Privacy.txt"
    /// The titles of the notices' sections about models.
    public static let modelSections = ["Speech recognition models", "Downloaded models"]
    public static let networkHeading = "## Network"

    /// The text of a bundled file by name.
    private let read: @Sendable (String) throws -> String
    /// Each downloaded file and its pinned URL.
    private let downloads: [(name: String, url: URL)]
    /// The model host's notices as an installed model keeps them; nil when no model is installed.
    private let notice: @Sendable () -> String?

    public init(downloads: [(name: String, url: URL)], notice: @escaping @Sendable () -> String? = { nil },
                read: @escaping @Sendable (String) throws -> String) {
        self.downloads = downloads
        self.notice = notice
        self.read = read
    }

    public func text(_ entry: LicenseEntry) throws -> String {
        switch entry {
        case .cassini: try read(Self.gpl)
        case .thirdParty:
            Self.join(try noticeSections().filter { !Self.modelSections.contains($0.title) }.map(\.text)
                      + ["ONNX Runtime third-party notices", try read(Self.onnxRuntimeNotices)])
        case .models:
            Self.join(try noticeSections().filter { Self.modelSections.contains($0.title) }.map(\.text) + [notice() ?? ""])
        case .modelSources:
            Self.join([Self.section(try read(Self.privacy), heading: Self.networkHeading)]
                      + downloads.map { "\($0.name)\n\($0.url.absoluteString)" })
        case .privacy: Self.plain(try read(Self.privacy))
        case .sourceCode: sourceCodeURL.absoluteString
        }
    }

    private func noticeSections() throws -> [(title: String, text: String)] {
        try read(Self.notices).components(separatedBy: "\n\n\n").compactMap { block in
            let text = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title = text.split(separator: "\n", maxSplits: 1).first else { return nil }
            return (String(title).trimmingCharacters(in: .whitespaces), text)
        }
    }

    /// The Markdown section that starts with the heading line `heading` (a prefix), up to the next `## `, its heading
    /// as plain text.
    public static func section(_ markdown: String, heading: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(heading) }) else { return "" }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        return plain(lines[start..<end].joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Headings without their `#` marks.
    public static func plain(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { line in
            guard line.hasPrefix("#") else { return line }
            return String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    private static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// "Source code and notices": every `LicenseEntry` in order. A row opens its text; "Source code on GitHub" opens the
/// browser instead. The opened row is kept by the screen (scene storage) and comes back with `restore(_:)`, its text
/// read again. A text that cannot be read opens nothing.
@MainActor @Observable public final class LicensesModel {
    public enum Effect: Hashable, Sendable {
        case openURL(URL)
    }

    public let entries = LicenseEntry.allCases
    /// The opened row's text.
    public private(set) var open: LicenseText?
    /// The row being opened or open, as the screen saves it.
    public private(set) var opened: LicenseEntry?

    @ObservationIgnored private let text: @Sendable (LicenseEntry) async throws -> String
    @ObservationIgnored public var onEffect: (Effect) -> Void = { _ in }

    public init(text: @escaping @Sendable (LicenseEntry) async throws -> String) {
        self.text = text
    }

    public func open(_ entry: LicenseEntry) async {
        if entry == .sourceCode {
            onEffect(.openURL(sourceCodeURL))
            return
        }
        opened = entry
        await load(entry)
    }

    /// Opens the row the screen saved, as after the app was closed.
    public func restore(_ entry: LicenseEntry?) async {
        guard let entry, entry != .sourceCode, open == nil else { return }
        await open(entry)
    }

    /// The text pane's Back.
    public func closeText() {
        opened = nil
        open = nil
    }

    private func load(_ entry: LicenseEntry) async {
        do {
            let value = try await text(entry)
            if opened == entry { open = LicenseText(entry: entry, text: value) }
        } catch {
            if opened == entry { opened = nil }
        }
    }
}
