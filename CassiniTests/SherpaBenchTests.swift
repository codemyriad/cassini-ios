import XCTest
import AVFoundation
import CassiniEngine
import CassiniInference
import CassiniNotebook
import CassiniSherpa

/// The WP0 spike: a real Parakeet Ultra decode through the sherpa-onnx C API, with memory and speed. Opt-in and
/// skipped unless the build links the runtime (every iOS build does) and the environment names the models;
/// scripts/sherpa-bench.sh runs it on a simulator. Simulator figures are not device measurements: the simulator
/// has no jetsam limit and runs on the Mac's cores.
///
/// Environment (xcodebuild passes TEST_RUNNER_<name> through as <name>):
///   CASSINI_PARAKEET_MODELS     directory with encoder/decoder/joiner .int8.onnx and tokens.txt (read only; cloned
///                               into this app's caches)
///   CASSINI_PARAKEET_AUDIO      the FLEURS-it short clip, 16 kHz mono WAV
///   CASSINI_PARAKEET_GOLDEN     Android's fleurs-it-short.txt golden
///   CASSINI_BENCH_LONG_SECONDS  length of the long run in 28 s windows (default 0: skipped)
///   CASSINI_BENCH_SPEAKERS      a model root with the speaker models' revision directories: with the recognizer
///                               still loaded, stream 60 s through Sortformer and make a CAM++ print, as a job holds
///                               both
///   CASSINI_BENCH_OUT           a file to write the measurements to as JSON
final class SherpaBenchTests: XCTestCase {
    private static let rate = 16_000
    /// The pinned export's sizes (the dist pin, D16 §2).
    private static let sizes = Dictionary(uniqueKeysWithValues: ModelCatalog.parakeetArtifacts.map { ($0.name, Int($0.size)) })

    func testParakeetUltraDecodesOnTheSimulator() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(SherpaRuntime.isLinked, "built without the native runtime")
        // Opt-in: every iOS build links the runtime, so the environment decides (scripts/sherpa-bench.sh sets it).
        try XCTSkipUnless(environment["CASSINI_PARAKEET_MODELS"] != nil, "opt-in: scripts/sherpa-bench.sh sets CASSINI_PARAKEET_MODELS")
        let source = try XCTUnwrap(environment["CASSINI_PARAKEET_MODELS"].map { URL(fileURLWithPath: $0) },
                                   "set CASSINI_PARAKEET_MODELS")
        let audio = try XCTUnwrap(environment["CASSINI_PARAKEET_AUDIO"].map { URL(fileURLWithPath: $0) })
        var report: [String: Any] = ["platform": "iOS Simulator (not a device measurement)",
                                     "device": environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "?",
                                     "runtime": environment["SIMULATOR_RUNTIME_VERSION"] ?? "?",
                                     "cores": ProcessInfo.processInfo.activeProcessorCount]
        let baseline = MemorySample.now()
        report["baselineFootprintMiB"] = mib(baseline.footprintBytes)

        let models = try installModels(from: source)
        let files = ParakeetFiles(directory: models)
        XCTAssertTrue(files.present())

        // Load with debug on, catching sherpa-onnx's stderr to see that it recognised Ultra by the encoder's url.
        let loadStart = Date()
        let (decoder, log) = try capturingStandardError { try ParakeetDecoder(files: files, debug: true) }
        report["loadSeconds"] = Date().timeIntervalSince(loadStart)
        let urlLine = log.split(separator: "\n").first { $0.contains("url=") || $0.contains("url:") || $0.contains("\turl") }
        report["encoderUrlLine"] = urlLine.map(String.init) ?? ""
        // The dist export (D16 §2) keeps that url in its encoder metadata; the fork's 0c2ee3f selects TDT by it.
        XCTAssertTrue(log.contains("https://huggingface.co/moondream/parakeet-ultra"), "encoder metadata: \(log.suffix(2000))")
        let loaded = MemorySample.now()
        report["loadedFootprintMiB"] = mib(loaded.footprintBytes)
        report["loadedPeakMiB"] = mib(loaded.peakFootprintBytes)
        report["availableAfterLoadMiB"] = mib(loaded.availableBytes)

