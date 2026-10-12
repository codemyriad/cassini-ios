import Foundation
import CassiniNotebook

/// The words of the progress card, from the Processing string table: Android's copy, with Speakers & matching as the
/// iOS step after Words.
enum ProgressText {
    static func headline(_ headline: ProgressHeadline) -> String {
        switch headline {
        case .starting: String(localized: "Starting…", table: "Processing")
        case .waitingForPrevious: String(localized: "Finishing the previous note…", table: "Processing")
        case .readingAudio: String(localized: "Reading the audio", table: "Processing")
        case .preparing: String(localized: "Preparing", table: "Processing")
        case .findingWords: String(localized: "Finding words", table: "Processing")
        case .findingSpeakers: String(localized: "Finding speakers", table: "Processing")
        case .matchingVoices: String(localized: "Matching saved voices", table: "Processing")
        case .saving: String(localized: "Saving", table: "Processing")
        }
    }

    static let stopping = String(localized: "Stopping and keeping progress…", table: "Processing")
    static let downloadingModels = String(localized: "Downloading models", table: "Processing")

    /// The stepper column's label.
    static func step(_ step: JobStep) -> String {
        switch step {
        case .reading: String(localized: "Reading", table: "Processing")
        case .preparing: String(localized: "Preparing", table: "Processing")
        case .words: String(localized: "Words", table: "Processing")
        case .speakers: String(localized: "Speakers & matching", table: "Processing")
        case .saving: String(localized: "Saving", table: "Processing")
        }
    }

    /// "Step 3 of 5: Words".
    static func stepDescription(_ step: JobStep) -> String {
        let number = step.rawValue + 1, count = JobStep.allCases.count, name = Self.step(step)
        return String(localized: "Step \(number) of \(count): \(name)", table: "Processing")
    }

    enum StepState { case done, inProgress, notStarted, skipped }

    static func stepState(_ state: StepState) -> String {
        switch state {
        case .done: String(localized: "done", table: "Processing")
        case .inProgress: String(localized: "in progress", table: "Processing")
        case .notStarted: String(localized: "not started", table: "Processing")
        case .skipped: String(localized: "skipped", table: "Processing")
        }
    }

    /// The Time left stat: "6–9 min", "About 6 min", "Under 1 min", "1 h 10 min–1 h 30 min", "Calculating…",
    /// "Finishing…".
    static func timeLeft(_ timeLeft: TimeLeft) -> String {
        switch timeLeft {
        case .calculating: return String(localized: "Calculating…", table: "Processing")
        case .finishing: return String(localized: "Finishing…", table: "Processing")
        case .range:
            guard let span = timeLeft.minutes else {
                return noBreak(String(localized: "Under 1 min", table: "Processing"))
            }
            if span.lowerBound == span.upperBound {
                let duration = hoursMinutes(span.lowerBound)
                return String(localized: "About \(duration)", table: "Processing")
            }
            if span.upperBound < 60 {
                let low = span.lowerBound, high = span.upperBound
                return noBreak(String(localized: "\(low)–\(high) min", table: "Processing"))
            }
            return hoursMinutes(span.lowerBound) + "–" + hoursMinutes(span.upperBound)
        }
    }

    /// The Battery at finish stat: "54% → about 41%", "Plugged in", "Measuring…"; nil when hidden.
    static func battery(_ battery: BatteryLine) -> String? {
        switch battery {
        case .unavailable: nil
        case .measuring: String(localized: "Measuring…", table: "Processing")
        case .pluggedIn: String(localized: "Plugged in", table: "Processing")
        case .projected(let now, let atFinish): String(localized: "\(now)% → about \(atFinish)%", table: "Processing")
        }
    }

    /// "29:52 / 48:13", the Processed stat.
    static func processed(doneMs: Int64, totalMs: Int64) -> String {
        TimeText.clock(Double(doneMs) / 1000) + " / " + TimeText.clock(Double(totalMs) / 1000)
    }

    /// "29:00–29:45", the audio the headline's stage works on.
    static func range(startMs: Int64, endMs: Int64) -> String {
        TimeText.clock(Double(startMs) / 1000) + "–" + TimeText.clock(Double(endMs) / 1000)
    }

    /// "6 min", "1 h", "1 h 10 min", with no-break spaces.
    static func hoursMinutes(_ minutes: Int64) -> String {
        let hours = minutes / 60, rest = minutes % 60
        let text = if hours == 0 {
            String(localized: "\(rest) min", table: "Processing")
        } else if rest == 0 {
            String(localized: "\(hours) h", table: "Processing")
        } else {
            String(localized: "\(hours) h \(rest) min", table: "Processing")
        }
        return noBreak(text)
    }

    private static func noBreak(_ text: String) -> String { text.replacingOccurrences(of: " ", with: "\u{00A0}") }
}
