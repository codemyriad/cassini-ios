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
/// bytes answers the whole file. iOS takes an answer to a resumed request only when it carries that entity tag: a
/// `206` or a `200` with another tag (a captive portal, a proxy, another file) fails with `DOWNLOAD` and leaves the kept
/// `.part` as it was, so it is never truncated by an answer that is not the file. An unsatisfiable range (`416`) keeps it
/// too: a `.part` shorter than the pinned size is always a range the file has, so that answer is not the file's.
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
            let count = Darwin.read(descriptor, buffer.baseAddress, bufferBytes)
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            done += Int64(count)
            if done < length, throttle.due() { onBytes(done) }
        }
        onBytes(done)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes of `artifact` still to download into `directory`: its size less a `.part` that can still be its
    /// prefix. A longer `.part` is deleted by `fetch`, so it saves nothing.
    public static func bytesToFetch(_ artifact: Artifact, in directory: URL) -> Int64 {
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
    /// total is the pinned size; a `200` answer with that entity tag restarts from zero. A `206` that ends before the
    /// artifact's last byte (some servers cap open-ended ranges) keeps what it brought and fails with `DOWNLOAD`, so the
    /// next attempt resumes further on. On a size or SHA-256 mismatch the `.part` is deleted.
    public func fetch(_ url: String, _ artifact: Artifact, into directory: URL,
                      redirects: RedirectPolicy = .downloads, progress: (Int64, Bool) -> Void) async throws {
        let destination = directory.appendingPathComponent(artifact.name)
        if ModelFiles.length(of: destination) == artifact.size,
           try Self.digest(destination, onBytes: { progress($0, true) }) == artifact.sha256 {
            progress(artifact.size, true)
            return
        }
        let partial = Self.partial(artifact, in: directory)
        // A longer file cannot be a prefix of the artifact.
        if ModelFiles.length(of: partial) > artifact.size { Self.remove(partial) }
        let offset = ModelFiles.length(of: partial)
        try ModelError.require(storage.availableBytes(at: directory) > artifact.size - offset + Self.slackBytes, .space)
        if offset < artifact.size { try await download(url, artifact, partial, redirects, progress) }
        progress(0, true)
        guard ModelFiles.length(of: partial) == artifact.size,
              try Self.digest(partial, onBytes: { progress($0, true) }) == artifact.sha256 else {
            Self.remove(partial)
            throw ModelError(.modelVerify)
        }
        try ModelError.require(rename(partial.path, destination.path) == 0, .modelInstall)
        progress(artifact.size, true)
    }

    /// Downloads the rest of `artifact` into `partial`, from its current length on.
    private func download(_ url: String, _ artifact: Artifact, _ partial: URL, _ redirects: RedirectPolicy,
                          _ progress: (Int64, Bool) -> Void) async throws {
        let offset = ModelFiles.length(of: partial)
        let answer = try await connect(url, offset: offset, ifRange: offset > 0 ? Self.entityTag(artifact) : nil,
                                       redirects)
        defer { answer.close() }
        do {
            try Self.requireIdentity(answer)
            // Where a 206 answer's range ends (exclusive); nil for a whole 200 answer.
            let rangeEnd = try Self.resumes(answer, artifact, partial, offset)
            let first = rangeEnd != nil ? offset : 0
            // Where the answer says it ends; -1 when it does not say.
            let announced = answer.expectedLength.map { first + $0 } ?? -1
            let received = try await Self.copy(answer.body, to: partial, from: first, limit: artifact.size) {
                progress($0, false)
            }
            // A connection that closed before the announced end leaves a prefix, and so does a range that stops
            // short of the artifact's end: keep it for the next attempt.
            let expected = rangeEnd != nil ? artifact.size : announced
            if received < expected {
                throw ModelError(.modelDownload, "Transfer ended at \(received) of \(expected) bytes")
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
        try ModelError.require((answer.expectedLength ?? 0) <= limit, .modelVerify)
        var body = Data()
        for try await block in answer.body {
            try ModelError.require(!Task.isCancelled, .cancelled)
            try ModelError.require(Int64(body.count + block.count) <= limit, .modelVerify)
            body.append(block)
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
        let text = try await read(url, limit: Self.noticeMaxBytes, redirects: redirects)
        guard !text.isEmpty, String(data: text, encoding: .utf8) != nil else {
            throw ModelError(.modelVerify, "The notices are not text")
        }
        let destination = directory.appendingPathComponent(ModelDescriptor.noticeFile)
        let partial = directory.appendingPathComponent("\(ModelDescriptor.noticeFile).part")
        do {
            try text.write(to: partial)
            try ModelFiles.sync(partial)
        } catch {
            Self.remove(partial)
            throw error
        }
        try ModelError.require(rename(partial.path, destination.path) == 0, .modelInstall)
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
    private func connect(_ url: String, offset: Int64, ifRange: String?, _ policy: RedirectPolicy) async throws
        -> HTTPAnswer {
        guard var target = URL(string: url) else { throw ModelError(.modelDownload, "Bad URL \(url)") }
        var headers = ["Accept-Encoding": Self.identity]
        if offset > 0 {
            headers["Range"] = "bytes=\(offset)-"
            if let ifRange { headers["If-Range"] = ifRange }
        }
        var hop = 0
        while true {
            let answer = try await transport.get(target, headers: headers, timeout: Self.timeout)
            guard Self.redirectCodes.contains(answer.status) else { return answer }
            let location = answer.header("Location")
            answer.close()
            hop += 1
            target = try policy.next(from: target, location: location, hop: hop)
        }
    }

    /// Whether `answer` continues the `offset` bytes of `partial`: for a `206` with the artifact's entity tag whose
    /// range starts there, ends inside the artifact and has the pinned size as its total, the offset just past the
    /// range's last byte; nil for a whole `200` answer (with the artifact's entity tag when `partial` has bytes, so a
    /// whole answer of another file never truncates it). Any other answer fails and keeps `partial`, an unsatisfiable
    /// range (`416`) too: `fetch` asks only for a range inside the pinned size, so that answer is not the file's.
    private static func resumes(_ answer: HTTPAnswer, _ artifact: Artifact, _ partial: URL,
                                _ offset: Int64) throws -> Int64? {
        let tag = answer.header("ETag")?.trimmingCharacters(in: .whitespaces)
        if answer.status == 200 {
            if offset > 0 && tag != entityTag(artifact) {
                throw ModelError(.modelDownload, "A whole answer with the entity tag \(tag ?? "none") for a kept part")
            }
            return nil
        }
        if answer.status != 206 || offset == 0 { throw ModelError(.modelDownload, "HTTP \(answer.status)") }
        guard tag == entityTag(artifact) else {
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
                             limit: Int64, progress: (Int64) -> Void) async throws -> Int64 {
        let output = try writer(file, append: start > 0)
        defer { try? output.close() }
        var count = start
        var throttle = Throttle()
        for try await block in body {
            try ModelError.require(!Task.isCancelled, .cancelled)
            count += Int64(block.count)
            try ModelError.require(count <= limit, .modelVerify)
            try output.write(contentsOf: block)
            if throttle.due() { progress(count) }
        }
        try ModelError.require(!Task.isCancelled, .cancelled)
        return count
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
        let destination = directory.appendingPathComponent(artifact.name)
        let compressed = directory.appendingPathComponent(download.name)
        let existing = Self.scaled(to: download.size, of: artifact.size)
        if ModelFiles.length(of: destination) == artifact.size,
           try Self.digest(destination, onBytes: { progress(existing($0), true) }) == artifact.sha256 {
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
    /// artifact's size plus the bytes hashed (up to twice its size). A full disk fails with `SPACE`, other write and
    /// sync failures with `INSTALL`, output that is not the pinned file with `VERIFY`.
    public static func decompress(_ source: URL, _ artifact: Artifact, into directory: URL, decoder: any Decompressing,
                                  progress: (Int64) -> Void = { _ in }) throws {
        let destination = directory.appendingPathComponent(artifact.name)
        let partial = partial(artifact, in: directory)
        defer { remove(partial) }
        do {
            let output = try writer(partial, append: false)
            var count: Int64 = 0
            var throttle = Throttle()
            do {
                defer { try? output.close() }
                try decoder.decompress(source) { block in
                    try ModelError.require(!Task.isCancelled, .cancelled)
                    count += Int64(block.count)
                    try ModelError.require(count <= artifact.size, .modelVerify)
                    try output.write(contentsOf: block)
                    if throttle.due() { progress(count) }
                }
            }
            try ModelError.require(ModelFiles.length(of: partial) == artifact.size, .modelVerify)
            try ModelError.require(try digest(partial) { progress(artifact.size + $0) } == artifact.sha256, .modelVerify)
            do { try ModelFiles.sync(partial) } catch {
                throw ModelError(CheckpointFiles.isOutOfSpace(error) ? .space : .modelInstall, "\(error)")
            }
            try ModelError.require(rename(partial.path, destination.path) == 0, .modelInstall)
        } catch let error as ModelError {
            throw error
        } catch is CancellationError {
            throw ModelError(.cancelled)
        } catch where CheckpointFiles.isOutOfSpace(error) {
            throw ModelError(.space, "Decompression: \(error)")
        } catch {
            throw ModelError(.modelVerify, "Decompression: \(error)")
        }
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
        if !append || !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        if append { try handle.seekToEnd() }
        return handle
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
