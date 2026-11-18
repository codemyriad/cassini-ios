import Darwin
import Testing
@testable import CassiniNotebook

@Suite(.serialized)
struct OnnxRuntimePrivacyTests {
    @Test func ensureTelemetryDisabledCoversMissingAndInheritedZero() {
        defer { OnnxRuntimePrivacy.ensureTelemetryDisabled() }

        unsetenv(OnnxRuntimePrivacy.environmentKey)
        #expect(OnnxRuntimePrivacy.currentValue == nil)
        #expect(!OnnxRuntimePrivacy.isTelemetryDisabled)
        #expect(OnnxRuntimePrivacy.ensureTelemetryDisabled())
        #expect(OnnxRuntimePrivacy.currentValue == "1")
        #expect(OnnxRuntimePrivacy.isTelemetryDisabled)

        setenv(OnnxRuntimePrivacy.environmentKey, "0", 1)
        #expect(OnnxRuntimePrivacy.currentValue == "0")
        #expect(!OnnxRuntimePrivacy.isTelemetryDisabled)
        #expect(OnnxRuntimePrivacy.ensureTelemetryDisabled())
        #expect(OnnxRuntimePrivacy.currentValue == "1")
        #expect(OnnxRuntimePrivacy.isTelemetryDisabled)
    }
}
