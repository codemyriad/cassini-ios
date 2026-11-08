import CryptoKit
import Darwin
import Foundation

/// One owner of Needle's process-global model. This low-level, bounded raw-segment API is not the production
/// recording/VAD adapter. No app launch loads this framework, and rollout remains gated by WhistleCapability.
public actor WhistleRuntime {
    public static let shared = WhistleRuntime()
    public static let engineRevision = "93e88ede867e4311c39151285e74df513e4b835b"
    public static let modelSHA256 = "b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb"
    private typealias Load = @convention(c) (UnsafePointer<UInt8>?, UInt64) -> Int32
    private typealias Models = @convention(c) () -> Int32
    private typealias Decode = @convention(c) (UnsafePointer<Float>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?, Int32) -> Int32
    private var handle: UnsafeMutableRawPointer?
    private var decode: Decode?
    private var model: UnsafeMutableBufferPointer<UInt8>?
    private init() {}

    private struct Manifest: Decodable {
        var engineRevision: String
        var modelSha256: String
        var runtimeSha256: String
        var target: String
        var minimumOS: String
        var sourceArchiveMinimumOS: String
    }

    private func privacyEnvironment() throws -> [String: String] {
        var environment: [String: String] = [:]
        for (key, value) in WhistlePrivacy.required {
            guard setenv(key, value, 1) == 0, let raw = getenv(key) else { throw WhistleError.privacy }
            environment[key] = String(cString: raw)
        }
        return environment
    }

    private func open(bundle: Bundle) throws {
        guard handle == nil else { return }
        #if os(iOS) && arch(arm64)
        #if targetEnvironment(simulator)
        let target = "ios-sim-arm64"
        #else
        let target = "ios-arm64"
        #endif
        #else
        throw WhistleError.unavailable
        #endif
        #if os(iOS) && arch(arm64)
        guard let resources = bundle.resourceURL, let frameworks = bundle.privateFrameworksURL else { throw WhistleError.unavailable }
        let root = resources.appendingPathComponent("Whistle", isDirectory: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.engineRevision == Self.engineRevision, manifest.modelSha256 == Self.modelSHA256,
              manifest.target == target, manifest.minimumOS == "26.0", manifest.sourceArchiveMinimumOS == "27.0" else {
            throw WhistleError.integrity
        }
        let binary = frameworks.appendingPathComponent("CassiniWhistleRuntime.framework/CassiniWhistleRuntime")
        let weights = try Data(contentsOf: root.appendingPathComponent("whistle.cact"), options: .mappedIfSafe)
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        guard weights.count == 16_919_407, hash(weights) == Self.modelSHA256,
              hash(try Data(contentsOf: binary, options: .mappedIfSafe)) == manifest.runtimeSha256 else { throw WhistleError.integrity }
        // This is the first operation that can execute engine constructors. Flags and both pins precede it.
        let loaded = try WhistlePrivacy.enter(environment: privacyEnvironment()) {
            guard let loaded = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else { throw WhistleError.unavailable }
            return loaded
        }
        // withUnsafeBytes only promises a pointer during its closure. Needle borrows beyond needle_load, so use
        // explicitly owned storage rather than retaining Data and relying on an incidental backing pointer.
        let bytes = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: weights.count)
        _ = weights.copyBytes(to: bytes)
        do {
            guard let loadSymbol = dlsym(loaded, "needle_load"), let decodeSymbol = dlsym(loaded, "needle_transcribe"),
                  let modelsSymbol = dlsym(loaded, "needle_models") else {
                throw WhistleError.missingAPI
            }
            let models = unsafeBitCast(modelsSymbol, to: Models.self)
            // Also fail closed if another image already owns this process-global native runtime.
            guard models() == 0 else { throw WhistleError.nativeFailure }
            let load = unsafeBitCast(loadSymbol, to: Load.self)
            guard load(bytes.baseAddress, UInt64(bytes.count)) >= 0, models() & 2 == 2 else {
                throw WhistleError.nativeFailure
            }
            model = bytes // Borrowed by the C API for the entire loaded lifetime.
            decode = unsafeBitCast(decodeSymbol, to: Decode.self)
            handle = loaded
        } catch {
            dlclose(loaded)
            bytes.deallocate()
            throw error
        }
        #endif
    }

    /// Actual C API, automatic language detection, no keywords; callers supply already segmented raw 16kHz PCM.
    /// Cancellation discards a late synchronous result. The serial actor cannot overlap model ownership/calls.
    public func transcribe(_ pcm: [Float], acceptance: WhistleCapability, bundle: Bundle = .main) throws -> WhistleResult {
        guard acceptance.available else { throw WhistleError.unavailable }
        try Task.checkCancellation()
        guard !pcm.isEmpty, pcm.count <= 16_000 * 15, pcm.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            throw WhistleError.invalidInput
        }
        try open(bundle: bundle)
        guard let decode else { throw WhistleError.missingAPI }
        let result = try WhistlePrivacy.enter(environment: privacyEnvironment()) {
            var output = [CChar](repeating: 0, count: 1_048_576)
            let count = pcm.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer {
                    decode(input.baseAddress, Int32(input.count), nil, nil, 1, $0.baseAddress, Int32($0.count))
                }
            }
            guard count >= 0 else { throw WhistleError.nativeFailure }
            guard let end = output.firstIndex(of: 0) else { throw WhistleError.invalidOutput }
            return try output.withUnsafeBufferPointer {
                try WhistleResult.parse(Data(bytes: $0.baseAddress!, count: end), samples: pcm.count)
            }
        }
        try Task.checkCancellation()
        return result
    }

    public func close() {
        decode = nil
        if let handle { dlclose(handle) }
        handle = nil
        model?.deallocate()
        model = nil // Released only after native destructors can no longer refer to it.
    }
}
