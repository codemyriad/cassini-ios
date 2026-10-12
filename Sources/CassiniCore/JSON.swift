import Foundation

/** A failed format check. Readers turn these into document states; they are never shown raw to people. */
public struct CassiniError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

@inline(__always) func check(_ condition: Bool, _ message: @autoclosure () -> String = "Malformed Cassini data") throws {
    if !condition { throw CassiniError(message()) }
}

func fullMatch(_ text: String, _ pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else { return false }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

/** Format strings compare by their UTF-8 bytes; Swift's `==` would equate canonically equivalent spellings. */
func sameBytes(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return a.utf8.elementsEqual(b.utf8)
    default: return false
    }
}

/** Whether [text] starts with the UTF-8 bytes of [prefix]; `hasPrefix` would accept a canonically equivalent start. */
func hasBytePrefix(_ text: String, _ prefix: String) -> Bool { text.utf8.starts(with: prefix.utf8) }

/** Tag names fold ASCII case only; `uppercased()` would also turn letters such as "ſ" into "S". */
func asciiUppercased<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    String(decoding: bytes.map { (0x61...0x7A).contains($0) ? $0 - 0x20 : $0 }, as: UTF8.self)
}

func asciiUppercased(_ text: String) -> String { asciiUppercased(text.utf8) }

/** Strict UTF-8: no repair, and unlike Foundation's decoder a leading BOM is kept. */
func utf8(_ bytes: [UInt8]) throws -> String {
    var iterator = bytes.makeIterator()
    var decoder = Unicode.UTF8()
    var scalars = String.UnicodeScalarView()
    while true {
        switch decoder.decode(&iterator) {
        case .scalarValue(let scalar): scalars.append(scalar)
        case .emptyInput: return String(scalars)
        case .error: throw CassiniError("Invalid UTF-8")
        }
    }
}

/**
 * JSON that keeps member order and number lexemes, so unknown members survive a rewrite.
 * Equality is structural and order-insensitive, as the Android reader's `same`.
 */
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    public static func int<T: BinaryInteger>(_ value: T) -> JSON { .number(String(value)) }
    public var object: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    /** What org.json's `toString()` gives for a scalar, used to compare tags with manifest values. */
    var text: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return s
        default: return serialized()
        }
    }

    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y || Double(x) == Double(y)
        case (.string(let x), .string(let y)): return sameBytes(x, y)
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)): return x == y
        default: return false
        }
    }

    public func serialized(indent: Int? = nil) -> String {
        var out = ""
        write(&out, indent: indent, level: 0)
        return out
    }

    private func write(_ out: inout String, indent: Int?, level: Int) {
        func newline(_ depth: Int) {
            if let indent = indent { out += "\n" + String(repeating: " ", count: indent * depth) }
        }
        switch self {
        case .null, .bool, .number: out += text
        case .string(let s): JSON.quote(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                newline(level + 1); item.write(&out, indent: indent, level: level + 1)
            }
            if !items.isEmpty { newline(level) }
            out += "]"
        case .object(let object):
            out += "{"
            for (i, pair) in object.pairs.enumerated() {
                if i > 0 { out += "," }
                newline(level + 1); JSON.quote(pair.key, into: &out); out += indent == nil ? ":" : ": "
                pair.value.write(&out, indent: indent, level: level + 1)
            }
            if !object.pairs.isEmpty { newline(level) }
            out += "}"
        }
    }

    private static func quote(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
    }

    /**
     * The strict payload boundary: one top-level object, no duplicate keys at any depth,
     * no lenient tokens, depth at most 64, nothing after the value.
     */
    public static func parseObject(_ text: String) throws -> JSONObject {
        var parser = Parser(bytes: Array(text.utf8))
        let value = try parser.value(depth: 0)
        parser.space()
        try check(parser.p == parser.bytes.count, "Trailing JSON data")
        guard case .object(let object) = value else { throw CassiniError("JSON payload is not an object") }
        return object
    }

    private struct Parser {
        let bytes: [UInt8]
        var p = 0
        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func space() { while p < bytes.count, [0x20, 0x0D, 0x0A, 0x09].contains(bytes[p]) { p += 1 } }
        mutating func take(_ c: UInt8) -> Bool {
            space()
            if p < bytes.count && bytes[p] == c { p += 1; return true }
            return false
        }
        mutating func hex4() throws -> UInt32 {
            try check(p + 4 <= bytes.count, "Invalid JSON escape")
            guard let s = String(bytes: bytes[p..<p + 4], encoding: .ascii), fullMatch(s, "[0-9a-fA-F]{4}"),
                  let v = UInt32(s, radix: 16) else { throw CassiniError("Invalid JSON escape") }
            p += 4
            return v
        }
        mutating func string() throws -> String {
            space()
            try check(p < bytes.count && bytes[p] == 0x22, "Expected JSON string")
            p += 1
            var raw: [UInt8] = []
            var out = ""
            func flush() throws { if !raw.isEmpty { out += try utf8(raw); raw.removeAll() } }
            while p < bytes.count {
                let c = bytes[p]; p += 1
                try check(c >= 32, "Control character in JSON string")
                if c == 0x22 { try flush(); return out }
                if c != 0x5C { raw.append(c); continue }
                try check(p < bytes.count, "Invalid JSON escape")
                let e = bytes[p]; p += 1
                switch e {
                case 0x22: raw.append(0x22)
                case 0x5C: raw.append(0x5C)
                case 0x2F: raw.append(0x2F)
                case 0x62: raw.append(0x08)
                case 0x66: raw.append(0x0C)
                case 0x6E: raw.append(0x0A)
                case 0x72: raw.append(0x0D)
                case 0x74: raw.append(0x09)
                case 0x75:
                    var v = try hex4()
                    if (0xD800...0xDBFF).contains(v) {
                        // Swift strings cannot hold a lone surrogate, so only whole pairs are accepted.
                        try check(p + 2 <= bytes.count && bytes[p] == 0x5C && bytes[p + 1] == 0x75, "Lone surrogate in JSON string")
                        p += 2
                        let low = try hex4()
                        try check((0xDC00...0xDFFF).contains(low), "Lone surrogate in JSON string")
                        v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(v) else { throw CassiniError("Lone surrogate in JSON string") }
                    try flush(); out.unicodeScalars.append(scalar)
                default: throw CassiniError("Invalid JSON escape")
                }
            }
            throw CassiniError("Unterminated JSON string")
        }
        mutating func value(depth: Int) throws -> JSON {
            try check(depth <= 64, "JSON nested too deeply")
            space()
            try check(p < bytes.count, "Unexpected end of JSON")
            switch bytes[p] {
            case 0x7B:
                p += 1
                var object = JSONObject()
                if take(0x7D) { return .object(object) }
                repeat {
                    let key = try string()
                    try check(!object.has(key), "Duplicate JSON key")
                    try check(take(0x3A), "Expected ':'")
                    object[key] = try value(depth: depth + 1)
                } while take(0x2C)
                try check(take(0x7D), "Expected '}'")
                return .object(object)
            case 0x5B:
                p += 1
                var items: [JSON] = []
                if take(0x5D) { return .array(items) }
                repeat { items.append(try value(depth: depth + 1)) } while take(0x2C)
                try check(take(0x5D), "Expected ']'")
                return .array(items)
            case 0x22:
                return .string(try string())
            default:
                let start = p
                while p < bytes.count, ![0x20, 0x0D, 0x0A, 0x09, 0x2C, 0x5D, 0x7D, 0x3A].contains(bytes[p]) { p += 1 }
                let token = String(decoding: bytes[start..<p], as: UTF8.self)
                switch token {
                case "null": return .null
                case "true": return .bool(true)
                case "false": return .bool(false)
                default:
                    try check(fullMatch(token, "-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?"), "Invalid JSON token")
                    return .number(token)
                }
            }
        }
    }
}

