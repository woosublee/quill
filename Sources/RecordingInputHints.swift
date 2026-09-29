import Foundation

/// Informational recording-overlay hints about the microphone (#214).
///
/// Hints only inform. They never stop, restart, or otherwise change the
/// recording, and they never carry user content (only fixed UI strings).
enum RecordingInputHint: Equatable {
    /// The microphone has picked up nothing since the recording started.
    case quiet
    /// The active microphone capture path stopped delivering audio buffers.
    case inputLost

    var messageKey: String {
        switch self {
        case .quiet:
            return "Are you talking? Your microphone isn't picking up any sound."
        case .inputLost:
            return "Microphone input stopped. Check the connection."
        }
    }

    var severity: RecordingNoticeSeverity {
        switch self {
        case .quiet:
            return .info
        case .inputLost:
            return .warning
        }
    }

    /// Only the input-lost warning is spoken by VoiceOver. The quiet hint is
    /// silent because a live-but-idle microphone would record the spoken
    /// phrase into the user's audio and transcript.
    var isAnnouncedToVoiceOver: Bool {
        self == .inputLost
    }
}

/// Decides when to show the one-time "Are you talking?" hint.
///
/// Levels are the normalized 0...1 display levels produced by
/// `LiveAudioLevelNormalizer` (the same values the overlay waveform draws).
struct RecordingQuietInputDetector {
    /// Levels at or below this count as "no sound". The normalizer gates the
    /// adaptive noise floor to exactly 0 and lifts any detected speech to at
    /// least 0.12 before smoothing (the first speech buffer already reaches
    /// about 0.054), so 0.04 separates silence from someone talking without
    /// reacting to residual smoothing tails near zero.
    static let nearSilentLevel: Float = 0.04
    /// How long the input must stay near silent from the start of the
    /// recording before the hint appears.
    static let quietDuration: TimeInterval = 10

    private var startedAt: TimeInterval?
    private(set) var hasHeardSound = false
    private(set) var hasShown = false
    private(set) var isShowing = false

    /// Starts the quiet window. A later call in the same recording (for
    /// example after switching to another microphone) gives the new input a
    /// fresh window, unless the hint was already shown or sound was heard.
    mutating func begin(at now: TimeInterval) {
        if startedAt == nil || (!hasShown && !hasHeardSound) {
            startedAt = now
        }
    }

    /// Any sound above the threshold hides the hint and disarms it for the
    /// rest of the recording.
    mutating func observeLevel(_ level: Float) {
        guard level > Self.nearSilentLevel else { return }
        hasHeardSound = true
        isShowing = false
    }

    @discardableResult
    mutating func evaluate(at now: TimeInterval) -> Bool {
        guard !hasHeardSound, !hasShown, let startedAt else { return isShowing }
        if now - startedAt >= Self.quietDuration {
            hasShown = true
            isShowing = true
        }
        return isShowing
    }
}

/// Detects sustained audio-buffer starvation on an active capture path.
///
/// The caller samples a monotonically increasing buffer counter. A counter
/// that changes (including a reset to zero after a restart) counts as
/// progress. Suspension (a capture-session interruption, an input switch, or
/// a system wake) restarts the grace window instead of accumulating time.
struct AudioBufferStarvationDetector {
    /// Time without any new buffer before the input-lost hint appears.
    static let starvationTimeout: TimeInterval = 5

    private var lastBufferCount: Int?
    private var lastProgressAt: TimeInterval?
    private(set) var isStarved = false

    mutating func rearm(at now: TimeInterval) {
        lastBufferCount = nil
        lastProgressAt = now
        isStarved = false
    }

    @discardableResult
    mutating func observe(
        bufferCount: Int,
        isSuspended: Bool,
        at now: TimeInterval
    ) -> Bool {
        guard !isSuspended, let lastProgressAt else {
            rearm(at: now)
            return false
        }
        guard let lastBufferCount else {
            // First sample after (re)arming is only a baseline.
            self.lastBufferCount = bufferCount
            return evaluateTimeout(since: lastProgressAt, now: now)
        }
        if bufferCount != lastBufferCount {
            self.lastBufferCount = bufferCount
            self.lastProgressAt = now
            isStarved = false
            return false
        }
        return evaluateTimeout(since: lastProgressAt, now: now)
    }

    private mutating func evaluateTimeout(
        since lastProgressAt: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        if now - lastProgressAt >= Self.starvationTimeout {
            isStarved = true
        }
        return isStarved
    }
}

/// Per-recording hint state. The input-lost warning takes precedence over the
/// quiet hint because missing buffers also look like silence.
struct RecordingInputHintState {
    let sessionID: UUID
    private(set) var quiet = RecordingQuietInputDetector()
    private(set) var starvation = AudioBufferStarvationDetector()

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    var currentHint: RecordingInputHint? {
        if starvation.isStarved { return .inputLost }
        if quiet.isShowing { return .quiet }
        return nil
    }

    /// Called when monitoring (re)starts on a capture path: a new input gets a
    /// fresh quiet window (still at most one hint per recording), and the
    /// starvation baseline starts over.
    mutating func resume(at now: TimeInterval) {
        quiet.begin(at: now)
        starvation.rearm(at: now)
    }

    /// Restarts only the starvation grace window (for example after wake).
    mutating func rearmStarvation(at now: TimeInterval) {
        starvation.rearm(at: now)
    }

    @discardableResult
    mutating func observeLevel(_ level: Float) -> RecordingInputHint? {
        quiet.observeLevel(level)
        return currentHint
    }

    @discardableResult
    mutating func tick(
        now: TimeInterval,
        bufferCount: Int,
        isCaptureSuspended: Bool
    ) -> RecordingInputHint? {
        starvation.observe(
            bufferCount: bufferCount,
            isSuspended: isCaptureSuspended,
            at: now
        )
        quiet.evaluate(at: now)
        return currentHint
    }
}
