import Foundation
import CassiniNotebook

extension RunDevice {
    /// This device: its hardware model identifier ("iPhone17,1"; a simulator says so) and its OS with the build
    /// ("iOS 26.0.1 (23A355)").
    @Sendable public static func current() -> RunDevice {
        let environment = ProcessInfo.processInfo.environment
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
        #if os(iOS)
        let name = "iOS", hardware = "hw.machine"
        #elseif os(macOS)
        let name = "macOS", hardware = "hw.model"
        #else
        let name = "unknown OS", hardware = "hw.machine"
        #endif
        var model = sysctl(hardware) ?? "unknown device"
        var build = sysctl("kern.osversion")
        if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"] {
            model = "\(simulated) Simulator"
            build = environment["SIMULATOR_RUNTIME_BUILD_VERSION"] ?? build
        }
        return RunDevice(model: model, system: build.map { "\(name) \(number) (\($0))" } ?? "\(name) \(number)")
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
