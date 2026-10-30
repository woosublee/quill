import Foundation
import QuillProviderCore

// The Mac's side of the shared resume rule (`CloudTranscriptionResumeDecision`).
// Each check fills only the plan fields it has always compared, and the saved
// record fills the same ones, so the comparison stays field for field what it
// was before the rule moved to QuillProviderCore.

extension CloudTranscriptionCompletionPolicy {
    var resumeFollowUp: CloudTranscriptionResumeFollowUp {
        CloudTranscriptionResumeFollowUp(
            postProcessingEnabled: postProcessingEnabled,
            outputLanguage: outputLanguage,
            pressEnterCommandEnabled: pressEnterCommandEnabled
        )
    }
}

extension CloudTranscriptionJobRecord {
    /// Decides for this saved job against `current`.
    func resumeDecision(
        current: CloudTranscriptionResumeIdentity,
        origin: CloudTranscriptionResumeOrigin
    ) -> CloudTranscriptionResumeDecision {
        CloudTranscriptionResumeDecision.decide(
            saved: resumeIdentity(comparedWith: current),
            current: current,
            origin: origin
        )
    }

    /// The saved side, filling a plan field only where `current` fills it.
    /// The follow-up is always filled; only a user retry compares it.
    func resumeIdentity(
        comparedWith current: CloudTranscriptionResumeIdentity
    ) -> CloudTranscriptionResumeIdentity {
        let wanted = current.plan
        return CloudTranscriptionResumeIdentity(
            providerID: identity.providerID,
            model: identity.model,
            language: identity.language,
            responseFormat: identity.responseFormat,
            plan: CloudTranscriptionResumePlan(
                algorithmVersion: wanted.algorithmVersion == nil
                    ? nil : plan.algorithmVersion,
                sizing: wanted.sizing == nil ? nil : plan.sizing?.rawValue,
                ceilingBytes: wanted.ceilingBytes == nil
                    ? nil : plan.encodedUploadCeilingBytes,
                silenceSearchFrameCount: wanted.silenceSearchFrameCount == nil
                    ? nil : plan.silenceSearchFrameCount
            ),
            followUp: completionPolicy.resumeFollowUp
        )
    }
}

extension CloudTranscriptionExecutionSnapshot {
    /// At startup a cloud job also needs the current chunking version and
    /// upload ceiling.
    var startupResumeIdentity: CloudTranscriptionResumeIdentity {
        CloudTranscriptionResumeIdentity(
            providerID: providerID,
            model: model,
            language: language,
            responseFormat: responseFormat,
            plan: CloudTranscriptionResumePlan(
                algorithmVersion: CloudTranscriptionChunkPlan.currentAlgorithmVersion,
                ceilingBytes: encodedUploadCeilingBytes
            )
        )
    }

    /// A user's cloud retry compares the upload ceiling and the follow-up.
    func retryResumeIdentity(
        completion: CloudTranscriptionCompletionPolicy
    ) -> CloudTranscriptionResumeIdentity {
        CloudTranscriptionResumeIdentity(
            providerID: providerID,
            model: model,
            language: language,
            responseFormat: responseFormat,
            plan: CloudTranscriptionResumePlan(
                ceilingBytes: encodedUploadCeilingBytes
            ),
            followUp: completion.resumeFollowUp
        )
    }
}

extension LocalAITranscriptionResumeIdentity {
    /// At startup a local AI job needs the current chunking version, raw WAV
    /// sizing, chunk ceiling, and silence search.
    var startupResumeIdentity: CloudTranscriptionResumeIdentity {
        CloudTranscriptionResumeIdentity(
            providerID: providerID,
            model: model,
            language: language,
            responseFormat: responseFormat,
            plan: CloudTranscriptionResumePlan(
                algorithmVersion: CloudTranscriptionChunkPlan.currentAlgorithmVersion,
                sizing: TranscriptionChunkSizingKind.rawWAV.rawValue,
                ceilingBytes: ceilingBytes,
                silenceSearchFrameCount: silenceSearchFrameCount
            )
        )
    }
}

extension LocalAITranscriptionExecutionSnapshot {
    /// A user's local AI retry compares raw WAV sizing and the follow-up.
    func retryResumeIdentity(
        language: String?,
        completion: CloudTranscriptionCompletionPolicy
    ) -> CloudTranscriptionResumeIdentity {
        CloudTranscriptionResumeIdentity(
            providerID: providerID,
            model: modelID,
            language: language,
            responseFormat: requestFormat.rawValue,
            plan: CloudTranscriptionResumePlan(
                sizing: TranscriptionChunkSizingKind.rawWAV.rawValue
            ),
            followUp: completion.resumeFollowUp
        )
    }
}
