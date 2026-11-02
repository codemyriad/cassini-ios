import Foundation
import CassiniNotebook

/// A size in the shown language by the shared rule (`SizeText`: "443 MB", "1,2 GB" in Italian, "458 Ko" in French),
/// with the units of the Notices table. The model download screen and the On-device models rows use it.
enum SizeCopy {
    static func text(_ bytes: Int64, locale: Locale) -> String {
        switch SizeText(bytes: bytes) {
        case .kilobytes(let kb): String(localized: "\(kb) KB", table: "Notices", comment: "A size under 1 MB")
        case .megabytes(let mb): String(localized: "\(mb) MB", table: "Notices")
        case .gigabyteTenths(let tenths):
            String(localized: "\((Double(tenths) / 10).formatted(.number.precision(.fractionLength(1)).locale(locale))) GB",
                   table: "Notices")
        }
    }
}
