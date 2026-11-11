import Foundation
import CassiniCore
import CassiniNotebook

enum BulkTransferCopy {
    static let filter = String(localized: "import.filter.cassiniAndZip", table: "BulkTransfer")
    static let cancel = String(localized: "common.cancel", table: "BulkTransfer")
    static let done = String(localized: "common.done", table: "BulkTransfer")
    static let all = String(localized: "export.zip.all", table: "BulkTransfer")
    static let selected = String(localized: "export.zip.selected", table: "BulkTransfer")
    static let cancelled = String(localized: "import.cancelled", table: "BulkTransfer")
    static func importing(_ progress: TransferProgress) -> String {
        String(format: String(localized: "import.progress", table: "BulkTransfer"), locale: .current,
               Int64(progress.done), Int64(progress.total))
    }
    static func exporting(_ progress: TransferProgress) -> String {
        String(format: String(localized: "export.zip.progress", table: "BulkTransfer"), locale: .current,
               Int64(progress.done), Int64(progress.total))
    }
    static func exported(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "export.zip.done", table: "BulkTransfer"), Int64(count))
    }
    static func summary(_ value: ImportSummary) -> String {
        var parts: [String] = []
        if value.imported > 0 { parts.append(String.localizedStringWithFormat(String(localized: "import.summary.imported", table: "BulkTransfer"), Int64(value.imported))) }
        if value.duplicates > 0 { parts.append(String.localizedStringWithFormat(String(localized: "import.summary.duplicates", table: "BulkTransfer"), Int64(value.duplicates))) }
        if value.unsupported > 0 { parts.append(String.localizedStringWithFormat(String(localized: "import.summary.unsupported", table: "BulkTransfer"), Int64(value.unsupported))) }
        if value.failed > 0 { parts.append(String.localizedStringWithFormat(String(localized: "import.summary.failed", table: "BulkTransfer"), Int64(value.failed))) }
        return parts.joined(separator: " · ")
    }
    static func archive(_ failure: ZIPFailure) -> String {
        switch failure {
        case .encrypted: String(localized: "import.zip.failed.encrypted", table: "BulkTransfer")
        case .unsafePaths: String(localized: "import.zip.failed.unsafePaths", table: "BulkTransfer")
        case .tooLarge: String(localized: "import.zip.failed.tooLarge", table: "BulkTransfer")
        case .empty: String(localized: "import.zip.failed.empty", table: "BulkTransfer")
        case .damaged, .entry: String(localized: "import.zip.failed.damaged", table: "BulkTransfer")
        }
    }
}
