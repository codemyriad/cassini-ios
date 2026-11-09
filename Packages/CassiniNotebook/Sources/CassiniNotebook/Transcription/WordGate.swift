import CassiniCore
import Foundation

extension Word {
    func with(startMs: Int64? = nil, endMs: Int64? = nil) -> Word {
        Word(speaker, startMs ?? self.startMs, endMs ?? self.endMs, text, lowConfidenceSpeaker: lowConfidenceSpeaker)
    }
}

/// What happens to decoded words before they become transcript words: they move onto the
/// recording clock, synthetic padding is clipped off, and the energy gate decides against the
/// speaker's own samples both whether a word is real and how far it reaches. Samples are at the
/// recording's own rate, so every duration here is converted with that rate, never with 16 kHz.
///
/// The gate measures AC level (D26.1): it takes the DC off before measuring. A microphone with an offset as small as
/// `minActive` would otherwise make every sample of the recording active. The DC is the mean of at least
/// `dcContextMs` around the word, so a click of a few samples cannot move it far enough to make silence active.
public enum WordGate {
    /// -60 dBFS peak, -80 dBFS RMS and 5 ms at or above -66 dBFS: rejects silence and lone clicks, keeps quiet acknowledgements.
    public static let minPeak: Float = 0.001
    public static let minRms = 0.0001
    public static let minActive: Float = 0.0005
    public static let minActiveMs = 5
    /// Parakeet has placed a word up to 180 ms before its PCM; the margins absorb that jitter.
    public static let preMarginMs: Int64 = 100
    public static let postMarginMs: Int64 = 200
    /// One 10 ms feature frame, twice `minActiveMs`, so a single sample cannot win or lose a window.
    public static let scanWindowMs: Int64 = 10
    /// A silence shorter than this is a closure inside the word; a longer one is the next turn's pause.
    public static let gapToleranceMs: Int64 = postMarginMs
    /// The least audio the DC is measured over: a full-scale sample moves its mean by under a tenth of `minActive`.
    public static let dcContextMs: Int64 = 1000
    /// A smaller DC is left on: on its own it cannot make a silent sample active, and speech's own mean over a second
    /// stays under it (FLEURS-it short: at most 1.7e-4). So a recording without an offset is gated exactly as Android
    /// gates it, and an offset from 8 LSB up is taken off.
    public static let minDC: Float = minActive / 2

    /// Removes decoder head padding, then puts words and their caps on the recording clock.
    public static func offsetDecoderWords(_ words: [DecodedWord], offsetMs: Int64, headPaddingMs: Int64) -> [DecodedWord] {
        words.map { timed in
            var word = timed.word
            var cap = timed.capMs
            if headPaddingMs > 0 {
                word = word.with(startMs: max(0, word.startMs - headPaddingMs), endMs: max(0, word.endMs - headPaddingMs))
                cap = max(0, cap - headPaddingMs)
            }
            return DecodedWord(word.with(startMs: word.startMs + offsetMs, endMs: word.endMs + offsetMs), capMs: cap + offsetMs)
        }
    }

    /// Strict overlap, so a word ending exactly at the span start belongs to the previous span, not this one.
    public static func wordsOverlappingSpeech(_ words: [DecodedWord], startMs: Int64, endMs: Int64) -> [DecodedWord] {
        words.filter { $0.word.startMs < endMs && $0.word.endMs > startMs }
    }

    /// Clips words straddling the real PCM end. A word stamped at the end or inside the `paddedTailMs`
    /// of synthetic padding becomes zero-length at the end, so the gate can judge the real audio before
    /// it; one starting past the padding, or reversed, is dropped. Neither ends nor caps reach into padding.
    public static func clampWordsToTimelineEnd(_ words: [DecodedWord], endMs: Int64, paddedTailMs: Int64) -> [DecodedWord] {
        let (sum, overflow) = endMs.addingReportingOverflow(max(0, paddedTailMs))
        let paddedEndMs = overflow || sum < endMs ? Int64.max : sum
        return words.compactMap { timed in
            let word = timed.word
            if word.endMs < word.startMs || word.startMs > paddedEndMs { return nil }
            let clamped: Word
            if word.startMs >= endMs { clamped = word.with(startMs: endMs, endMs: endMs) }
            else if word.endMs > endMs { clamped = word.with(endMs: endMs) }
            else { clamped = word }
            return DecodedWord(clamped, capMs: min(timed.capMs, endMs))
        }
    }

    public static func finalizeTranscriptWords(_ samples: [Float], sampleRate: Int, words: [DecodedWord], audioEndMs: Int64,
                                               paddedTailMs: Int64) -> [Word] {
        filterWordsByEnergy(samples, sampleRate: sampleRate, words: clampWordsToTimelineEnd(words, endMs: audioEndMs, paddedTailMs: paddedTailMs))
    }

    public static func finalizeTranscriptWords(_ audio: PcmAudio, words: [DecodedWord], paddedTailMs: Int64) -> [Word] {
        finalizeTranscriptWords(audio.samples, sampleRate: audio.sampleRate, words: words, audioEndMs: audio.durationMs,
                                paddedTailMs: paddedTailMs)
    }

