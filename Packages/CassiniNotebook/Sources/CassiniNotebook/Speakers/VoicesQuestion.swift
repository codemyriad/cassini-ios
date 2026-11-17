/// The one-time question belongs over a visible meeting with actual speech from multiple people.
/// `writable` refers to the saved-voices store; a live draft can ask while its note is processing.
public enum VoicesQuestion {
    public static func shouldAsk(answered: Bool, speakerCount: Int?, visible: Bool,
                                 writable: Bool, overlayReady: Bool, obstructed: Bool) -> Bool {
        !answered && (speakerCount ?? 0) > 1 && visible && writable && overlayReady && !obstructed
    }
}
