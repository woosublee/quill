import Foundation
import QuillProviderCore

/// The shared rule for whether a saved transcription job resumes, starts
/// over, or waits. Synthetic identities only.
@main
struct CloudTranscriptionResumeDecisionTests {
    static func main() {
        do {
            try matchingJobResumesFromEitherOrigin()
            try startupMismatchWaitsAndRetryMismatchStartsOver()
            try onlyARetryComparesTheFollowUp()
            try fieldsNeitherSideFillsAlwaysMatch()
            try aFieldOnlyOneSideFillsIsAMismatch()
            print("CloudTranscriptionResumeDecisionTests passed")
        } catch {
            fputs("CloudTranscriptionResumeDecisionTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expectEqual(
        _ actual: CloudTranscriptionResumeDecision,
        _ expected: CloudTranscriptionResumeDecision,
        _ message: String
    ) throws {
        guard actual == expected else {
            throw Failure(description: "\(message): \(actual) != \(expected)")
        }
    }

    static let plan = CloudTranscriptionResumePlan(
        algorithmVersion: 1,
        sizing: "rawWAV",
        ceilingBytes: 1_920_044,
        silenceSearchFrameCount: 320_000
    )
    static let followUp = CloudTranscriptionResumeFollowUp(
        postProcessingEnabled: true,
        outputLanguage: "en",
        pressEnterCommandEnabled: false
    )

    static func job(
        providerID: String = "provider-a",
        model: String = "model-a",
        language: String? = "en",
        responseFormat: String = "json",
        plan: CloudTranscriptionResumePlan = plan,
        followUp: CloudTranscriptionResumeFollowUp? = followUp
    ) -> CloudTranscriptionResumeIdentity {
        CloudTranscriptionResumeIdentity(
            providerID: providerID,
            model: model,
            language: language,
            responseFormat: responseFormat,
            plan: plan,
            followUp: followUp
        )
    }

    static func decide(
        _ saved: CloudTranscriptionResumeIdentity,
        _ current: CloudTranscriptionResumeIdentity,
        _ origin: CloudTranscriptionResumeOrigin
    ) -> CloudTranscriptionResumeDecision {
        CloudTranscriptionResumeDecision.decide(
            saved: saved,
            current: current,
            origin: origin
        )
    }

    static func matchingJobResumesFromEitherOrigin() throws {
        try expectEqual(decide(job(), job(), .startup), .resume, "startup match")
        try expectEqual(decide(job(), job(), .userRetry), .resume, "retry match")
    }

    static func startupMismatchWaitsAndRetryMismatchStartsOver() throws {
        let mismatches: [(String, CloudTranscriptionResumeIdentity)] = [
            ("provider", job(providerID: "provider-b")),
            ("model", job(model: "model-b")),
            ("language", job(language: "ko")),
            ("automatic language", job(language: nil)),
            ("response format", job(responseFormat: "text")),
            ("algorithm", job(plan: CloudTranscriptionResumePlan(
                algorithmVersion: 2,
                sizing: plan.sizing,
                ceilingBytes: plan.ceilingBytes,
                silenceSearchFrameCount: plan.silenceSearchFrameCount
            ))),
            ("sizing", job(plan: CloudTranscriptionResumePlan(
                algorithmVersion: plan.algorithmVersion,
                sizing: "multipart",
                ceilingBytes: plan.ceilingBytes,
                silenceSearchFrameCount: plan.silenceSearchFrameCount
            ))),
            ("ceiling", job(plan: CloudTranscriptionResumePlan(
                algorithmVersion: plan.algorithmVersion,
                sizing: plan.sizing,
                ceilingBytes: 1_000,
                silenceSearchFrameCount: plan.silenceSearchFrameCount
            ))),
            ("silence", job(plan: CloudTranscriptionResumePlan(
                algorithmVersion: plan.algorithmVersion,
                sizing: plan.sizing,
                ceilingBytes: plan.ceilingBytes,
                silenceSearchFrameCount: 48_000
            ))),
        ]
        for (name, current) in mismatches {
            try expectEqual(decide(job(), current, .startup), .wait, "startup \(name) waits")
            try expectEqual(decide(job(), current, .userRetry), .startOver, "retry \(name) starts over")
        }
    }

    static func onlyARetryComparesTheFollowUp() throws {
        let other = CloudTranscriptionResumeFollowUp(
            postProcessingEnabled: false,
            outputLanguage: "en",
            pressEnterCommandEnabled: false
        )
        try expectEqual(decide(job(), job(followUp: other), .startup), .resume, "startup keeps the saved follow-up")
        try expectEqual(decide(job(), job(followUp: nil), .startup), .resume, "startup needs no current follow-up")
        try expectEqual(decide(job(), job(followUp: other), .userRetry), .startOver, "retry with another follow-up")
    }

    static func fieldsNeitherSideFillsAlwaysMatch() throws {
        let bare = job(plan: CloudTranscriptionResumePlan(), followUp: nil)
        try expectEqual(decide(bare, bare, .startup), .resume, "empty plan at startup")
        try expectEqual(decide(bare, bare, .userRetry), .resume, "empty plan on retry")
    }

    static func aFieldOnlyOneSideFillsIsAMismatch() throws {
        let unsized = job(plan: CloudTranscriptionResumePlan(
            algorithmVersion: plan.algorithmVersion,
            ceilingBytes: plan.ceilingBytes,
            silenceSearchFrameCount: plan.silenceSearchFrameCount
        ))
        try expectEqual(decide(unsized, job(), .startup), .wait, "saved without sizing waits")
        try expectEqual(decide(job(), unsized, .userRetry), .startOver, "current without sizing starts over")
        try expectEqual(decide(job(), job(followUp: nil), .userRetry), .startOver, "retry missing a follow-up")
    }
}
