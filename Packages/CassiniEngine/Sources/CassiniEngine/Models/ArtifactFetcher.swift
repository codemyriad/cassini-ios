import Foundation
import CryptoKit
import CassiniNotebook

/// Decompresses a verified download for `ArtifactFetcher.fetchCompressed`, handing each block it produces to `sink`.
/// Every model file on the model host is seekable Zstandard; the app's decoder is `ZstdDecompressor` (CassiniInference).
public protocol Decompressing: Sendable {
    func decompress(_ source: URL, into sink: (Data) throws -> Void) throws
}

/// Downloads pinned artifacts (Android's `ArtifactFetcher`). A file is installed only after its size and SHA-256
/// match, and a verified file is never replaced. An interrupted download keeps its `.part` file, named after the
/// SHA-256 of the file it will be (through failures and the app being closed), and resumes it with an HTTP Range
/// request; a `.part` that cannot be the artifact is deleted. A transfer that ends early keeps its prefix and fails with
/// `DOWNLOAD`. Free-space checks count only the bytes still to fetch (`bytesToFetch`), because a kept `.part` already
/// holds the rest.
///
/// Every request asks for `Accept-Encoding: identity`, and an answer with another `Content-Encoding` fails with
/// `DOWNLOAD`: the bytes counted, resumed and hashed are the file's own. A resumed request also sends `If-Range` with
/// the entity tag of the pinned file, which the model host gives as its quoted SHA-256 (D4): a server holding other
/// bytes answers the whole file. A `200` to a resumed request restarts from zero whatever its entity tag (Android's
/// rule): the size and SHA-256 checks decide whether it is the file, and a proxy that strips entity tags cannot keep
/// every retry failing. A `206` without that entity tag cannot be told apart from bytes of another file, and an
/// unsatisfiable range (`416`) says the kept `.part` does not fit the file served: both fail with `DOWNLOAD` and delete
/// the `.part`, so the next attempt starts from zero instead of failing the same way.
///
/// Redirects are followed by hand, only as `RedirectPolicy` allows: HTTPS to `ModelCatalog.downloadHosts`, at most
/// five hops. Any other redirect fails the file with `DOWNLOAD` and keeps its `.part`.
///
/// A cancelled task stops between blocks with `CANCELLED` (Android checks the thread's interrupt there).
public struct ArtifactFetcher: Sendable {
    /// Seconds without an answer or data before a request fails.
    public static let timeout: TimeInterval = 30
    /// Space left free on top of what a download writes (32 MiB).
    public static let slackBytes: Int64 = 32 * 1024 * 1024
    static let bufferBytes = 128 * 1024
    static let progressInterval = Duration.milliseconds(500)
    private static let redirectCodes: Set<Int> = [301, 302, 303, 307, 308]
    static let identity = "identity"
    /// The longest notices file read (the host's is about 32 KB).
    public static let noticeMaxBytes: Int64 = 2 << 20

    /// The entity tag the model host gives `artifact`: its quoted SHA-256.
    public static func entityTag(_ artifact: Artifact) -> String { "\"\(artifact.sha256)\"" }

    public let transport: any HTTPTransport
    public let storage: any StorageProbe

    public init(transport: any HTTPTransport, storage: any StorageProbe) {
        self.transport = transport
        self.storage = storage
    }

