import Foundation
import CassiniNotebook

/// The pinned shared policy is the sole source of offered audio types. Header reads are bounded and happen inside
/// the coordinated/security-scoped accessor, before a destination file is created.
public enum ImportPolicy {
    public struct Entry: Decodable, Sendable {
        public let id: String
        public let status: String
        public let extensions: [String]
        public let utis: [String]
        let contentValidation: Validation?
    }
    struct Validation: Decodable, Sendable {
        let minProbeBytes: Int
        let containerMagicHex: String
        let acceptedBosMagicHex: [String]
        let secondPageMagicHex: String
        let rejectedBosMagicHex: [String]
    }
    private struct Contract: Decodable { let types: [Entry] }
    public static let entries: [Entry] = {
        // A missing or invalid bundled contract is a build defect, never a reason to offer broad audio types.
        let url = Bundle.module.url(forResource: "import-types", withExtension: "json")!
        return try! JSONDecoder().decode(Contract.self, from: Data(contentsOf: url)).types.filter { $0.status == "decided" }
    }()
    public static var utis: [String] { entries.flatMap(\.utis) }
    public static func accepts(filename: String) -> Bool {
        let ext = "." + (filename as NSString).pathExtension.lowercased()
        return entries.contains { $0.extensions.contains(ext) }
    }
    public static let probeBytes = entries.compactMap(\.contentValidation?.minProbeBytes).max()!

    public static func validate(header: Data, filename: String, fileBytes: Int64?) throws {
        guard accepts(filename: filename), !header.starts(with: Data("fLaC".utf8)) else { throw FileImportError.cannotOpen }
        let bytes = [UInt8](header)
        // A decided filename must not admit a recognized non-contract container such as raw ADTS, CAF or AIFF.
        if case .other(let container?) = ImportClassifier.sniff(bytes), !accepts(filename: "source." + container) {
            throw FileImportError.cannotOpen
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "opus" || ext == "ogg" || header.starts(with: Data("OggS".utf8)) {
            guard validOpus(bytes) else { throw FileImportError.cannotOpen }
        }
        if ext == "wav" {
            let h = bytes
            guard h.count >= 44, h.starts(with: Array("RIFF".utf8)), Array(h[8..<12]) == Array("WAVE".utf8) else {
                throw FileImportError.cannotOpen
            }
            let declared = UInt64(h[4]) | UInt64(h[5]) << 8 | UInt64(h[6]) << 16 | UInt64(h[7]) << 24
            if let fileBytes, declared + 8 > UInt64(max(0, fileBytes)) { throw FileImportError.cannotOpen }
        }
    }

    private static func hex(_ value: String) -> [UInt8] {
        stride(from: 0, to: value.count, by: 2).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    static func validOpus(_ h: [UInt8]) -> Bool {
        let rules = entries.first { $0.id == "opus-ogg" }!.contentValidation!
        let magic = hex(rules.containerMagicHex)
        guard h.count >= 28, h.starts(with: magic), h[4] == 0, h[5] == 2 else { return false }
        let end = 27 + Int(h[26])
        guard end <= h.count, h[26] > 0 else { return false }
        let payloadEnd = end + h[27..<end].reduce(0) { $0 + Int($1) }
        guard payloadEnd <= h.count, payloadEnd >= end + 19 else { return false }
        let payload = h[end..<payloadEnd]
        guard !rules.rejectedBosMagicHex.contains(where: { payload.starts(with: hex($0)) }),
              rules.acceptedBosMagicHex.contains(where: { payload.starts(with: hex($0)) }),
              h[end + 8] & 0xf0 == 0,
              h.count >= payloadEnd + 28,
              h[payloadEnd...].starts(with: magic), h[payloadEnd + 4] == 0,
              h[payloadEnd + 5] & 3 == 0 else { return false }
        // Same logical stream, next page: another BOS (including video) never passes.
        guard Array(h[14..<18]) == Array(h[(payloadEnd + 14)..<(payloadEnd + 18)]) else { return false }
        let tags = payloadEnd + 27 + Int(h[payloadEnd + 26])
        let tagMagic = hex(rules.secondPageMagicHex)
        guard tags + tagMagic.count <= h.count else { return false }
        return h[tags...].starts(with: tagMagic)
    }
}
