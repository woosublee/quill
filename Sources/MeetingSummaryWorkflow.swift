import Foundation
import QuillAITextCore
import QuillUserIssueCore
import QuillSummaryFormatCore
import QuillSummaryGenerationCore

struct MeetingSummaryGeneratorConfiguration: Sendable {
    let backendExecutor: AIProcessingBackendExecutor
    let fallbackExecutor: AIProcessingBackendExecutor?
}

struct MeetingSummaryWorkflowDependencies {
    var makeGenerator:
        @MainActor (MeetingSummaryGeneratorConfiguration)
            -> any MeetingSummaryGenerating
    var now: @Sendable () -> Date
}

struct MeetingSummaryWorkflowRequest {
    let noteID: UUID
    let initialItem: PipelineHistoryItem
    let requestedOutputLanguage: String
    let configuredBackendKind: MeetingSummaryBackendKind
    let configuredModelID: String
    let providerHost: String?
    let generatorConfiguration: MeetingSummaryGeneratorConfiguration
    /// Keeps a successful result as a candidate instead of saving it, so the
    /// person can compare it with an edited summary first (#262).
    var deliversCandidate = false
}

/// A newly generated summary waiting for the person to keep it or not.
struct MeetingSummaryCandidate: Equatable, Sendable {
    let envelope: MeetingSummaryEnvelope
    let attempt: MeetingSummaryAttempt
}

struct MeetingSummaryHistoryAccess {
    var durability:
        @MainActor @Sendable () -> PipelineHistoryDurability
    var item:
        @MainActor @Sendable (UUID) throws -> PipelineHistoryItem?
    var persist:
        @MainActor @Sendable (PipelineHistoryItem, Bool) throws -> Void
}

struct MeetingSummaryWorkflowState: Equatable, Sendable {
    var generatingNoteIDs: Set<UUID>
    var pendingRevealNoteIDs: Set<UUID>
    var candidates: [UUID: MeetingSummaryCandidate]
    /// Notes whose new summary had the same text as the saved one, with
    /// when that summary was made, so the Summary tab can say so.
    var unchangedSummaries: [UUID: Date]

    static let initial = MeetingSummaryWorkflowState(
        generatingNoteIDs: [],
        pendingRevealNoteIDs: [],
        candidates: [:],
        unchangedSummaries: [:]
    )
}

enum MeetingSummaryWorkflowEvent {
    case stateChanged(MeetingSummaryWorkflowState)
    case itemPersisted(PipelineHistoryItem)
}

enum MeetingSummaryWorkflowOutcome {
    case verifiedSuccess
    case unverifiedSuccess
    case invalidInput
    case sourceChanged
    case generationFailed(Error)
    case persistenceFailed
}

private enum MeetingSummaryCurrentItemValidation {
    case current(PipelineHistoryItem)
    case stale
    case persistenceFailed
}

final class MeetingSummaryWorkflow: @unchecked Sendable {
    private let dependencies: MeetingSummaryWorkflowDependencies
    @MainActor private var generationRevisionByID: [UUID: Int] = [:]
    @MainActor private(set) var state = MeetingSummaryWorkflowState.initial
    nonisolated(unsafe) var onEvent:
        (@MainActor (MeetingSummaryWorkflowEvent) -> Void)?

    init(dependencies: MeetingSummaryWorkflowDependencies) {
        self.dependencies = dependencies
    }