        // FLEURS-it short, decoded whole with no tail (QUIET cutting of a clip of 10 s or more) and with the 500 ms tail
        // a SPEECH span gets (DecodePolicy.WHOLE_SPANS).
        let fleurs = try readMono16k(audio)
        report["fleursSeconds"] = Double(fleurs.count) / Double(Self.rate)
        let golden = try environment["CASSINI_PARAKEET_GOLDEN"].map { try goldenParagraph(URL(fileURLWithPath: $0)) }
        for (name, tail) in [("fleursNoTail", 0), ("fleursTail500", Self.rate / 2)] {
            let (result, seconds) = timed { decoder.decode(fleurs + [Float](repeating: 0, count: tail)) }
            let words = timedWords(result)
            XCTAssertFalse(words.isEmpty, "timed words")
            XCTAssertTrue(result.text.trimmingCharacters(in: .whitespaces).isEmpty || !result.tokens.isEmpty, "TIMINGS rule")
            var entry: [String: Any] = ["text": result.text.trimmingCharacters(in: .whitespaces), "tokens": result.tokens.count,
                                        "words": words.count, "seconds": seconds, "pieces": result.tokens.joined(separator: "|"),
                                        "rtf": seconds / (Double(fleurs.count) / Double(Self.rate)),
                                        "firstWords": words.prefix(3).map { "\($0.word)@\(String(format: "%.2f", $0.start))-\(String(format: "%.2f", $0.end))" }]
            if let golden {
                entry["golden"] = golden
                entry["matchesGolden"] = result.text.trimmingCharacters(in: .whitespaces) == golden
                entry["matchesGoldenIgnoringCase"] = result.text.trimmingCharacters(in: .whitespaces).lowercased() == golden.lowercased()
                entry["wordDifferences"] = wordDifferences(result.text, golden)
            }
            report[name] = entry
        }

        // 28 s and 60 s clips: FLEURS repeated with 0.5 s of silence between copies.
        for seconds in [28, 60] {
            let clip = repeated(fleurs, seconds: seconds)
            let (result, elapsed) = timed { decoder.decode(clip) }
            let sample = MemorySample.now()
            report["clip\(seconds)s"] = ["seconds": elapsed, "rtf": elapsed / Double(seconds), "words": timedWords(result).count,
                                        "footprintMiB": mib(sample.footprintBytes), "peakMiB": mib(sample.peakFootprintBytes),
                                        "availableMiB": mib(sample.availableBytes)] as [String: Any]
        }

        // The long run: 28 s windows, as IncrementalTranscript feeds the decoder.
        let longSeconds = Int(environment["CASSINI_BENCH_LONG_SECONDS"] ?? "0") ?? 0
        if longSeconds > 0 {
            let window = repeated(fleurs, seconds: 28)
            var decodeSeconds = 0.0, words = 0, maxFootprint: UInt64 = 0
            var thermal: [String] = []
            let started = Date()
            for index in 0..<(longSeconds + 27) / 28 {
                let (result, elapsed) = timed { decoder.decode(window) }
                decodeSeconds += elapsed
                words += timedWords(result).count
                maxFootprint = max(maxFootprint, MemorySample.now().footprintBytes)
                if index % 20 == 0 { thermal.append(thermalName(ProcessInfo.processInfo.thermalState)) }
            }
            let sample = MemorySample.now()
            report["long"] = ["audioSeconds": ((longSeconds + 27) / 28) * 28, "decodeSeconds": decodeSeconds,
                              "wallSeconds": Date().timeIntervalSince(started),
                              "rtf": decodeSeconds / Double(((longSeconds + 27) / 28) * 28), "words": words,
                              "maxFootprintMiB": mib(maxFootprint), "peakMiB": mib(sample.peakFootprintBytes),
                              "thermalStates": thermal] as [String: Any]
        }
        report["thermalState"] = thermalName(ProcessInfo.processInfo.thermalState)
        let afterDecodes = MemorySample.now()
        report["afterDecodesFootprintMiB"] = mib(afterDecodes.footprintBytes)
        report["peakMiB"] = mib(afterDecodes.peakFootprintBytes)

