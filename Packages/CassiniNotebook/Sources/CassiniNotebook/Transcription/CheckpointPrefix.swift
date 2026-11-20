import Foundation

/// Whether a checkpoint was produced by recording-time precomputation or post-Stop batch transcription.
/// Legacy checkpoints omit `origin`, which defaults to `.batch`.
public enum CheckpointOrigin: String, Codable, Hashable, Sendable {
    case batch
    case precompute
}

/// Committed-prefix descriptor carried by mobile recording-time precompute checkpoints (`D-1117`, `D109`).
public struct CommittedPrefix: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case cafPcm16LeFrames
        case oggOpusCommittedBytes
    }

    /// Right half-width of `cassini-fir-48k-16k-v1` (97-tap symmetric FIR, decimation factor 3).
    public static let cafFirLookaheadFrames = 48

    public var kind: Kind
    /// Source `.caf` PCM16LE sample rate in Hz (required positive integer for `.cafPcm16LeFrames`; omitted for Ogg Opus).
    public var sourceSampleRateHz: Int?
    /// Exact number of committed source units `[0 ..< committedUnitCount)`:
    /// - `.cafPcm16LeFrames`: CAF source-rate PCM16LE frames consumed including resampler right-halo.
    /// - `.oggOpusCommittedBytes`: committed non-EOS Ogg Opus file bytes.
    public var committedUnitCount: UInt64
    /// Lowercase 64-character hex SHA-256 over the committed prefix bytes.
    public var prefixSha256: String
    /// Optional lowercase 64-character hex SHA-256 of the decoded 16 kHz mono PCM prefix.
    public var decodedPcmSha256: String?

    public init(
        kind: Kind,
        sourceSampleRateHz: Int? = nil,
        committedUnitCount: UInt64,
        prefixSha256: String,
        decodedPcmSha256: String? = nil
    ) {
        self.kind = kind
        self.sourceSampleRateHz = sourceSampleRateHz
        self.committedUnitCount = committedUnitCount
        self.prefixSha256 = prefixSha256
        self.decodedPcmSha256 = decodedPcmSha256
    }

    /// Minimum CAF source-rate frames `[0 ..< N)` required to produce `consumed16kSamples` at 16 kHz
    /// with `resamplerLookaheadFrames` of right-halo lookahead.
    public static func minRequiredCafSourceFrames(
        consumed16kSamples: UInt64,
        sourceSampleRateHz: Int,
        resamplerLookaheadFrames: Int = 0
    ) -> UInt64 {
        guard consumed16kSamples > 0, sourceSampleRateHz > 0, resamplerLookaheadFrames >= 0 else { return 0 }
        return ((consumed16kSamples - 1) * UInt64(sourceSampleRateHz) + 15_999) / 16_000
            + UInt64(resamplerLookaheadFrames) + 1
    }

    /// True iff `value` is a 64-character lowercase hexadecimal SHA-256 string.
    public static func isValidHex64(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66)
        }
    }

    /// Structural validity of the descriptor fields alone (independent of finalized file state).
    public var isValidDescriptor: Bool {
        guard committedUnitCount > 0, Self.isValidHex64(prefixSha256) else { return false }
        if let decodedPcmSha256, !Self.isValidHex64(decodedPcmSha256) { return false }
        if kind == .cafPcm16LeFrames {
            guard let rate = sourceSampleRateHz, rate > 0 else { return false }
        }
        return true
    }
}

extension CheckpointState {
    /// On-disk byte lengths of sidecar work files referenced by a checkpoint.
    public struct WorkFileBytes: Hashable, Sendable {
        public var clipsBytes: Int64?
        public var wordLogBytes: Int64?
        public var audioBytes: Int64?

        public init(clipsBytes: Int64? = nil, wordLogBytes: Int64? = nil, audioBytes: Int64? = nil) {
            self.clipsBytes = clipsBytes
            self.wordLogBytes = wordLogBytes
            self.audioBytes = audioBytes
        }
    }

    /// Finalized audio file properties used to validate a `CommittedPrefix` when whole-file `signature` differs.
    public struct PrefixExpectation: Hashable, Sendable {
        public var prefixKind: CommittedPrefix.Kind
        public var sourceSampleRateHz: Int?
        public var resamplerLookaheadFrames: Int
        public var finalizedUnitCount: UInt64
        public var prefixSha256: String
        public var decodedPcmSha256: String?
        public var workFiles: WorkFileBytes