    @MainActor
    func generate(
        request: MeetingSummaryWorkflowRequest,
        history: MeetingSummaryHistoryAccess
    ) async -> MeetingSummaryWorkflowOutcome {
        guard history.durability() == .durable else {
            return .persistenceFailed
        }
        let initialItem = request.initialItem
        let initialFingerprint = Self.availabilitySource(
            for: initialItem
        ).fingerprint

        let generationRevision = generationRevisionByID[
            request.noteID,
            default: 0
        ]
        generationRevisionByID[request.noteID] = generationRevision
        state.generatingNoteIDs.insert(request.noteID)
        state.candidates.removeValue(forKey: request.noteID)
        state.unchangedSummaries.removeValue(forKey: request.noteID)
        emitState()

        let transcript = Self.transcript(for: initialItem)
        let resolvedLanguage: (
            context: MeetingSummaryLanguageContext,
            resolvedSpokenLanguage: SpokenLanguageResolution?
        )
        do {
            resolvedLanguage = try Self.resolvedLanguage(
                for: initialItem,
                transcript: transcript,
                requestedOutputLanguage: request.requestedOutputLanguage
            )
        } catch {
            return persistFailure(
                error,
                request: request,
                history: history,
                revision: generationRevision,
                languageContext: nil,
                sourceFingerprint: initialFingerprint
            )
        }

        var sourceItem = initialItem
        if let spokenLanguage = resolvedLanguage.resolvedSpokenLanguage {
            let currentItem: PipelineHistoryItem
            switch validateCurrentItem(
                noteID: request.noteID,
                revision: generationRevision,
                sourceFingerprint: initialFingerprint,
                history: history
            ) {
            case .current(let item):
                currentItem = item
            case .stale:
                finishGeneration(
                    noteID: request.noteID,
                    revision: generationRevision
                )
                return .sourceChanged
            case .persistenceFailed:
                finishGeneration(
                    noteID: request.noteID,
                    revision: generationRevision
                )
                return .persistenceFailed
            }
            let updated = currentItem.withSpokenLanguage(spokenLanguage)
            do {
                try history.persist(updated, true)
            } catch {
                finishGeneration(
                    noteID: request.noteID,
                    revision: generationRevision
                )
                return .persistenceFailed
            }
            onEvent?(.itemPersisted(updated))
            sourceItem = updated
        }

        let source = Self.source(
            for: sourceItem,
            languageContext: resolvedLanguage.context
        )
        // Reused for the failure record, the stale check, the envelope, and
        // the attempt below instead of hashing the transcript for each.
        let sourceFingerprint = source.fingerprint
        let generator = dependencies.makeGenerator(
            request.generatorConfiguration
        )
        let result: MeetingSummaryGenerationResult
        do {
            result = try await generator.generate(source: source)
        } catch {
            return persistFailure(
                error,
                request: request,
                history: history,
                revision: generationRevision,
                languageContext: source.languageContext,
                sourceFingerprint: sourceFingerprint
            )
        }

        let currentItem: PipelineHistoryItem
        switch validateCurrentItem(
            noteID: request.noteID,
            revision: generationRevision,
            sourceFingerprint: sourceFingerprint,
            history: history
        ) {
        case .current(let item):
            currentItem = item
        case .stale:
            finishGeneration(
                noteID: request.noteID,
                revision: generationRevision
            )
            return .sourceChanged
        case .persistenceFailed:
            finishGeneration(
                noteID: request.noteID,
                revision: generationRevision
            )
            return .persistenceFailed
        }
        let envelope = MeetingSummaryRecordBuilder.successEnvelope(
            result: result,
            sourceFingerprint: sourceFingerprint,
            languageContext: source.languageContext,
            generatedAt: dependencies.now(),
            previous: currentItem.meetingSummary
        )
        let attempt = MeetingSummaryRecordBuilder.successAttempt(
            result: result,
            configuredProviderHost: request.providerHost,
            languageContext: source.languageContext,
            sourceFingerprint: sourceFingerprint,
            occurredAt: dependencies.now()
        )
        // The same text leaves nothing to choose: it is saved directly,
        // keeping what is on screen, like a retranscription with the same
        // result.
        let unchangedSummary = request.deliversCandidate
            ? currentItem.meetingSummary.flatMap { envelope.keepingRows(of: $0) }
            : nil
        if request.deliversCandidate, unchangedSummary == nil {
            // Nothing is saved until the person chooses the new summary.
            state.candidates[request.noteID] = MeetingSummaryCandidate(
                envelope: envelope,
                attempt: attempt
            )
            finishGeneration(
                noteID: request.noteID,
                revision: generationRevision
            )
            return result.evidenceVerification == .unverified
                ? .unverifiedSuccess
                : .verifiedSuccess
        }
        let updated = currentItem
            .withMeetingSummary(unchangedSummary ?? envelope)
            .withMeetingSummaryAttempt(attempt)
        do {
            try history.persist(updated, true)
        } catch {
            finishGeneration(
                noteID: request.noteID,
                revision: generationRevision
            )
            return .persistenceFailed
        }
        onEvent?(.itemPersisted(updated))
        if let unchangedSummary {
            state.unchangedSummaries[request.noteID] = unchangedSummary.generatedAt
        }
        finishGeneration(
            noteID: request.noteID,
            revision: generationRevision,
            pendingReveal: unchangedSummary == nil
        )
        return result.evidenceVerification == .unverified
            ? .unverifiedSuccess
            : .verifiedSuccess
    }

    @MainActor
    func invalidate(noteID: UUID) {
        generationRevisionByID[noteID, default: 0] += 1
        state.generatingNoteIDs.remove(noteID)
        state.pendingRevealNoteIDs.remove(noteID)
        state.candidates.removeValue(forKey: noteID)
        state.unchangedSummaries.removeValue(forKey: noteID)
        emitState()
    }

    @MainActor
    func forget(noteID: UUID) {
        generationRevisionByID.removeValue(forKey: noteID)
        state.generatingNoteIDs.remove(noteID)
        state.pendingRevealNoteIDs.remove(noteID)
        state.candidates.removeValue(forKey: noteID)
        state.unchangedSummaries.removeValue(forKey: noteID)
        emitState()
    }

    /// Drops a candidate the person decided not to keep, or already saved.
    @MainActor
    func discardCandidate(noteID: UUID) {
        guard state.candidates.removeValue(forKey: noteID) != nil else { return }
        emitState()
    }

    /// Hides the note that a new summary had the same text.
    @MainActor
    func dismissUnchangedSummary(noteID: UUID) {
        guard state.unchangedSummaries.removeValue(forKey: noteID) != nil else { return }
        emitState()
    }

    @MainActor
    func forgetAll() {
        generationRevisionByID.removeAll()
        state = .initial
        emitState()
    }

