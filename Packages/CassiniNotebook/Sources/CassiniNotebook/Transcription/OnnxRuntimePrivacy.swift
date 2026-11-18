import Darwin
import Synchronization

/// Shared process-wide ONNX Runtime telemetry opt-out (`ORT_DISABLE_TELEMETRY=1`).
///
/// Both speech engines (`CassiniWhistle` and `CassiniSherpa`) and app startup invoke this before ONNX Runtime can
/// initialize `OrtEnv`, ensuring `ORT_DISABLE_TELEMETRY` is `"1"` even when unset or inherited as `"0"`.
public enum OnnxRuntimePrivacy {
    public static let environmentKey = "ORT_DISABLE_TELEMETRY"
    public static let optOutValue = "1"
    private static let lock = Mutex(())

    /// Sets `ORT_DISABLE_TELEMETRY=1` in the process environment and verifies the resulting value is `"1"`.
    @discardableResult
    public static func ensureTelemetryDisabled() -> Bool {
        lock.withLock { _ in
            guard setenv(environmentKey, optOutValue, 1) == 0,
                  let raw = getenv(environmentKey) else {
                return false
            }
            return String(cString: raw) == optOutValue
        }
    }

    /// Reads the current `ORT_DISABLE_TELEMETRY` value from the process environment.
    public static var currentValue: String? {
        lock.withLock { _ in
            getenv(environmentKey).map { String(cString: $0) }
        }
    }

    public static var isTelemetryDisabled: Bool {
        currentValue == optOutValue
    }
}
