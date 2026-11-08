import CWhistleDSP
import CryptoKit
import Foundation
import CassiniNotebook

/// D11.1 model with the application's existing, pinned iOS CPU runtime. One inference task owns this instance.
/// The ONNX runtime differs from desktop; exact whole-pipeline fixture parity is required for the internal path.
public final class WhistleVAD {
    public static let modelSHA256 = "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"
    private let detector: OpaquePointer
    private var filter = SpeechInputFilter()
    public init(model: URL) throws {
        let bytes = try Data(contentsOf: model, options: .mappedIfSafe)
        guard bytes.count < 10_000_000,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == Self.modelSHA256 else {
            throw WhistleError.integrity
        }
        var environment: [String:String] = [:]
        for (key, value) in WhistlePrivacy.required {
            guard setenv(key, value, 1) == 0, let raw = getenv(key) else { throw WhistleError.privacy }
            environment[key] = String(cString: raw)
        }
        var error = [CChar](repeating: 0, count: 2048)
        let created = try WhistlePrivacy.enter(environment: environment) {
            model.path.withCString { cassini_vad_create($0, &error, error.count) }
        }
        guard let created else { throw WhistleError.unavailable }
        detector = created
    }
    public func probability(_ frame: [Float]) throws -> Float {
        guard frame.count == 512 else { throw WhistleError.invalidInput }
        let input = filter(frame)
        var probability: Float = 0
        var error = [CChar](repeating: 0, count: 2048)
        let result = input.withUnsafeBufferPointer {
            cassini_vad_probability(detector, $0.baseAddress, &probability, &error, error.count)
        }
        guard result == 1, probability.isFinite, (0...1).contains(probability) else { throw WhistleError.nativeFailure }
        return probability
    }
    deinit { cassini_vad_destroy(detector) }
}
