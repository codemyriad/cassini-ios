import Foundation
import Observation

/// The one place app-wide errors are shown: one alert at a time, from the root, in the order they happened. Sheets
/// keep their own errors in local state.
@MainActor @Observable final class ErrorPresenter {
    struct PresentedError: Identifiable, Equatable {
        let id = UUID()
        let message: String
        /// Offer "Open Settings", e.g. when microphone access is off.
        let offersSettings: Bool
    }

    private(set) var current: PresentedError?
    @ObservationIgnored private var waiting: [PresentedError] = []

    func present(_ message: String, offersSettings: Bool = false) {
        let error = PresentedError(message: message, offersSettings: offersSettings)
        guard current?.message != message, !waiting.contains(where: { $0.message == message }) else { return }
        if current == nil { current = error } else { waiting.append(error) }
    }

    func dismiss(_ id: PresentedError.ID) {
        guard current?.id == id else { return }
        current = waiting.isEmpty ? nil : waiting.removeFirst()
    }
}