    /// Drops words whose margin-widened interval is silence or a click, and extends each kept word over
    /// its speaker's continuing audio up to its cap, because Parakeet's 320 ms duration head stops a long
    /// word's last token short of the sound. The cap is consumed here: kept words come back plain.
    /// Without samples or a sample rate nothing can be measured, so words pass through unchanged.
    public static func filterWordsByEnergy(_ samples: [Float], sampleRate: Int, words: [DecodedWord]) -> [Word] {
        if words.isEmpty || samples.isEmpty || sampleRate <= 0 { return words.map(\.word) }
        let rate = Int64(sampleRate)
        let audioEndMs = Int64(samples.count) * 1000 / rate
        let minimumActiveSamples = (sampleRate * minActiveMs + 999) / 1000
        return samples.withUnsafeBufferPointer { buffer in
            words.compactMap { timed -> Word? in
                let word = timed.word
                if word.endMs < 0 || word.endMs < word.startMs || word.startMs > audioEndMs { return nil }
                var startMs = max(0, word.startMs)
                var endMs = min(audioEndMs, word.endMs)
                startMs = startMs > preMarginMs ? startMs - preMarginMs : 0
                endMs = endMs < audioEndMs - postMarginMs ? endMs + postMarginMs : audioEndMs
                let start = Int(startMs * rate / 1000)
                let end = Int(min(Int64(buffer.count), (endMs * rate + 999) / 1000))
                if end <= start { return nil }
                let dc = dc(buffer, start, end, sampleRate: sampleRate)
                var peak: Float = 0
                var squareSum = 0.0
                var active = 0
                for i in start..<end {
                    let sample = buffer[i] - dc
                    squareSum += Double(sample) * Double(sample)
                    let magnitude = sample < 0 ? -sample : sample
                    if magnitude >= minActive { active += 1 }
                    if magnitude > peak { peak = magnitude }
                }
                let meanSquare = squareSum / Double(end - start)
                guard peak >= minPeak, meanSquare >= minRms * minRms, active >= minimumActiveSamples else { return nil }
                return word.with(endMs: wordEndOverContinuingAudio(buffer, sampleRate: sampleRate, timed: timed, audioEndMs: audioEndMs,
                                                                   dc: dc))
            }
        }
    }

    /// Walks `scanWindowMs` windows from the word's end towards its cap while its speaker's audio
    /// continues, bridging gaps shorter than `gapToleranceMs`. The end lands on the last active
    /// window: never past the cap, so never past the punctuation-inclusive end, and never before the
    /// word's own end, so no speech is cut. Silence right after the word leaves its end alone.
    public static func wordEndOverContinuingAudio(_ samples: [Float], sampleRate: Int, timed: DecodedWord, audioEndMs: Int64) -> Int64 {
        samples.withUnsafeBufferPointer { buffer in
            guard sampleRate > 0, !buffer.isEmpty else { return timed.word.endMs }
            let rate = Int64(sampleRate)
            let from = Int(min(max(0, timed.word.endMs) * rate / 1000, Int64(buffer.count - 1)))
            let to = Int(min(max(0, min(timed.extentCapMs, audioEndMs)) * rate / 1000, Int64(buffer.count)))
            return wordEndOverContinuingAudio(buffer, sampleRate: sampleRate, timed: timed, audioEndMs: audioEndMs,
                                              dc: dc(buffer, from, max(from + 1, to), sampleRate: sampleRate))
        }
    }

    /// The scan with the DC `dc` taken off every sample: the word's, measured once over at least `dcContextMs`.
    private static func wordEndOverContinuingAudio(_ samples: UnsafeBufferPointer<Float>, sampleRate: Int, timed: DecodedWord,
                                                   audioEndMs: Int64, dc: Float) -> Int64 {
        let end = timed.word.endMs
        let capMs = min(timed.extentCapMs, audioEndMs)
        if capMs <= end || sampleRate <= 0 { return end }
        let rate = Int64(sampleRate)
        let windowSamples = Int((rate * scanWindowMs + 999) / 1000)
        if windowSamples <= 0 { return end }
        let minimumActiveSamples = (sampleRate * minActiveMs + 999) / 1000
        var lastActiveMs: Int64 = -1
        var at = end
        while at < capMs {
            let start = at * rate / 1000
            let stop = min(start + Int64(windowSamples), Int64(samples.count))
            if start < 0 || start >= stop { break }
            var active = 0
            for i in Int(start)..<Int(stop) {
                let sample = samples[i] - dc
                if (sample < 0 ? -sample : sample) >= minActive { active += 1 }
            }
            if active >= minimumActiveSamples {
                lastActiveMs = at + scanWindowMs
            } else if at - (lastActiveMs < 0 ? end : lastActiveMs) >= gapToleranceMs {
                break
            }
            at += scanWindowMs
        }
        if lastActiveMs < 0 { return end }
        return max(min(lastActiveMs, capMs), end)
    }

    /// The DC around `samples[start..<end]`: the mean of that stretch widened evenly to at least `dcContextMs`, kept
    /// inside the samples (all of them when they are shorter), or 0 when it is under `minDC`.
    private static func dc(_ samples: UnsafeBufferPointer<Float>, _ start: Int, _ end: Int, sampleRate: Int) -> Float {
        let context = Int(Int64(sampleRate) * dcContextMs / 1000)
        var from = start, to = end
        if to - from < context {
            let widen = context - (to - from)
            from -= widen / 2
            to += widen - widen / 2
            if from < 0 { to -= from; from = 0 }
            if to > samples.count { from -= to - samples.count; to = samples.count }
            from = max(0, from)
        }
        var sum = 0.0
        for i in from..<to { sum += Double(samples[i]) }
        let mean = Float(sum / Double(to - from))
        return abs(mean) < minDC ? 0 : mean
    }
}