        public init(
            prefixKind: CommittedPrefix.Kind,
            sourceSampleRateHz: Int? = nil,
            resamplerLookaheadFrames: Int = 0,
            finalizedUnitCount: UInt64,
            prefixSha256: String,
            decodedPcmSha256: String? = nil,
            workFiles: WorkFileBytes = WorkFileBytes()
        ) {
            self.prefixKind = prefixKind
            self.sourceSampleRateHz = sourceSampleRateHz
            self.resamplerLookaheadFrames = resamplerLookaheadFrames
            self.finalizedUnitCount = finalizedUnitCount
            self.prefixSha256 = prefixSha256
            self.decodedPcmSha256 = decodedPcmSha256
            self.workFiles = workFiles
        }
    }
}

/// Pure rule engine implementing `contract/HEAD-START-TRANSCRIPTION.md` §5.2 for mobile committed-prefix
/// checkpoint validation and silent precompute fallback (backed by `mobile-prefix-checkpoint-vectors.json`).
public enum MobileCheckpointValidator {
    public static let defaultMaxTranscribeMs: Int64 = 12 * 3_600 * 1_000

    public enum Decision: String, Equatable, Sendable {
        case resume
        case discardAndFullDecode
        case rejectBatchCheckpoint
    }

    public enum MatchMode: String, Equatable, Sendable {
        case wholeFile
        case committedPrefix
    }

    public struct Outcome: Equatable, Sendable {
        public let decision: Decision
        public let matchMode: MatchMode?
        public let reason: String?
        public let failUserJob: Bool

        public init(decision: Decision, matchMode: MatchMode?, reason: String?, failUserJob: Bool) {
            self.decision = decision
            self.matchMode = matchMode
            self.reason = reason
            self.failUserJob = failUserJob
        }
    }