        // Streaming Sortformer with the recognizer still loaded, as a job holds both while it decodes (Android's
        // rule), then CAM++ over 45 s of the clip: the memory of the whole speaker pipeline on top of Ultra.
        if let speakerModels = environment["CASSINI_BENCH_SPEAKERS"].map({ URL(fileURLWithPath: $0) }) {
            let started = Date()
            let clip = repeated(fleurs, seconds: 60)
            let diarizer = try SortformerStream(model: URL(fileURLWithPath: ModelCatalog.diarization.path(
                in: speakerModels, ModelCatalog.diarizationModel.name)))
            var start = 0
            while start < clip.count {
                let end = min(clip.count, start + IncrementalTranscript.windowSamples)
                try diarizer.process(PcmAudio(Array(clip[start..<end]), sampleRate: Self.rate), startMs: Int64(start) * 1000 / Int64(Self.rate))
                if end == clip.count { break }
                start += IncrementalTranscript.windowSamples - IncrementalTranscript.overlapSamples
            }
            let streamed = MemorySample.now()
            let prints = try VoiceprintExtractor.compute(
                model: URL(fileURLWithPath: ModelCatalog.voiceprint.path(in: speakerModels, ModelCatalog.voiceprintModel.name)),
                audio: PcmAudio(clip, sampleRate: Self.rate), windows: ["s": [PrintWindow(0, 45 * Self.rate)]]) {}
            let printed = MemorySample.now()
            report["speakers"] = ["seconds": Date().timeIntervalSince(started), "slots": Set(diarizer.turns.map(\.speaker)).count,
                                  "stateFloats": diarizer.saveState().count, "printDim": prints["s"]?.vector.count ?? 0,
                                  "withDiarizerFootprintMiB": mib(streamed.footprintBytes),
                                  "afterPrintsFootprintMiB": mib(printed.footprintBytes),
                                  "peakMiB": mib(printed.peakFootprintBytes)] as [String: Any]
        }
        _ = consume decoder
        report["afterReleaseFootprintMiB"] = mib(MemorySample.now().footprintBytes)

        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let text = String(decoding: json, as: UTF8.self)
        print("CASSINI_BENCH_BEGIN\n\(text)\nCASSINI_BENCH_END")
        if let out = environment["CASSINI_BENCH_OUT"] { try json.write(to: URL(fileURLWithPath: out)) }
        let attachment = XCTAttachment(string: text)
        attachment.name = "sherpa-bench.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - helpers

    /// Clones the models into this app's caches (APFS clones, so no second 650 MB) and checks their sizes.
    private func installModels(from source: URL) throws -> URL {
        let target = URL.cachesDirectory.appendingPathComponent("parakeet-ultra", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        for (name, size) in Self.sizes {
            let destination = target.appendingPathComponent(name)
            if (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) != size {
                try? manager.removeItem(at: destination)
                try manager.copyItem(at: source.appendingPathComponent(name), to: destination)
            }
            XCTAssertEqual(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, size, name)
        }
        return target
    }

    private func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.rate), channels: 1, interleaved: false))
        XCTAssertEqual(file.processingFormat.sampleRate, Double(Self.rate))
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func repeated(_ clip: [Float], seconds: Int) -> [Float] {
        let total = seconds * Self.rate
        let gap = [Float](repeating: 0, count: Self.rate / 2)
        var out: [Float] = []
        out.reserveCapacity(total)
        while out.count < total { out += clip; out += gap }
        return Array(out.prefix(total))
    }

    /// The transcript paragraph of an Android TXT export golden (the line after the "[mm:ss]" line).
    private func goldenParagraph(_ url: URL) throws -> String {
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("[") && $0.hasSuffix("]") })
        return lines[index + 1].trimmingCharacters(in: .whitespaces)
    }

    private func wordDifferences(_ text: String, _ golden: String) -> [String] {
        let a = text.split(separator: " ").map(String.init), b = golden.split(separator: " ").map(String.init)
        var out: [String] = []
        for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : "") != (i < b.count ? b[i] : "") {
            out.append("\(i): \(i < a.count ? a[i] : "∅") ≠ \(i < b.count ? b[i] : "∅")")
        }
        return out
    }

    /// Words from the token arrays: a token that starts with "▁" or a space begins a word (a simplified TokenWords for
    /// the spike; WP2 ports Android's).
    private func timedWords(_ result: RecognizedTokens) -> [(word: String, start: Float, end: Float)] {
        var out: [(word: String, start: Float, end: Float)] = []
        for i in result.tokens.indices {
            let token = result.tokens[i]
            let start = i < result.timestamps.count ? result.timestamps[i] : 0
            let end = start + (i < result.durations.count ? result.durations[i] : 0)
            if token.hasPrefix("▁") || token.hasPrefix(" ") || out.isEmpty {
                out.append((String(token.drop { $0 == "▁" || $0 == " " }), start, end))
            } else {
                out[out.count - 1].word += token
                out[out.count - 1].end = end
            }
        }
        return out.filter { !$0.word.isEmpty }
    }

    private func timed<T>(_ body: () -> T) -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }

    private func capturingStandardError<T>(_ body: () throws -> T) throws -> (T, String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sherpa-stderr-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        fflush(stderr)
        let saved = dup(STDERR_FILENO)
        dup2(handle.fileDescriptor, STDERR_FILENO)
        defer { try? FileManager.default.removeItem(at: url) }
        let value: T
        do {
            value = try body()
        } catch {
            fflush(stderr); dup2(saved, STDERR_FILENO); close(saved)
            throw error
        }
        fflush(stderr); dup2(saved, STDERR_FILENO); close(saved)
        try handle.close()
        return (value, (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    private func mib(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }

    private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

