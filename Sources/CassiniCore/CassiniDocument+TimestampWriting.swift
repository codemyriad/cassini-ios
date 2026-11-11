import Foundation

extension CassiniDocument {
    /// A producer emits schema-valid timestamps even when a tolerant reader accepted legacy spellings.
    /// Normalize lexical forms instead of formatting Date: preserved sub-millisecond fractions must not be lost.
    static func canonicalTimestamp(_ value: JSON?, requiresUppercaseZ: Bool = false) -> String? {
        guard let raw = value?.string else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!requiresUppercaseZ || text.hasSuffix("Z")), parseInstant(text) != nil else { return nil }
        var result = String(text.prefix(10)) + "T" + String(text.dropFirst(11))
        if result.hasSuffix("z") { result.removeLast(); result.append("Z") }
        return result
    }

    static func canonicalLocalTimestamp(_ value: JSON?) -> String? {
        guard let text = value?.string,
              fullMatch(text, "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"),
              parseInstant(text + "Z") != nil else { return nil }
        return text
    }

    /// Preserve the reader's UTC eligibility before normalizing: promoting an ignored lower-z/offset UTC
    /// would replace a different valid DATE/local fallback. Optional unusable fields are omitted instead.
    static func canonicalizingTimestamps(_ input: JSONObject) throws -> JSONObject {
        var manifest = input
        var meeting = try manifest.object("meeting")
        guard let created = canonicalTimestamp(meeting["createdAtUtc"]), created.hasSuffix("Z") else {
            throw CassiniError("Cannot write invalid createdAtUtc")
        }
        meeting["createdAtUtc"] = .string(created)
        if meeting["recordedAtUtc"] != nil {
            meeting["recordedAtUtc"] = canonicalTimestamp(meeting["recordedAtUtc"], requiresUppercaseZ: true).map(JSON.string)
        }
        if meeting["processedAtUtc"] != nil {
            let processed = canonicalTimestamp(meeting["processedAtUtc"])
            meeting["processedAtUtc"] = processed.flatMap { $0.hasSuffix("Z") ? .string($0) : nil }
        }
        if meeting["recordedAtLocal"] != nil {
            meeting["recordedAtLocal"] = canonicalLocalTimestamp(meeting["recordedAtLocal"]).map(JSON.string)
        }
        manifest["meeting"] = .object(meeting)
        // Descriptor creation dates use date-time without the meeting fields' UTC-only pattern.
        for key in ["transcripts", "readableTranscripts"] {
            guard let entries = manifest[key]?.array else { continue }
            manifest[key] = .array(entries.map { entry in
                guard var object = entry.object, object["createdAtUtc"] != nil else { return entry }
                object["createdAtUtc"] = canonicalTimestamp(object["createdAtUtc"]).map(JSON.string)
                return .object(object)
            })
        }
        return manifest
    }
}
