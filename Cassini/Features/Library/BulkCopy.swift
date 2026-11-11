import Foundation
import CassiniCore
import CassiniEngine

/// Shared D96 strings. IDs and all translations are pinned in docs/shared-strings-pin.md.
enum BulkCopy {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        switch key {
        case "common.cancel": return NSLocalizedString("common.cancel", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID common.cancel")
        case "import.filter.cassiniAndZip": return NSLocalizedString("import.filter.cassiniAndZip", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID import.filter.cassiniAndZip")
        case "import.progress": return NSLocalizedString("import.progress", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID import.progress")
        case "import.cancelled": return NSLocalizedString("import.cancelled", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID import.cancelled")
        case "import.summary.imported": return NSLocalizedString("import.summary.imported", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID import.summary.imported")
        case "import.summary.duplicates": return NSLocalizedString("import.summary.duplicates", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID import.summary.duplicates")
        case "import.summary.unsupported": return NSLocalizedString("import.summary.unsupported", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID import.summary.unsupported")
        case "import.summary.failed": return NSLocalizedString("import.summary.failed", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID import.summary.failed")
        case "import.zip.failed.damaged": return NSLocalizedString("import.zip.failed.damaged", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID import.zip.failed.damaged")
        case "import.zip.failed.encrypted": return NSLocalizedString("import.zip.failed.encrypted", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID import.zip.failed.encrypted")
        case "import.zip.failed.unsafePaths": return NSLocalizedString("import.zip.failed.unsafePaths", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID import.zip.failed.unsafePaths")
        case "import.zip.failed.tooLarge": return NSLocalizedString("import.zip.failed.tooLarge", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID import.zip.failed.tooLarge")
        case "import.zip.failed.empty": return NSLocalizedString("import.zip.failed.empty", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID import.zip.failed.empty")
        case "export.zip.all": return NSLocalizedString("export.zip.all", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID export.zip.all")
        case "export.zip.selected": return NSLocalizedString("export.zip.selected", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID export.zip.selected")
        case "export.zip.progress": return NSLocalizedString("export.zip.progress", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID export.zip.progress")
        case "export.zip.done": return NSLocalizedString("export.zip.done", tableName: "Bulk", bundle: bundle, comment: "Shared D96 catalog ID export.zip.done")
        default: preconditionFailure("Unknown shared bulk-copy ID")
        }
    }

    static var cancel: String { text("common.cancel") }
    static var filter: String { text("import.filter.cassiniAndZip") }
    static var exportAll: String { text("export.zip.all") }
    static var exportSelected: String { text("export.zip.selected") }
    static var cancelled: String { text("import.cancelled") }

    static func progress(_ key: String, _ value: BulkProgress, locale: Locale = .autoupdatingCurrent,
                         bundle: Bundle = .main) -> String {
        let current = min(max(0, value.completed) + 1, max(1, value.total))
        return text(key, bundle: bundle)
            .replacingOccurrences(of: "{done}", with: current.formatted(.number.locale(locale)))
            .replacingOccurrences(of: "{total}", with: value.total.formatted(.number.locale(locale)))
    }

    static func count(_ key: String, _ count: Int, bundle: Bundle = .main) -> String {
        String.localizedStringWithFormat(text(key, bundle: bundle), Int64(count))
    }

    static func summary(_ value: BulkImportSummary, bundle: Bundle = .main) -> String {
        [("import.summary.imported", value.imported), ("import.summary.duplicates", value.duplicates),
         ("import.summary.unsupported", value.unsupported), ("import.summary.failed", value.failed)]
            .filter { $0.1 > 0 }
            .map { count($0.0, $0.1, bundle: bundle) }
            .joined(separator: " · ")
    }

    static func archiveFailure(_ error: ZipArchiveError, bundle: Bundle = .main) -> String {
        let suffix: String = switch error {
        case .damaged: "damaged"
        case .encrypted: "encrypted"
        case .unsafePaths: "unsafePaths"
        case .tooLarge: "tooLarge"
        case .empty: "empty"
        }
        return text("import.zip.failed.\(suffix)", bundle: bundle)
    }
}

struct BulkProgress: Equatable, Sendable {
    var completed: Int
    var total: Int
}