    /// Hex SHA-256 of `file`, checking `cancelled` between blocks (the task's cancellation by default; the inference
    /// thread passes its cancel flag). `onBytes` receives the bytes hashed so far: after the first block, then at most
    /// every half second, and always once at the end with the file's length (a block that reaches the end is reported
    /// only there, after the last cancellation check).
    public static func digest(_ file: URL, onBytes: (Int64) -> Void = { _ in },
                              cancelled: () -> Bool = { Task.isCancelled }) throws -> String {
        let descriptor = open(file.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var hash = SHA256()
        var done: Int64 = 0
        var throttle = Throttle()
        let length = ModelFiles.length(of: file)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferBytes, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            try ModelError.require(!cancelled(), .cancelled)
            let count = try readRetryingInterruptions(cancelled: cancelled) {
                Darwin.read(descriptor, buffer.baseAddress, bufferBytes)
            }
            if count == 0 { break }
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            done += Int64(count)
            if done < length, throttle.due() { onBytes(done) }
        }
        onBytes(done)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Retry an interrupted local read without losing its cancellation boundary. Kept internal for deterministic
    /// error-path tests; public digest still exposes genuine read errors to installed-model validation.
    static func readRetryingInterruptions(cancelled: () -> Bool, _ read: () -> Int) throws -> Int {
        while true {
            try ModelError.require(!cancelled(), .cancelled)
            let count = read()
            if count >= 0 { return count }
            let code = errno
            if code == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// The bytes of `artifact` still to download into `directory`: none when its file is already there at its pinned
    /// size (`fetch` checks its SHA-256 without a request; for a compressed download, an install interrupted while it
    /// was decompressed), else its size less a `.part` that can still be its prefix. A longer `.part` is deleted by
    /// `fetch`, so it saves nothing.
    public static func bytesToFetch(_ artifact: Artifact, in directory: URL) -> Int64 {
        if ModelFiles.length(of: directory.appendingPathComponent(artifact.name)) == artifact.size { return 0 }
        let kept = ModelFiles.length(of: partial(artifact, in: directory))
        return kept > artifact.size ? artifact.size : artifact.size - kept
    }

    /// Places `artifact` in `directory` unless a verified copy is already there. The download goes to a `.part` file
    /// that replaces nothing until its size and SHA-256 match. `progress` receives the bytes done so far and whether
    /// they are being verified rather than downloaded: while downloading, the bytes in the `.part`; while verifying,
    /// the bytes hashed so far (from 0 up to the artifact's size, which always comes last). `redirects` decides which
    /// redirects are followed.
    ///
    /// A `.part` left by an earlier attempt is resumed with `Range: bytes=<length>-` and `If-Range: "<sha256>"`. A
    /// `206` answer is accepted only when it carries that entity tag, its `Content-Range` starts at that length and its
    /// total is the pinned size; a `200` answer restarts from zero, whatever its entity tag. A `206` without that entity
    /// tag or a `416` fails with `DOWNLOAD` and deletes the `.part`. A `206` that ends before the artifact's last byte
    /// (some servers cap open-ended ranges) keeps what it brought and fails with `DOWNLOAD`, so the next attempt resumes
    /// further on. On a size or SHA-256 mismatch the `.part` is deleted.
    public func fetch(_ url: String, _ artifact: Artifact, into directory: URL,
                      redirects: RedirectPolicy = .downloads, progress: (Int64, Bool) -> Void) async throws {
        var stage = "download.directory"
        do {
            try Self.localIO(model: artifact.name, stage: "download.directory") {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            stage = "download.cached-sha256"
            let destination = directory.appendingPathComponent(artifact.name)
            if ModelFiles.isFile(destination), ModelFiles.length(of: destination) == artifact.size,
               try Self.localIO(model: artifact.name, stage: stage, { try Self.digest(destination, onBytes: { progress($0, true) }) }) == artifact.sha256 {
                progress(artifact.size, true)
                return
            }
            let partial = Self.partial(artifact, in: directory)
            stage = "download.partial"
            try Self.localIO(model: artifact.name, stage: stage) {
                if ModelFiles.isDirectory(partial) { throw POSIXError(.EISDIR) }
            }
            // A longer file cannot be a prefix of the artifact.
            if ModelFiles.length(of: partial) > artifact.size { Self.remove(partial) }
            let offset = ModelFiles.length(of: partial)
            stage = "download.space"
            try ModelError.require(storage.availableBytes(at: directory) > artifact.size - offset + Self.slackBytes, .space)
            stage = "download.transfer"
            if offset < artifact.size { try await download(url, artifact, partial, redirects, progress) }
            progress(0, true)
            stage = "download.size"
            guard ModelFiles.length(of: partial) == artifact.size else {
                Self.remove(partial)
                throw ModelError(.modelVerify)
            }
            stage = "download.sha256"
            ModelInstallDiagnostics.begin(model: artifact.name, stage: stage)
            guard try Self.localIO(model: artifact.name, stage: stage, { try Self.digest(partial, onBytes: { progress($0, true) }) }) == artifact.sha256 else {
                Self.remove(partial)
                throw ModelError(.modelVerify)
            }
            stage = "download.sync"
            ModelInstallDiagnostics.begin(model: artifact.name, stage: stage)
            try Self.localIO(model: artifact.name, stage: stage) { try ModelFiles.sync(partial) }
            try ModelError.require(!Task.isCancelled, .cancelled)
            stage = "download.rename"
            if rename(partial.path, destination.path) != 0 {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                ModelInstallDiagnostics.failure(model: artifact.name, stage: stage, error: error)
                throw Self.writing(error)
            }
            progress(artifact.size, true)
        } catch {
            ModelInstallDiagnostics.failure(model: artifact.name, stage: stage, error: error)
            throw error
        }
    }

    /// Downloads the rest of `artifact` into `partial`, from its current length on.
    private func download(_ url: String, _ artifact: Artifact, _ partial: URL, _ redirects: RedirectPolicy,
                          _ progress: (Int64, Bool) -> Void) async throws {
        let offset = ModelFiles.length(of: partial)
        let answer = try await connect(url, offset: offset, ifRange: offset > 0 ? Self.entityTag(artifact) : nil,
                                       redirects, retryArtifact: artifact.name)
        defer { answer.close() }
        do {
            try Self.requireIdentity(answer)
            // Where a 206 answer's range ends (exclusive); nil for a whole 200 answer.
            let rangeEnd = try Self.resumes(answer, artifact, partial, offset)
            let first = rangeEnd != nil ? offset : 0
            let end = rangeEnd ?? artifact.size
            // Reject framing that cannot be this pinned response before waiting for any body.
            try ModelError.require(answer.expectedLength == nil || answer.expectedLength == end - first, .modelVerify)
            let received: Int64
            do {
                received = try await Self.copy(answer.body, to: partial, from: first, limit: end,
                                               finishAtLimit: answer.expectedLength != nil) { progress($0, false) }
            } catch let error as URLError where error.code != .cancelled && !Task.isCancelled
                && ModelFiles.length(of: partial) == artifact.size {
                // A late transport failure after all pinned bytes arrived still goes through size/SHA checks.
                // This does not establish the cause of any earlier zero-byte metadata timeout.
                return
            }
            // A lengthless short 200 and a capped 206 both keep their prefix for Range resume.
            if received < artifact.size {
                throw ModelError(.modelDownload, "Transfer ended at \(received) of \(artifact.size) bytes")
            }
        } catch let error as ModelError {
            // More bytes than the artifact has, or another file: the partial download cannot be finished.
            if error.failure == .modelVerify { Self.remove(partial) }
            throw error
        }
    }

    /// Reads the whole answer to a GET of `url`, at most `limit` bytes, following the redirects `redirects` allows
    /// (the model host's manifest and notices). An answer other than `200`, with a `Content-Encoding`, or shorter than it
    /// announced fails with `DOWNLOAD`; a longer one with `VERIFY`.
    public func read(_ url: String, limit: Int64, redirects: RedirectPolicy = .downloads) async throws -> Data {
        let answer = try await connect(url, offset: 0, ifRange: nil, redirects)
        defer { answer.close() }
        guard answer.status == 200 else { throw ModelError(.modelDownload, "HTTP \(answer.status)") }
        try Self.requireIdentity(answer)
        let cap = answer.expectedLength ?? limit
        try ModelError.require(cap >= 0 && cap <= limit, .modelVerify)
        var body = Data()
        if answer.expectedLength != 0 {
            for try await block in answer.body {
                try ModelError.require(!Task.isCancelled, .cancelled)
                try ModelError.require(Int64(block.count) <= cap - Int64(body.count), .modelVerify)
                body.append(block)
                // Complete the declared metadata body without waiting for transport EOF/teardown.
                if answer.expectedLength != nil && Int64(body.count) == cap { break }
            }
        }
        try ModelError.require(!Task.isCancelled, .cancelled)
        if let announced = answer.expectedLength, Int64(body.count) < announced {
            throw ModelError(.modelDownload, "Transfer ended at \(body.count) of \(announced) bytes")
        }
        return body
    }

    /// Downloads the model host's notices from `url` into `directory` as `NOTICE.txt`, written through to storage. The
    /// file has no pin (the manifest gives no hash for it): it must be text and not empty, else `VERIFY`.
    public func fetchNotice(_ url: String, into directory: URL, redirects: RedirectPolicy = .downloads) async throws {
        var stage = "notice.fetch"
        let partial = directory.appendingPathComponent("NOTICE.txt.part")
        do {
            ModelInstallDiagnostics.begin(model: ModelDescriptor.noticeFile, stage: stage)
            let text = try await read(url, limit: Self.noticeMaxBytes, redirects: redirects)
            guard !text.isEmpty, String(data: text, encoding: .utf8) != nil else {
                throw ModelError(.modelVerify, "The notices are not text")
            }
            let destination = directory.appendingPathComponent(ModelDescriptor.noticeFile)
            stage = "notice.write"
            try Self.localIO(model: ModelDescriptor.noticeFile, stage: stage) { try text.write(to: partial) }
            stage = "notice.sync"
            ModelInstallDiagnostics.begin(model: ModelDescriptor.noticeFile, stage: stage)
            try Self.localIO(model: ModelDescriptor.noticeFile, stage: stage) { try ModelFiles.sync(partial) }
            try ModelError.require(!Task.isCancelled, .cancelled)
            stage = "notice.rename"
            ModelInstallDiagnostics.begin(model: ModelDescriptor.noticeFile, stage: stage)
            if rename(partial.path, destination.path) != 0 {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                ModelInstallDiagnostics.failure(model: ModelDescriptor.noticeFile, stage: stage, error: error)
                throw Self.writing(error)
            }
        } catch {
            Self.remove(partial)
            ModelInstallDiagnostics.failure(model: ModelDescriptor.noticeFile, stage: stage, error: error)
            throw error
        }
    }

    /// Fails with `DOWNLOAD` unless `answer` has no `Content-Encoding` or `identity`: a transfer encoding would make the
    /// lengths, ranges and hashes count other bytes than the file's.
    private static func requireIdentity(_ answer: HTTPAnswer) throws {
        let encoding = (answer.header("Content-Encoding") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard encoding.isEmpty || encoding == identity else {
            throw ModelError(.modelDownload, "Content-Encoding \(encoding)")
        }
    }

    /// Asks for `url` (the bytes from `offset` on, when it is not 0, if the entity tag is still `ifRange`) and follows
    /// the redirects `policy` allows, sending the same request each time. Returns the first answer that is not a
    /// redirect.
    private func connect(_ url: String, offset: Int64, ifRange: String?, _ policy: RedirectPolicy,
                         retryArtifact: String? = nil) async throws
        -> HTTPAnswer {
        guard var target = URL(string: url) else { throw ModelError(.modelDownload, "Bad URL \(url)") }
        var headers = ["Accept-Encoding": Self.identity]
        if offset > 0 {
            headers["Range"] = "bytes=\(offset)-"
            if let ifRange { headers["If-Range"] = ifRange }
        }
        var hop = 0
        var activeTransport = transport
        var retried = false
        while true {
            let answer: HTTPAnswer
            do {
                answer = try await activeTransport.get(target, headers: headers, timeout: Self.timeout)
            } catch {
                // No HTTPAnswer means no body has reached the artifact writer. Retry only this GET, keeping
                // the exact resume headers and redirect budget; metadata has its separate bounded policy.
                if let retryArtifact {
                    ModelInstallDiagnostics.failure(model: retryArtifact, stage: "artifact.request.before-headers.no-body", error: error)
                }
                guard let retryArtifact, !retried, !ModelInstaller.isCancellation(error),
                      let network = error as? URLError,
                      network.code == .timedOut || network.code == .networkConnectionLost else { throw error }
                try Task.checkCancellation()
                guard let fresh = activeTransport.freshForRetry() else { throw error }
                try Task.checkCancellation()
                ModelInstallDiagnostics.begin(model: retryArtifact, stage: "artifact.request.before-headers.retry-1")
                activeTransport = fresh
                retried = true
                continue
            }
            guard Self.redirectCodes.contains(answer.status) else { return answer }
            let location = answer.header("Location")
            answer.close()
            hop += 1
            target = try policy.next(from: target, location: location, hop: hop)
        }
    }

    /// Whether `answer` continues the `offset` bytes of `partial`: for a `206` with the artifact's entity tag whose
    /// range starts there, ends inside the artifact and has the pinned size as its total, the offset just past the
    /// range's last byte; nil for a whole `200` answer, whatever its entity tag (the size and SHA-256 checks guard what
    /// it brings). Any other answer fails with `DOWNLOAD`. A `206` without the artifact's entity tag and an
    /// unsatisfiable range (`416`) also delete `partial`: neither can continue it, so the next attempt starts from zero
    /// rather than asking for the same range again.
    private static func resumes(_ answer: HTTPAnswer, _ artifact: Artifact, _ partial: URL,
                                _ offset: Int64) throws -> Int64? {
        if answer.status == 200 { return nil }
        if answer.status == 416 {
            remove(partial)
            throw ModelError(.modelDownload, "HTTP 416 for a part of \(offset) bytes")
        }
        if answer.status != 206 || offset == 0 { throw ModelError(.modelDownload, "HTTP \(answer.status)") }
        let tag = answer.header("ETag")?.trimmingCharacters(in: .whitespaces)
        guard tag == entityTag(artifact) else {
            remove(partial)
            throw ModelError(.modelDownload, "A partial answer with the entity tag \(tag ?? "none")")
        }
        let header = (answer.header("Content-Range") ?? "").trimmingCharacters(in: .whitespaces)
        guard let match = header.wholeMatch(of: /bytes (\d+)-(\d+)\/(\d+)/),
              let start = Int64(match.1), let end = Int64(match.2), let total = Int64(match.3) else {
            throw ModelError(.modelVerify, "Content-Range \(header)")
        }
        try ModelError.require(start == offset && total == artifact.size && end >= offset && end < artifact.size,
                               .modelVerify)
        return end + 1
    }

    /// Writes `body` to `file` (appending after its first `start` bytes, or from zero when `start` is 0) and returns
    /// the byte count, starting from `start`. A count above `limit` fails with `VERIFY`. `progress` receives the count
    /// at most every half second.
    private static func copy(_ body: AsyncThrowingStream<Data, any Error>, to file: URL, from start: Int64,
                             limit: Int64, finishAtLimit: Bool, progress: (Int64) -> Void) async throws -> Int64 {
        let output = try localIO(model: "artifact", stage: "download.output-create") { try writer(file, append: start > 0) }
        do {
            var count = start
            var throttle = Throttle()
            for try await block in body {
                try ModelError.require(!Task.isCancelled, .cancelled)
                try ModelError.require(Int64(block.count) <= limit - count, .modelVerify)
                try localIO(model: "artifact", stage: "download.output-write") { try output.write(contentsOf: block) }
                count += Int64(block.count)
                if throttle.due() { progress(count) }
                // Content-Length was checked against the pinned whole-file/range end before entry.
                // Do not wait for a stalled EOF once this response's complete body has arrived.
                if finishAtLimit && count == limit { break }
            }
            try ModelError.require(!Task.isCancelled, .cancelled)
            try localIO(model: "artifact", stage: "download.output-close") { try output.close() }
            return count
        } catch {
            try? output.close()
            throw error
        }
    }

    /// Like `fetch` for a compressed `download` of `artifact` (each model file on the model host is its own seekable
    /// Zstandard object). The compressed file is fetched and verified (size and SHA-256), then decompressed to a `.part`
    /// file that replaces nothing until the decompressed size and SHA-256 match, and is written through to storage
    /// before it is renamed into place. The verified compressed file is deleted only then: a cancel or a failure while
    /// it is decompressed keeps it, so the next attempt decompresses it again without downloading it. Its own `.part`
    /// is resumed like any other.
    ///
    /// `progress` counts in bytes of `download`, as for `fetch`. While verifying, the count covers the whole check:
    /// hashing the compressed file, decompressing it and hashing the result, each share in proportion to the bytes it
    /// reads or writes, so "Checking files" rises once from 0 to the download's size.
    public func fetchCompressed(_ url: String, download: Artifact, artifact: Artifact, into directory: URL,
                                decoder: any Decompressing, redirects: RedirectPolicy = .downloads,
                                progress: (Int64, Bool) -> Void) async throws {
        try Self.localIO(model: artifact.name, stage: "download.directory") {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        let destination = directory.appendingPathComponent(artifact.name)
        let compressed = directory.appendingPathComponent(download.name)
        let existing = Self.scaled(to: download.size, of: artifact.size)
        if ModelFiles.isFile(destination), ModelFiles.length(of: destination) == artifact.size,
           try Self.localIO(model: artifact.name, stage: "output.cached-sha256", { try Self.digest(destination, onBytes: { progress(existing($0), true) }) }) == artifact.sha256 {
            // An install killed between the rename and the delete leaves the download beside its file.
            Self.remove(compressed)
            Self.remove(Self.partial(download, in: directory))
            progress(download.size, true)
            return
        }
        // A kept `.part` of the compressed file already holds its share; the decompressed copy needs all of its own.
        let needed = Self.bytesToFetch(download, in: directory) + artifact.size + Self.slackBytes
        try ModelError.require(storage.availableBytes(at: directory) > needed, .space)
        // The check reads the download once and writes and reads the decompressed file once each.
        let check = Self.scaled(to: download.size, of: download.size + 2 * artifact.size)
        try await fetch(url, download, into: directory, redirects: redirects) { bytes, verifying in
            // fetch ends with the download's size once it is installed; the check is not over yet.
            if verifying { progress(check(min(bytes, download.size)), true) } else { progress(bytes, false) }
        }
        try Self.decompress(compressed, artifact, into: directory, decoder: decoder) {
            progress(check(download.size + $0), true)
        }
        Self.remove(compressed)
        progress(download.size, true)
    }

    /// Decompresses a verified `source` into `directory` as `artifact`, or fails without a file. The file is written
    /// through to storage (`F_FULLFSYNC`) before its rename. `progress` receives the bytes written, then the
    /// artifact's size plus the bytes hashed (up to twice its size). A full disk fails with `SPACE`; other failures to
    /// create, write, close or sync the decompressed file (this device's, not the download's) with `INSTALL`; a stream
    /// the decoder cannot read, or output that is not the pinned file, with `VERIFY`.
    public static func decompress(_ source: URL, _ artifact: Artifact, into directory: URL, decoder: any Decompressing,
                                  progress: (Int64) -> Void = { _ in }) throws {
        let destination = directory.appendingPathComponent(artifact.name)
        let partial = partial(artifact, in: directory)
        try localIO(model: artifact.name, stage: "output.create") {
            if ModelFiles.isDirectory(partial) { throw POSIXError(.EISDIR) }
        }
        defer { remove(partial) }
        var stage = "output.create"
        var reported = false
        func report(_ error: any Error) {
            guard !reported else { return }
            reported = true
            ModelInstallDiagnostics.failure(model: artifact.name, stage: stage, error: error)
        }
        do {
            let output: FileHandle
            do { output = try writer(partial, append: false) } catch { report(error); throw writing(error) }
            var count: Int64 = 0
            var throttle = Throttle()
            do {
                stage = "decode"
                ModelInstallDiagnostics.begin(model: artifact.name, stage: stage)
                try decoder.decompress(source) { block in
                    try ModelError.require(!Task.isCancelled, .cancelled)
                    stage = "output.size"
                    count += Int64(block.count)
                    try ModelError.require(count <= artifact.size, .modelVerify)
                    stage = "output.write"
                    do { try output.write(contentsOf: block) } catch { report(error); throw writing(error) }
                    if throttle.due() { progress(count) }
                    stage = "decode"
                }
            } catch {
                try? output.close()
                throw error
            }
            stage = "output.close"
            do { try output.close() } catch { report(error); throw writing(error) }
            stage = "output.size"
            try ModelError.require(ModelFiles.length(of: partial) == artifact.size, .modelVerify)
            stage = "output.sha256"
            ModelInstallDiagnostics.begin(model: artifact.name, stage: stage)
            try ModelError.require(try localIO(model: artifact.name, stage: stage, { try digest(partial) { progress(artifact.size + $0) } }) == artifact.sha256, .modelVerify)
            try ModelError.require(!Task.isCancelled, .cancelled)
            stage = "file.sync"
            ModelInstallDiagnostics.begin(model: artifact.name, stage: stage)
            do { try ModelFiles.sync(partial) } catch { report(error); throw writing(error) }
            try ModelError.require(!Task.isCancelled, .cancelled)
            stage = "file.rename"
            ModelInstallDiagnostics.begin(model: artifact.name, stage: stage)
            if rename(partial.path, destination.path) != 0 {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                report(error)
                throw writing(error)
            }
        } catch let error as ModelError {
            report(error)
            throw error
        } catch is CancellationError {
            throw ModelError(.cancelled)
        } catch where CheckpointFiles.isOutOfSpace(error) {
            report(error)
            throw ModelError(.space, "Decompression: \(error)")
        } catch {
            report(error)
            // The decoder also opens/reads its retained compressed file. Those filesystem failures are local;
            // its own format errors still mean the checked stream could not be decoded.
            let native = error as NSError
            if native.domain == NSPOSIXErrorDomain
                || (native.domain == NSCocoaErrorDomain && (0..<1024).contains(native.code)) {
                throw writing(error)
            }
            throw ModelError(.modelVerify, "Decompression: \(error)")
        }
    }

    /// Local filesystem failures cannot be repaired by a network retry. Public `digest` retains its raw I/O
    /// errors for installed-model validation; installation call sites classify them here.
    private static func localIO<T>(model: String, stage: String, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch is CancellationError { throw ModelError(.cancelled) }
        catch {
            ModelInstallDiagnostics.failure(model: model, stage: stage, error: error)
            throw writing(error)
        }
    }

    private static func writing(_ error: any Error) -> ModelError {
        if let error = error as? ModelError { return error }
        return ModelError(CheckpointFiles.isOutOfSpace(error) ? .space : .modelInstall, "File I/O: \(error)")
    }

    /// Maps a count out of `of` to the same share of `to`.
    private static func scaled(to: Int64, of: Int64) -> (Int64) -> Int64 {
        { done in of <= 0 ? to : Int64(Double(to) * Double(min(max(done, 0), of)) / Double(of)) }
    }

    /// The `.part` of `artifact` in `directory`, named after its SHA-256: a kept part only ever resumes the file it
    /// was the prefix of, even when the host publishes another file under the same name.
    static func partial(_ artifact: Artifact, in directory: URL) -> URL {
        directory.appendingPathComponent("\(artifact.sha256).part")
    }

    private static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    /// A handle that writes `file`: after its bytes when `append`, else over an emptied file.
    private static func writer(_ file: URL, append: Bool) throws -> FileHandle {
        let flags = O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC)
        let descriptor = open(file.path, flags, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

/// True the first time, then at most every `ArtifactFetcher.progressInterval`.
private struct Throttle {
    private var last: ContinuousClock.Instant?

    mutating func due() -> Bool {
        let now = ContinuousClock.now
        if let last, now - last <= ArtifactFetcher.progressInterval { return false }
        last = now
        return true
    }
}
