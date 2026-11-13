import Foundation
import CassiniNotebook

/// The words of the transcribing status strip and details sheet, combining the shared Phase 1 catalog (`MeetingPhase1`)
/// and the Processing string table.
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

    /// The stepper row's visible label, from the shared Phase 1 catalog.
    static func step(_ step: JobStep) -> String {
        switch step {
        case .reading: MeetingPhase1Copy.stepReading
        case .preparing: MeetingPhase1Copy.stepPreparing
        case .words: MeetingPhase1Copy.stepWords
        case .speakers: MeetingPhase1Copy.stepSpeakers
        case .saving: MeetingPhase1Copy.stepSaving
        }
    }

    static func step(_ step: JobStep, language: String, bundle: Bundle = .main) -> String {
        let key = switch step {
        case .reading: "transcribing.step.reading"
        case .preparing: "transcribing.step.preparing"
        case .words: "transcribing.step.words"
        case .speakers: "transcribing.step.speakers"
        case .saving: "transcribing.step.saving"
        }
        return MeetingPhase1Copy.template(key, language: language, bundle: bundle)
    }

    /// "Step 3 of 5: Words", always matching the visible catalog step label.
    static func stepDescription(_ step: JobStep) -> String {
        let number = step.rawValue + 1, count = JobStep.allCases.count, name = Self.step(step)
        return String(localized: "Step \(number) of \(count): \(name)", table: "Processing")
    }

    static func stepDescription(_ step: JobStep, language: String, bundle: Bundle = .main) -> String {
        let locale = Locale(identifier: language)
        let localized = localizedBundle(language: language, bundle: bundle)
        let number = step.rawValue + 1, count = JobStep.allCases.count
        let name = Self.step(step, language: language, bundle: bundle)
        return String(localized: "Step \(number) of \(count): \(name)", table: "Processing",
                      bundle: localized, locale: locale)
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

    /// Compact continuation copy after `"Transcribing · "` on the status strip (`transcribing.eta.minutes` for whole
    /// minutes, existing localized continuations for calculating, finishing and sub-minute estimates).
    static func compactEta(_ timeLeft: TimeLeft) -> String {
        let locale = Locale.autoupdatingCurrent
        switch timeLeft {
        case .calculating:
            return continuation(String(localized: "Calculating time left…", table: "Processing"), locale: locale)
        case .finishing:
            return continuation(String(localized: "Finishing…", table: "Processing"), locale: locale)
        case .range:
            guard let span = timeLeft.minutes else {
                let under = noBreakAfterNumbers(String(localized: "Under 1 min left", table: "Processing"))
                return continuation(under, locale: locale)
            }
            let singular = span.lowerBound == 1 && span.upperBound == 1
            let count = formattedSpan(span, locale: locale)
            return MeetingPhase1Copy.etaMinutes(singular: singular, n: count)
        }
    }

    static func compactEta(_ timeLeft: TimeLeft, language: String, bundle: Bundle = .main) -> String {
        let locale = Locale(identifier: language)
        let localized = localizedBundle(language: language, bundle: bundle)
        switch timeLeft {
        case .calculating:
            let text = String(localized: "Calculating time left…", table: "Processing", bundle: localized, locale: locale)
            return continuation(text, locale: locale)
        case .finishing:
            let text = String(localized: "Finishing…", table: "Processing", bundle: localized, locale: locale)
            return continuation(text, locale: locale)
        case .range:
            guard let span = timeLeft.minutes else {
                let raw = String(localized: "Under 1 min left", table: "Processing", bundle: localized, locale: locale)
                return continuation(noBreakAfterNumbers(raw), locale: locale)
            }
            let singular = span.lowerBound == 1 && span.upperBound == 1
            let count = formattedSpan(span, locale: locale)
            let key = singular ? "transcribing.eta.minutes.one" : "transcribing.eta.minutes.other"
            return MeetingPhase1Copy.template(key, language: language, bundle: bundle)
                .replacingOccurrences(of: "{n}", with: count)
        }
    }

    /// The Time left stat in the details sheet: "6–9 min", "About 6 min", "Under 1 min", "1 h 10 min–1 h 30 min",
    /// "Calculating…", "Finishing…".
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

    /// Line 2 of the library's progress banner (WP9): "About 6–9 min left", "About 6 min left", "Under 1 min left",
    /// "Calculating time left…", "Finishing…".
    static func timeLeftLine(_ timeLeft: TimeLeft) -> String {
        switch timeLeft {
        case .calculating: return String(localized: "Calculating time left…", table: "Processing")
        case .finishing: return String(localized: "Finishing…", table: "Processing")
        case .range:
            guard let span = timeLeft.minutes else {
                return noBreakAfterNumbers(String(localized: "Under 1 min left", table: "Processing"))
            }
            let duration = if span.lowerBound == span.upperBound {
                hoursMinutes(span.lowerBound)
            } else if span.upperBound < 60 {
                noBreak(String(localized: "\(span.lowerBound)–\(span.upperBound) min", table: "Processing"))
            } else {
                hoursMinutes(span.lowerBound) + "–" + hoursMinutes(span.upperBound)
            }
            return String(localized: "About \(duration) left", table: "Processing")
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

    /// "62%".
    static func percent(_ value: Int) -> String { String(localized: "\(value)%", table: "Processing") }

    /// "29:52 of 48:13", the Audio done stat (`transcribing.stat.audioDoneValue`).
    static func audioDone(doneMs: Int64, totalMs: Int64) -> String {
        MeetingPhase1Copy.audioDoneValue(done: TimeText.clock(Double(doneMs) / 1000),
                                         total: TimeText.clock(Double(totalMs) / 1000))
    }

    static func audioDone(doneMs: Int64, totalMs: Int64, language: String, bundle: Bundle = .main) -> String {
        MeetingPhase1Copy.template("transcribing.stat.audioDoneValue", language: language, bundle: bundle)
            .replacingOccurrences(of: "{done}", with: TimeText.clock(Double(doneMs) / 1000))
            .replacingOccurrences(of: "{total}", with: TimeText.clock(Double(totalMs) / 1000))
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

    private static func formattedSpan(_ span: ClosedRange<Int64>, locale: Locale) -> String {
        let low = span.lowerBound.formatted(.number.locale(locale))
        let high = span.upperBound.formatted(.number.locale(locale))
        return span.lowerBound == span.upperBound ? high : "\(low)–\(high)"
    }

    private static func continuation(_ text: String, locale: Locale) -> String {
        guard let first = text.first else { return text }
        return String(first).lowercased(with: locale) + text.dropFirst()
    }

    private static func localizedBundle(language: String, bundle: Bundle) -> Bundle {
        let selected = Bundle.preferredLocalizations(from: bundle.localizations,
            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"
        return bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
    }

    private static func noBreak(_ text: String) -> String { text.replacingOccurrences(of: " ", with: "\u{00A0}") }

    /// A no-break space after each number, as in "Under 1\u{00A0}min left".
    private static func noBreakAfterNumbers(_ text: String) -> String {
        text.replacingOccurrences(of: #"(\d) "#, with: "$1\u{00A0}", options: .regularExpression)
    }
}
