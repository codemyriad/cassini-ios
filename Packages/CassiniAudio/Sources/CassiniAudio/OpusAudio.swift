import Foundation
import AVFoundation
import CassiniCore
import COpusBridge

/// Bounded-memory Ogg Opus conversion. Audio packets are decoded/encoded incrementally.
public enum OpusAudio {
    public static func decode(_ source: URL, to destination: URL) throws {
        let info = try OggOpus.scan(source)
        guard info.validFraming, info.head.count >= 19, info.head[18] == 0, (1...2).contains(info.channels), info.sampleCount > 0 else {
            throw CassiniError("Unsupported or damaged Opus stream")
        }
        _ = try info.digest()
        var status: Int32 = 0
        guard let decoder = opus_decoder_create(48_000, Int32(info.channels), &status), status == OPUS_OK else { throw failure(status) }
        defer { opus_decoder_destroy(decoder) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(info.channels), interleaved: true) else { throw CassiniError("Cannot create audio format") }
        let file = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let reader = OggOpus.Reader(try FileSource(source)); _ = try reader.headers()
        var pcm = [Float](repeating: 0, count: 5760 * info.channels)
        var skip = OggOpus.u16(info.head, 10), written: Int64 = 0
        let gainValue = Int16(bitPattern: UInt16(OggOpus.u16(info.head, 16)))
        let gain = pow(Float(10), Float(gainValue) / (20 * 256))
        while let packet = try reader.packet() {
            try Task.checkCancellation()
            let frames = opus_decode_float(decoder, packet, Int32(packet.count), &pcm, 5760, 0)
            guard frames >= 0 else { throw failure(frames) }
            let leading = min(skip, Int(frames)); skip -= leading
            let available = max(0, Int(frames) - leading)
            let count = min(available, Int(max(0, info.sampleCount - written)))
            guard count > 0 else { continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let output = buffer.floatChannelData?[0] else { throw CassiniError("Cannot allocate audio buffer") }
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<(count * info.channels) { output[index] = pcm[leading * info.channels + index] * gain }
            try file.write(from: buffer); written += Int64(count)
        }
        guard written == info.sampleCount else { throw CassiniError("Truncated Opus audio") }
    }

    public static func encode(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960) else { throw CassiniError("Cannot prepare Opus conversion") }
        var status: Int32 = 0
        guard let encoder = opus_encoder_create(48_000, 1, OPUS_APPLICATION_AUDIO, &status), status == OPUS_OK else { throw failure(status) }
        defer { opus_encoder_destroy(encoder) }
        let lookahead = cassini_opus_lookahead(encoder)
        guard lookahead >= 0, cassini_opus_bitrate(encoder, 48_000) == OPUS_OK else { throw CassiniError("Cannot configure Opus encoder") }
        let preSkip = Int(lookahead)
        let head = Array("OpusHead".utf8) + [1, 1, UInt8(preSkip & 255), UInt8(preSkip >> 8), 0x80, 0xBB, 0, 0, 0, 0, 0]
        let sink = try FileSink(destination)
        defer { try? sink.close() }
        let muxer = try OggOpus.LiveMuxer(sink, head: head, tags: CassiniDocument.tagsPacket([]))
        var packet = [UInt8](repeating: 0, count: 4000), samples: Int64 = 0, encoded: Int64 = 0
        var ended = false
        while !ended {
            try Task.checkCancellation()
            var readError: Error?, conversionError: NSError?
            output.frameLength = 0
            let state = converter.convert(to: output, error: &conversionError) { requested, result in
                do {
                    guard input.framePosition < input.length else { result.pointee = .endOfStream; return nil }
                    try input.read(into: inputBuffer, frameCount: min(4096, requested, AVAudioFrameCount(input.length - input.framePosition)))
                    result.pointee = inputBuffer.frameLength == 0 ? .endOfStream : .haveData
                    return inputBuffer.frameLength == 0 ? nil : inputBuffer
                } catch { readError = error; result.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }; if let conversionError { throw conversionError }
            guard state != .error else { throw CassiniError("Audio conversion failed") }
            let count = Int(output.frameLength)
            ended = state == .endOfStream
            guard count > 0 else { if ended { break }; continue }
            samples += Int64(count)
            guard let pcm = output.floatChannelData?[0] else { throw CassiniError("Missing audio data") }
            for index in count..<960 { pcm[index] = 0 }
            let size = opus_encode_float(encoder, pcm, 960, &packet, Int32(packet.count))
            guard size > 0 else { throw failure(size) }
            try muxer.add(Array(packet.prefix(Int(size)))); encoded += 960
        }
        guard samples > 0 else { throw CassiniError("Audio is empty") }
        let silence = [Float](repeating: 0, count: 960)
        while encoded < samples + Int64(preSkip) {
            try Task.checkCancellation()
            let size = opus_encode_float(encoder, silence, 960, &packet, Int32(packet.count))
            guard size > 0 else { throw failure(size) }
            try muxer.add(Array(packet.prefix(Int(size)))); encoded += 960
        }
        try muxer.finish(finalGranule: samples + Int64(preSkip)); try sink.flush()
    }
    private static func failure(_ code: Int32) -> CassiniError { CassiniError("Opus: \(String(cString: opus_strerror(code)))") }
}
