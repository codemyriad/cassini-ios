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
    private var binaryPath: String?
    private var loadFailed = false
    private init() {}

    private struct Manifest: Decodable {
        var engineRevision: String
        var modelSha256: String
        var runtimeIdentity: String
        var identitySchema: String
        var target: String
        var minimumOS: String
        var sourceArchiveMinimumOS: String
    }

    /// Read-only admission check; this never dlopens the runtime or constructs an inference session.
    public static func bundleIsVerified(_ bundle: Bundle = .main) -> Bool {
        #if os(iOS) && arch(arm64)
        #if targetEnvironment(simulator)
        let target = "ios-sim-arm64"
        #else
        let target = "ios-arm64"
        #endif
        do {
            guard let resources = bundle.resourceURL, let frameworks = bundle.privateFrameworksURL else { return false }
            let root = resources.appendingPathComponent("Whistle")
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
            guard manifest.engineRevision == engineRevision, manifest.modelSha256 == modelSHA256,
                  manifest.target == target, manifest.identitySchema == "cassini-whistle-sections-v1",
                  manifest.minimumOS == "26.0", manifest.sourceArchiveMinimumOS == "27.0" else { return false }
            func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
            let weights = try Data(contentsOf: root.appendingPathComponent("whistle.cact"), options: .mappedIfSafe)
            let vad = try Data(contentsOf: root.appendingPathComponent("silero-vad-6.2.1.onnx"), options: .mappedIfSafe)
            let binary = frameworks.appendingPathComponent("CassiniWhistleRuntime.framework/CassiniWhistleRuntime")
            let actualIdentity = try WhistleBinaryIdentity.digest(Data(contentsOf: binary, options: .mappedIfSafe))
            return weights.count == 16_919_407 && hash(weights) == modelSHA256
                && vad.count == 2_327_524 && hash(vad) == WhistleVAD.modelSHA256
                && actualIdentity == manifest.runtimeIdentity
        } catch { return false }
        #else
        return false
        #endif
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
        guard !loadFailed else { throw WhistleError.nativeFailure }
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
              manifest.identitySchema == "cassini-whistle-sections-v1", manifest.target == target, manifest.minimumOS == "26.0", manifest.sourceArchiveMinimumOS == "27.0" else {
            throw WhistleError.integrity
        }
        let binary = frameworks.appendingPathComponent("CassiniWhistleRuntime.framework/CassiniWhistleRuntime")
        let weights = try Data(contentsOf: root.appendingPathComponent("whistle.cact"), options: .mappedIfSafe)
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        guard weights.count == 16_919_407, hash(weights) == Self.modelSHA256,
              try WhistleBinaryIdentity.digest(Data(contentsOf: binary, options: .mappedIfSafe)) == manifest.runtimeIdentity else { throw WhistleError.integrity }
        // This is the first operation that can execute engine constructors. Flags and both pins precede it.
        let loaded = try WhistlePrivacy.enter(environment: privacyEnvironment()) {
            guard let loaded = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else { throw WhistleError.unavailable }
            return loaded
        }
        // withUnsafeBytes only promises a pointer during its closure. Needle borrows beyond needle_load, so use
        // explicitly owned storage rather than retaining Data and relying on an incidental backing pointer.
        let bytes = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: weights.count)
        _ = weights.copyBytes(to: bytes)
        var loadAttempted = false
        do {
            guard let loadSymbol = dlsym(loaded, "needle_load"), let decodeSymbol = dlsym(loaded, "needle_transcribe"),
                  let modelsSymbol = dlsym(loaded, "needle_models") else {
                throw WhistleError.missingAPI
            }
            let models = unsafeBitCast(modelsSymbol, to: Models.self)
            // Also fail closed if another image already owns this process-global native runtime.
            guard models() == 0 else { throw WhistleError.nativeFailure }
            let load = unsafeBitCast(loadSymbol, to: Load.self)
            loadAttempted = true
            guard load(bytes.baseAddress, UInt64(bytes.count)) >= 0, models() & 2 == 2 else {
                throw WhistleError.nativeFailure
            }
            model = bytes // Borrowed by the C API for the entire loaded lifetime.
            decode = unsafeBitCast(decodeSymbol, to: Decode.self)
            handle = loaded
            binaryPath = binary.path
        } catch {
            if loadAttempted {
                // A failed native load can leave a partially constructed global model borrowing the bytes.
                // The API has no partial-load cleanup guarantee. Retain this bounded allocation until process exit;
                // decode stays nil and all future prepares fail. Never borrow freed storage or reuse a failed load.
                model = bytes; handle = loaded; binaryPath = binary.path
                loadFailed = true
            } else {
                dlclose(loaded); bytes.deallocate()
            }
            throw error
        }
        #endif
    }

    /// Verify and prepare the model while the caller holds the session's native budget.
    public func prepare(acceptance: WhistleCapability, bundle: Bundle = .main) throws {
        guard acceptance.available else { throw WhistleError.unavailable }
        try Task.checkCancellation()
        try open(bundle: bundle)
    }

    /// Actual C API, automatic language detection, no keywords; callers supply already segmented raw 16kHz PCM.
    /// Cancellation discards a late synchronous result. The serial actor cannot overlap model ownership/calls.
    public func transcribe(_ pcm: [Float], acceptance: WhistleCapability, bundle: Bundle = .main) throws -> WhistleResult {
        guard acceptance.available else { throw WhistleError.unavailable }
        try Task.checkCancellation()
        guard !pcm.isEmpty, pcm.count <= 240_128, pcm.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
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

    /// dyld can retain a C++ image with thread-local destructors after dlclose. Never free its borrowed weights
    /// while that model remains alive. Reuse that single resident model on the next session; memory measurements
    /// must include this retained allocation and speaker preflights see it in os_proc_available_memory().
    @discardableResult public func close() -> Bool {
        guard !loadFailed else { return false }
        guard let previous = handle else { return true }
        guard let binaryPath, dlclose(previous) == 0 else { return false }
        if let resident = dlopen(binaryPath, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD) {
            handle = resident
            guard let symbol = dlsym(resident, "needle_models") else { return false }
            if unsafeBitCast(symbol, to: Models.self)() != 0 { return false }
            // No native model still borrows the bytes, even if dyld retains the executable image.
            dlclose(resident)
        }
        decode = nil
        handle = nil
        model?.deallocate()
        model = nil
        self.binaryPath = nil
        return true
    }
}