    @MainActor
    func consumePendingReveal(noteID: UUID) -> Bool {
        let consumed = state.pendingRevealNoteIDs.remove(noteID) != nil
        if consumed { emitState() }
        return consumed
    }

    static func transcript(for item: PipelineHistoryItem) -> String {
        let processed = item.postProcessedTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return processed.isEmpty ? item.rawTranscript : processed
    }

    static func source(
        for item: PipelineHistoryItem,
        languageContext: MeetingSummaryLanguageContext
    ) -> MeetingSummarySource {
        let calendar = item.calendarMatch.map { match in
            MeetingSummaryCalendarContext(
                title: match.title,
                start: match.start,
                end: match.end,
                attendees: match.attendees.compactMap {
                    MeetingSummaryCalendarContext.attendeeLabel(
                        displayName: $0.displayName,
                        email: $0.email
                    )
                }
            )
        }
        return MeetingSummarySource(
            transcript: transcript(for: item),
            calendar: calendar,
            languageContext: languageContext
        )
    }

    static func availabilitySource(
        for item: PipelineHistoryItem
    ) -> MeetingSummarySource {
        source(
            for: item,
            languageContext: MeetingSummaryLanguageContext(
                requestedOutputLanguage: "",
                appliedLanguageCode: "",
                resolutionSource: .unavailable
            )
        )
    }

    static func resolvedLanguage(
        for item: PipelineHistoryItem,
        transcript: String,
        requestedOutputLanguage: String
    ) throws -> (
        context: MeetingSummaryLanguageContext,
        resolvedSpokenLanguage: SpokenLanguageResolution?
    ) {
        let decision: MeetingSummaryLanguageDecision
        do {
            decision = try MeetingSummaryLanguageDecision.resolve(
                requestedOutputLanguage: requestedOutputLanguage,
                spokenLanguage: item.spokenLanguage,
                transcriptionLanguageCode: item.transcriptionLanguageCode,
                transcript: transcript
            )
        } catch MeetingSummaryLanguageError.unavailable {
            throw QuillUserIssueError.meetingSummaryLanguageUnavailable()
        }
        return (decision.context, decision.resolvedSpokenLanguage)
    }

    @MainActor
    private func persistFailure(
        _ error: Error,
        request: MeetingSummaryWorkflowRequest,
        history: MeetingSummaryHistoryAccess,
        revision: Int,
        languageContext: MeetingSummaryLanguageContext?,
        sourceFingerprint: String
    ) -> MeetingSummaryWorkflowOutcome {
        let currentItem: PipelineHistoryItem
        switch validateCurrentItem(
            noteID: request.noteID,
            revision: revision,
            sourceFingerprint: sourceFingerprint,
            history: history
        ) {
        case .current(let item):
            currentItem = item
        case .stale:
            finishGeneration(noteID: request.noteID, revision: revision)
            return .sourceChanged
        case .persistenceFailed:
            finishGeneration(noteID: request.noteID, revision: revision)
            return .persistenceFailed
        }
        if let summaryError = error as? MeetingSummaryError,
           summaryError == .sourceChanged {
            finishGeneration(noteID: request.noteID, revision: revision)
            return .sourceChanged
        }

        let attempt = MeetingSummaryRecordBuilder.failureAttempt(
            error: error,
            issue: (error as? QuillUserIssueError)?.record,
            backendKind: request.configuredBackendKind,
            configuredModelID: request.configuredModelID,
            configuredProviderHost: request.providerHost,
            languageContext: languageContext,
            sourceFingerprint: sourceFingerprint,
            occurredAt: dependencies.now()
        )
        let updated = currentItem.withMeetingSummaryAttempt(attempt)
        do {
            try history.persist(updated, true)
        } catch {
            finishGeneration(noteID: request.noteID, revision: revision)
            return .persistenceFailed
        }
        onEvent?(.itemPersisted(updated))
        finishGeneration(noteID: request.noteID, revision: revision)
        return .generationFailed(error)
    }

    @MainActor
    private func validateCurrentItem(
        noteID: UUID,
        revision: Int,
        sourceFingerprint: String,
        history: MeetingSummaryHistoryAccess
    ) -> MeetingSummaryCurrentItemValidation {
        guard generationRevisionByID[noteID] == revision else {
            return .stale
        }
        let item: PipelineHistoryItem
        do {
            guard let loadedItem = try history.item(noteID) else {
                return .stale
            }
            item = loadedItem
        } catch {
            return .persistenceFailed
        }
        guard Self.availabilitySource(for: item).fingerprint
                == sourceFingerprint else {
            return .stale
        }
        return .current(item)
    }

    @MainActor
    private func finishGeneration(
        noteID: UUID,
        revision: Int,
        pendingReveal: Bool = false
    ) {
        guard generationRevisionByID[noteID] == revision else {
            return
        }
        if pendingReveal {
            state.pendingRevealNoteIDs.insert(noteID)
        }
        state.generatingNoteIDs.remove(noteID)
        emitState()
    }

    @MainActor
    private func emitState() {
        onEvent?(.stateChanged(state))
    }
}
