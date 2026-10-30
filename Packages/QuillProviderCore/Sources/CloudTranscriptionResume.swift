/// What a saved transcription job was made with, for deciding whether it can
/// pick up from its saved chunks under the current settings
/// (`CloudTranscriptionResumeDecision`), the same on the Mac and the iPhone.
/// Cloud and local AI jobs both use it.
///
/// Each app fills one identity for the saved job and one for the current
/// settings, and the rule compares them field by field. A field an app does
/// not track stays nil on both sides, so it always matches.
public struct CloudTranscriptionResumeIdentity: Equatable, Sendable {
    /// The provider or local engine, such as a hash of the provider URL or a
    /// local model package digest.
    public let providerID: String
    public let model: String
    /// The transcription language sent to the model; nil is automatic.
    public let language: String?
    public let responseFormat: String
    public let plan: CloudTranscriptionResumePlan
    /// What happens to the text afterwards. Only a user retry compares it:
    /// a startup resume finishes with the job's saved follow-up.
    public let followUp: CloudTranscriptionResumeFollowUp?

    public init(
        providerID: String,
        model: String,
        language: String?,
        responseFormat: String,
        plan: CloudTranscriptionResumePlan = CloudTranscriptionResumePlan(),
        followUp: CloudTranscriptionResumeFollowUp? = nil
    ) {
        self.providerID = providerID
        self.model = model
        self.language = language
        self.responseFormat = responseFormat
        self.plan = plan
        self.followUp = followUp
    }

    /// Everything but the follow-up.
    func sameTranscription(as other: Self) -> Bool {
        providerID == other.providerID
            && model == other.model
            && language == other.language
            && responseFormat == other.responseFormat
            && plan == other.plan
    }
}

/// How the audio is cut into chunks. Every field is optional so each app
/// fills the ones its planner has; a different value means the saved chunks
/// no longer line up with a new plan.
///
/// A nil field means "not tracked", never a real value such as a default.
public struct CloudTranscriptionResumePlan: Equatable, Sendable {
    /// The chunking algorithm's version.
    public let algorithmVersion: Int?
    /// How a chunk's size is measured, such as `rawWAV`.
    public let sizing: String?
    /// The most bytes one chunk may take.
    public let ceilingBytes: UInt64?
    /// How far back from a chunk's end to look for a quiet cut.
    public let silenceSearchFrameCount: UInt64?

    public init(
        algorithmVersion: Int? = nil,
        sizing: String? = nil,
        ceilingBytes: UInt64? = nil,
        silenceSearchFrameCount: UInt64? = nil
    ) {
        self.algorithmVersion = algorithmVersion
        self.sizing = sizing
        self.ceilingBytes = ceilingBytes
        self.silenceSearchFrameCount = silenceSearchFrameCount
    }
}

/// What runs on the finished transcript.
public struct CloudTranscriptionResumeFollowUp: Equatable, Sendable {
    public let postProcessingEnabled: Bool
    public let outputLanguage: String
    /// The Mac's press-Enter voice command; false where there is none.
    public let pressEnterCommandEnabled: Bool

    public init(
        postProcessingEnabled: Bool,
        outputLanguage: String,
        pressEnterCommandEnabled: Bool
    ) {
        self.postProcessingEnabled = postProcessingEnabled
        self.outputLanguage = outputLanguage
        self.pressEnterCommandEnabled = pressEnterCommandEnabled
    }
}

/// Who is asking to run a saved job.
public enum CloudTranscriptionResumeOrigin: Equatable, Sendable {
    /// The app is starting and found unfinished work. Nothing is thrown away.
    case startup
    /// The user asked to try again, so the current settings win.
    case userRetry
}

/// What to do with a saved job.
public enum CloudTranscriptionResumeDecision: Equatable, Sendable {
    /// Continue from the saved chunks.
    case resume
    /// Drop the saved chunks and transcribe again with the current settings.
    case startOver
    /// Leave the saved job alone until the user retries.
    case wait

    /// Decides for a saved job against the current settings.
    ///
    /// At startup a job resumes only when its transcription matches the
    /// current settings exactly; otherwise it waits. A user retry resumes
    /// when the transcription and the follow-up both match, and otherwise
    /// starts over, so a retry never waits.
    ///
    /// Whether anything can run the job now (an API key, a local engine) is
    /// the caller's check: a startup with nothing to run it leaves the job
    /// waiting without asking.
    public static func decide(
        saved: CloudTranscriptionResumeIdentity,
        current: CloudTranscriptionResumeIdentity,
        origin: CloudTranscriptionResumeOrigin
    ) -> Self {
        switch origin {
        case .startup:
            return saved.sameTranscription(as: current) ? .resume : .wait
        case .userRetry:
            return saved == current ? .resume : .startOver
        }
    }
}
