import Foundation

/// A size as Cassini shows it, by the shared rule of `ux-draft/format-vectors.json` (`sizeRule`, v4; decisions D6 and
/// D37.10), which every Cassini app follows so a model reads "443 MB" everywhere:
///
/// - MB is bytes / 1 048 576 rounded half up. When that rounded value is 1000 or more, GB is bytes / 1 073 741 824
///   rounded half up to one decimal, always shown with it.
/// - Below 1 MiB, KB is bytes / 1024 rounded half up; a size that is not 0 shows at least 1 KB, and 0 bytes is 0 KB.
///   When the rounded KB value is 1000 or more, the MB rule applies instead.
///
/// The rounding is decimal, on whole numbers, never binary floating point. The app writes the number in the reader's
/// locale ("1,2 GB" in Italian) and the unit from its string catalog.
public enum SizeText: Hashable, Sendable {
    case kilobytes(Int64)
    case megabytes(Int64)
    /// Tenths of a gigabyte: 13 is "1.3 GB".
    case gigabyteTenths(Int64)

    private static let kib: Int64 = 1024
    private static let mib: Int64 = 1_048_576
    private static let gib: Int64 = 1_073_741_824

    /// `bytes` by the shared rule; a negative size counts as 0.
    public init(bytes: Int64) {
        let bytes = max(0, bytes)
        if bytes < Self.mib {
            let kb = Self.halfUp(bytes, Self.kib)
            if kb < 1000 {
                self = .kilobytes(bytes == 0 ? 0 : max(1, kb))
                return
            }
        }
        let mb = Self.halfUp(bytes, Self.mib)
        self = mb >= 1000 ? .gigabyteTenths(Self.halfUp(bytes * 10, Self.gib)) : .megabytes(mb)
    }

    /// `value / unit` rounded half up, on whole numbers (sizes are far below the overflow).
    private static func halfUp(_ value: Int64, _ unit: Int64) -> Int64 { (value * 2 + unit) / (unit * 2) }

    /// The size in English with "." as the decimal point, as the shared vectors write it ("443 MB", "1.3 GB"),
    /// prefixed "about " when `approx`.
    public func english(approx: Bool = false) -> String {
        let text = switch self {
        case .kilobytes(let kb): "\(kb) KB"
        case .megabytes(let mb): "\(mb) MB"
        case .gigabyteTenths(let tenths): "\(tenths / 10).\(tenths % 10) GB"
        }
        return approx ? "about \(text)" : text
    }
}