    /// Validates raw JSON checkpoint and expected-file dictionaries strictly per `HEAD-START-TRANSCRIPTION.md` §5.2.
    public static func validate(checkpoint: [String: Any], expected: [String: Any]) -> Outcome {
        let originRaw = checkpoint["origin"] as? String
        let origin: CheckpointOrigin = originRaw == "precompute" ? .precompute : .batch

        func fail(_ reason: String) -> Outcome {
            let decision: Decision = origin == .precompute ? .discardAndFullDecode : .rejectBatchCheckpoint
            return Outcome(
                decision: decision,
                matchMode: nil,
                reason: reason,
                failUserJob: decision == .rejectBatchCheckpoint
            )
        }

        if exactInt(checkpoint["version"]) != exactInt(expected["version"]) {
            return fail("versionMismatch")
        }
        if (checkpoint["source"] as? String) != (expected["source"] as? String) {
            return fail("sourceMismatch")
        }
        if (checkpoint["model"] as? String) != (expected["model"] as? String) {
            return fail("modelMismatch")
        }
        if (checkpoint["speakers"] as? String) != (expected["speakers"] as? String) {
            return fail("speakersMismatch")
        }

        let maxMs = exactInt(expected["maxTranscribeMs"]) ?? defaultMaxTranscribeMs
        let samplesPerMs: Int64 = 16
        let matchMode: MatchMode

        if let cpSig = checkpoint["signature"] as? String,
           let expSig = expected["signature"] as? String,
           cpSig == expSig {
            matchMode = .wholeFile
        } else {
            guard let prefix = checkpoint["committedPrefix"] as? [String: Any] else {
                return fail("signatureMismatch")
            }
            guard let kindStr = prefix["kind"] as? String,
                  let kind = CommittedPrefix.Kind(rawValue: kindStr),
                  let unitCount = exactInt(prefix["committedUnitCount"]),
                  unitCount > 0,
                  let prefixSha = prefix["prefixSha256"] as? String,
                  CommittedPrefix.isValidHex64(prefixSha) else {
                return fail("invalidPrefixDescriptor")
            }
            let decodedShaAny = prefix["decodedPcmSha256"]
            var decodedSha: String?
            if let value = decodedShaAny, !(value is NSNull) {
                guard let str = value as? String, CommittedPrefix.isValidHex64(str) else {
                    return fail("invalidPrefixDescriptor")
                }
                decodedSha = str
            }
            guard let expectedKindStr = expected["prefixKind"] as? String,
                  expectedKindStr == kindStr else {
                return fail("prefixKindMismatch")
            }
            if kind == .cafPcm16LeFrames {
                guard let prefixRate = exactInt(prefix["sourceSampleRateHz"]), prefixRate > 0 else {
                    return fail("invalidPrefixDescriptor")
                }
                guard let expectedRate = exactInt(expected["sourceSampleRateHz"]),
                      expectedRate > 0,
                      prefixRate == expectedRate else {
                    return fail("sourceSampleRateMismatch")
                }
                let expectedLookahead: Int64
                if let rawLookahead = expected["resamplerLookaheadFrames"], !(rawLookahead is NSNull) {
                    guard let parsed = exactInt(rawLookahead), parsed >= 0 else {
                        return fail("invalidPrefixDescriptor")
                    }
                    expectedLookahead = parsed
                } else {
                    expectedLookahead = 0
                }
                guard let doneMsCheck = exactInt(checkpoint["doneMs"]),
                      doneMsCheck >= 0, doneMsCheck <= maxMs else {
                    return fail("invalidCounters")
                }
                var recSamplesCheck: Int64?
                if let rawRec = checkpoint["recognitionSampleCount"], !(rawRec is NSNull) {
                    guard let parsed = exactInt(rawRec),
                          parsed >= doneMsCheck * samplesPerMs,
                          parsed <= maxMs * samplesPerMs else {
                        return fail("invalidCounters")
                    }
                    recSamplesCheck = parsed
                }
                let consumed16k = max(doneMsCheck * samplesPerMs, recSamplesCheck ?? 0)
                let minRequired = CommittedPrefix.minRequiredCafSourceFrames(
                    consumed16kSamples: UInt64(consumed16k),
                    sourceSampleRateHz: Int(prefixRate),
                    resamplerLookaheadFrames: Int(expectedLookahead)
                )
                if UInt64(unitCount) < minRequired {
                    return fail("prefixCoverageInsufficient")
                }
            }
            guard let finalizedUnits = exactInt(expected["finalizedUnitCount"]),
                  finalizedUnits >= unitCount else {
                return fail("prefixTruncated")
            }
            guard (expected["prefixSha256"] as? String) == prefixSha else {
                return fail("prefixDigestMismatch")
            }
            if let decodedSha, (expected["decodedPcmSha256"] as? String) != decodedSha {
                return fail("decodedPrefixMismatch")
            }
            matchMode = .committedPrefix
        }

        guard let doneMs = exactInt(checkpoint["doneMs"]),
              let totalMs = (checkpoint["totalMs"] == nil || checkpoint["totalMs"] is NSNull) ? 0 : exactInt(checkpoint["totalMs"]),
              let resumedFromMs = (checkpoint["resumedFromMs"] == nil || checkpoint["resumedFromMs"] is NSNull) ? 0 : exactInt(checkpoint["resumedFromMs"]),
              doneMs >= 0, doneMs <= maxMs,
              totalMs >= 0, totalMs <= maxMs,
              (totalMs == 0 || doneMs <= totalMs),
              resumedFromMs >= 0, resumedFromMs <= doneMs else {
            return fail("invalidCounters")
        }
        if let rawRec = checkpoint["recognitionSampleCount"], !(rawRec is NSNull) {
            guard let recSamples = exactInt(rawRec),
                  recSamples >= doneMs * samplesPerMs,
                  recSamples <= maxMs * samplesPerMs else {
                return fail("invalidCounters")
            }
        }

        let reqFiles = checkpoint["workFiles"] as? [String: Any] ?? [:]
        let actualFiles = expected["workFiles"] as? [String: Any] ?? [:]
        for key in ["clipsBytes", "wordLogBytes", "audioBytes"] {
            if let rawNeed = reqFiles[key] {
                guard let need = exactInt(rawNeed), need >= 0,
                      let have = exactInt(actualFiles[key]), have >= need else {
                    return fail("workFileTruncated")
                }
            }
        }

        return Outcome(decision: .resume, matchMode: matchMode, reason: nil, failUserJob: false)
    }

    /// Accepts only exact JSON integers (rejects booleans and non-integer floating-point numbers).
    private static func exactInt(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        if CFNumberIsFloatType(number) { return nil }
        return number.int64Value
    }
}
