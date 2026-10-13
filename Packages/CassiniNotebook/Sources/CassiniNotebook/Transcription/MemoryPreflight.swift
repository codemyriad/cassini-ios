/// The memory check at the start of a job (Android's `Limits.memoryAllows` and `lowMemory`): the speaker analysis reads
/// the whole recording as 16 kHz float samples, so a recording whose samples, with 30 % headroom for the decode, the
/// words and the resampler, do not fit the memory left to Cassini flags the device. It only adds a hint to the
/// processing card; the job runs either way.
public enum MemoryPreflight {
    /// The analysis sample rate.
    public static let sampleRate: Int64 = 16_000

    /// Whether `durationMs` of audio fits in `availableBytes`.
    public static func allows(durationMs: Int64, availableBytes: Int64) -> Bool {
        durationMs * sampleRate / 1000 * 4 * 13 / 10 <= availableBytes
    }

    /// Whether the card says the device is low on memory: the duration is known and does not fit. `availableBytes`
    /// is nil (or 0) when the system does not tell, as on a Mac; that is never low.
    public static func lowMemory(durationMs: Int64, availableBytes: Int64?) -> Bool {
        guard durationMs > 0, let availableBytes, availableBytes > 0 else { return false }
        return !allows(durationMs: durationMs, availableBytes: availableBytes)
    }
}