/** An ordered JSON object with byte-exact keys. Assigning an existing key replaces it in place; nil removes it. */
public struct JSONObject: Equatable, Sendable {
    public private(set) var pairs: [(key: String, value: JSON)] = []
    public init() {}
    public init(_ pairs: [(String, JSON)]) { for (k, v) in pairs { self[k] = v } }
    public var keys: [String] { pairs.map { $0.key } }
    public func has(_ key: String) -> Bool { pairs.contains { sameBytes($0.key, key) } }
    /** Whether the keys are exactly [expected], compared byte for byte. */
    func hasExactly(_ expected: Set<String>) -> Bool {
        pairs.count == expected.count && pairs.allSatisfy { pair in expected.contains { sameBytes($0, pair.key) } }
    }
    public subscript(key: String) -> JSON? {
        get { pairs.first { sameBytes($0.key, key) }?.value }
        set {
            let index = pairs.firstIndex { sameBytes($0.key, key) }
            switch (index, newValue) {
            case (let i?, let v?): pairs[i].value = v
            case (let i?, nil): pairs.remove(at: i)
            case (nil, let v?): pairs.append((key, v))
            case (nil, nil): break
            }
        }
    }
    public func object(_ key: String) throws -> JSONObject {
        guard let o = self[key]?.object else { throw CassiniError("Expected object \(key)") }
        return o
    }
    public func array(_ key: String) throws -> [JSON] {
        guard let a = self[key]?.array else { throw CassiniError("Expected array \(key)") }
        return a
    }
    public func string(_ key: String) throws -> String {
        guard let s = self[key]?.string else { throw CassiniError("Expected string \(key)") }
        return s
    }
    /** A non-negative integer no larger than 2^53 - 1, however it is spelled. */
    public func number(_ key: String) throws -> Int64 {
        guard case .number(let lexeme)? = self[key], let n = Double(lexeme) else { throw CassiniError("Expected number \(key)") }
        try check(n.isFinite && n >= 0 && n <= 9007199254740991.0 && n.rounded(.towardZero) == n, "Invalid number \(key)")
        return Int64(n)
    }
    public func serialized(indent: Int? = nil) -> String { JSON.object(self).serialized(indent: indent) }

    /** Keys are unique, so equal counts and every member of [a] found in [b] means the same members. */
    public static func == (a: JSONObject, b: JSONObject) -> Bool {
        a.pairs.count == b.pairs.count && a.pairs.allSatisfy { b[$0.key] == $0.value }
    }
}
