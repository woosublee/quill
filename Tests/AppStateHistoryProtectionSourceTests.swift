import Foundation

/// Most history-safety guarantees this suite once checked via exact source text
/// now have behavioral coverage in `AppStateStorageSafetyTests` (startup gating,
/// archive/recovery ordering, mutation guards, and snapshot-only failure
/// isolation). What remains here is limited to:
///
/// 1. a static scan proving removed process-global dependency seams do not
///    reappear, and
/// 2. a small number of defense-in-depth invariants that cannot be exercised
///    through the public `AppState` API without simulating disk failures,
///    permission-callback races, or wall-clock timing that would make the
///    test itself the primary source of flakiness. Each is documented with
///    the specific reason it remains a source check rather than a behavior
///    test.
struct AppStateHistoryProtectionSourceTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let repositorySwiftSource = try combinedSwiftSource(in: ["Sources", "Tests"])
        let removedHistorySeams: [String] = [
            ["meeting", "Summary", "Generator", "Factory"].joined(),
            ["storage", "Root", "Provider"].joined(),
            ["pipeline", "History", "Store", "Factory"].joined(),
            ["pipeline", "History", "Store", "At", "URL", "Factory"].joined(),
            ["retry", "Cloud", "Transcription", "Dependencies", "Factory"].joined(),
            ["make", "Default", "Pipeline", "History", "Store"].joined()
        ]
        let removedModelSeams: [String] = [
            ["native", "Whisper", "Install", "Status", "Provider"].joined(),
            ["native", "Whisper", "Install", "Starter"].joined(),
            ["native", "Whisper", "Progress", "Schedule"].joined(),
            ["local", "AI", "Server", "Manager", "Factory"].joined(),
            ["local", "AI", "Idle", "Shutdown", "Sleep"].joined(),
            ["local", "AI", "Install", "Status", "Provider"].joined(),
            ["local", "AI", "Install", "Starter"].joined(),
            ["local", "AI", "Progress", "Schedule"].joined(),
            ["local", "AI", "Model", "Delete"].joined(),
            ["local", "AI", "Partial", "Model", "Delete"].joined(),
            ["local", "AI", "Processing", "Availability", "Provider"].joined()
        ]
        let removedSeams = removedHistorySeams + removedModelSeams
        let removedNativeWhisperWorkerConstructions: [String] = [
            ["Native", "Whisper", "Model", "Store", "()"].joined(),
            ["Native", "Whisper", "Runtime", "()"].joined()
        ]
        let removedStaticReferences = [
            ["App", "State", ".", "app", "Storage", "Root", "Directory"].joined(),
            ["App", "State", ".", "audio", "Storage", "Directory"].joined(),
            ["App", "State", ".", "transcript", "Storage", "Directory"].joined(),
            ["App", "State", ".", "load", "Transcript"].joined(),
            ["static func ", "load", "Transcript"].joined()
        ]
        for removedIdentifier in removedSeams + removedStaticReferences {
            try expect(
                !repositorySwiftSource.contains(removedIdentifier),
                "removed AppState dependency seam remains absent: \(removedIdentifier)"
            )
        }

        // Native Whisper behavior and two-environment isolation are covered by
        // TranscriptionServiceLocalIssueTests. This narrow scan only prevents
        // the removed worker-local live construction from returning.
        let transcriptionServiceSource = try String(
            contentsOfFile: "Sources/TranscriptionService.swift",
            encoding: .utf8
        )
        let nativeWhisperWorkerRange = try transcriptionServiceSource.range(
            from: "private func transcribeWithNativeWhisper(fileURL: URL)",
            to: "private func transcribeWithAppleSpeech(fileURL: URL)"
        )
        let nativeWhisperWorker = String(
            transcriptionServiceSource[nativeWhisperWorkerRange]
        )
        for removedConstruction in removedNativeWhisperWorkerConstructions {
            try expect(
                !nativeWhisperWorker.contains(removedConstruction),
                "Native Whisper worker does not reopen live execution: \(removedConstruction)"
            )
        }

        // Archive admission now has table-driven behavior coverage in
        // HistoryArchiveRecoveryWorkflowTests. This remaining source check
        // protects the separate mid-write audio-import tracking invariant.
        try expect(
            source.contains("pendingAudioImportJobIDs.insert(jobID)")
                && source.contains("pendingAudioImportJobIDs.remove(jobID)"),
            "audio import is tracked before its detached audio copy can touch history storage"
        )

        // Recording start and microphone-permission resumption recheck history
        // availability after every asynchronous suspension point as defense in
        // depth against history becoming unavailable while a start is in
        // flight. Simulating that exact race (flip availability mid-permission
        // callback) is disproportionate to this suite; the occurrence count is
        // the cheapest faithful proxy for "the recheck was not deleted."
        let recordingStartRange = try source.range(
            from: "private func startRecording(",
            to: "/// Whether the configured recording flow will actually exercise Accessibility."
        )
        let recordingStart = String(source[recordingStartRange])
        try expect(
            source.contains("private var pendingRecordingStartCount = 0")
                && recordingStart.contains("pendingRecordingStartCount += 1")
                && recordingStart.contains("defer {")
                && recordingStart.contains(
                    "self.completePendingRecordingStartTask(startRequestID)"
                ),
            "an awaited recording start tracks itself as pending via defer, so an early throw or return still decrements the count"
        )
        try expect(
            recordingStart.components(separatedBy: "requireAvailableHistoryForMutation()").count >= 3,
            "an awaited recording start rechecks archive protection before creating writers"
        )
        let microphonePermissionRange = try source.range(
            from: "private func ensureMicrophoneAccess(",
            to: "private func applyAudioInterruptionIfNeeded()"
        )
        let microphonePermission = String(source[microphonePermissionRange])
        try expect(
            microphonePermission.contains("pendingRecordingStartCount += 1")
                && microphonePermission.contains("defer {")
                && microphonePermission.contains(
                    "strongSelf.completePendingRecordingStartTask("
                ),
            "microphone permission resumption tracks itself as pending via defer, so an early throw or return still decrements the count"
        )
        try expect(
            microphonePermission.components(
                separatedBy: "strongSelf.requireAvailableHistoryForMutation()"
            ).count >= 3,
            "microphone permission resumption rechecks archive protection before creating writers"
        )

        // A failed history update must not delete assets it never touched, and
        // recovery import must remain the sole writer to active history while
        // it runs. Forcing a genuine mid-write Core Data failure to observe
        // this behaviorally would require corrupting the store at an exact
        // instant inside a transaction, which is not reproducible through the
        // public API.
        let persistenceRange = try source.range(
            from: "private func recordPipelineHistoryEntry(",
            to: "private func startRealtimeStreamingIfEnabled()"
        )
        let persistence = String(source[persistenceRange])
        try expect(
            persistence.contains("if existingID == nil, !isJournalAudioFile {")
                && persistence.contains("guard !isHistoryRecoveryOperationInProgress else { return false }"),
            "a failed update preserves assets and cannot write during recovery import"
        )

        // Deferred orphan cleanup must use the reference snapshot's startup
        // timestamp, not the time it happens to run, so a file created after
        // startup is never mistaken for an old orphan. Verifying this
        // behaviorally requires controlling the wall clock inside a detached
        // Task, which the harness does not support.
        let orphanSweepRange = try source.range(
            from: "if referenceTrust.permitsStartupReferenceCleanup {\n                    let sweepReferenceTrust",
            to: "            } else {\n                print(\"Skipping history startup work because persistent history is unavailable.\")"
        )
        let orphanSweep = String(source[orphanSweepRange])
        try expect(
            orphanSweep.contains("let sweepNow = Date()")
                && orphanSweep.contains("now: sweepNow"),
            "delayed orphan cleanup uses the startup reference snapshot time"
        )

        // Recently Deleted rows are part of the stored history: recovery
        // compares against them and a cancelled job never removes audio they
        // still use. Exercising either needs a recovery snapshot import or a
        // cancelled live transcription, so these stay source checks.
        try expect(
            !source.contains("activeHistory: pipelineHistory")
                && source.contains("activeHistory: storedHistory"),
            "history recovery compares against live and Recently Deleted notes"
        )
        let cancelRange = try source.range(
            from: "let cancelledStatus = localizedCatalogString(\"Cancelled\")",
            to: "finishTranscriptionJob(job.id)"
        )
        try expect(
            String(source[cancelRange]).contains("storedHistory.contains(where: {"),
            "a cancelled job keeps audio a Recently Deleted note uses"
        )
        // The purge runs from a timer and when Settings opens; it waits
        // silently instead of raising the busy-history error banner.
        let purgeRange = try source.range(
            from: "func purgeExpiredRecentlyDeletedNotes(",
            to: "\n    }\n"
        )
        let purge = String(source[purgeRange])
        try expect(
            purge.contains("HistoryWorkflowAdmission.mutation(")
                && !purge.contains("deleteRecentlyDeletedNoteNow(id:"),
            "the purge checks history admission silently and deletes in one batch"
        )

        // In-memory copies of a stored note keep its deletion and field
        // clock, so a copy of a Recently Deleted note never shows as live.
        // These copies are built inside long AppState and recovery flows.
        let recovery = try String(contentsOfFile: "Sources/RecordingRecoveryHistory.swift", encoding: .utf8)
        let unrecoveredCopy = try recovery.range(
            from: "func replacingUnrecoveredStatus(",
            to: "\n    }\n"
        )
        try expect(
            recovery[unrecoveredCopy].contains("deletedAt: deletedAt")
                && recovery[unrecoveredCopy].contains("fieldClock: fieldClock"),
            "replacingUnrecoveredStatus keeps deletion and clock"
        )
        let liveCopy = try source.range(
            from: "private func updateLiveNoteTranscript(",
            to: "\n    }\n"
        )
        try expect(
            source[liveCopy].contains("deletedAt: existing.deletedAt")
                && source[liveCopy].contains("fieldClock: existing.fieldClock"),
            "live transcript updates keep deletion and clock"
        )

        // Recently Deleted follow-ups that need a live Settings window, a
        // failing store, or a run loop to exercise behaviorally.
        let recoveryView = try String(contentsOfFile: "Sources/HistoryRecoveryView.swift", encoding: .utf8)
        try expect(
            recoveryView.contains("appState.$recentlyDeletedNotes.dropFirst()"),
            "recovery inspection refreshes when Recently Deleted changes"
        )
        let invalidate = try source.range(
            from: "func invalidateHistoryRecoveryInspectionResults() {",
            to: "\n    }\n"
        )
        try expect(
            source[invalidate].contains("guard !historyRecoverySnapshots.isEmpty else { return }"),
            "no inspection work without snapshots"
        )
        let removal = try source.range(
            from: "private func removeRecentlyDeletedNotes(",
            to: "\n    }\n\n"
        )
        try expect(
            source[removal].contains("meetingSummaryWorkflow.forget(noteID: id)")
                && source[removal].contains("forgetWarningBannerState(for: id)")
                && source[removal].contains("guard reportsErrors"),
            "removal tears down note state and stays silent for the purge"
        )
        try expect(
            source.contains("removeRecentlyDeletedNotes(ids: expiredIDs, reportsErrors: false)")
                && source.contains("RunLoop.main.add(timer, forMode: .common)")
                && source.contains("func stopRecentlyDeletedPurgeSchedule()"),
            "the hourly purge is silent, runs in common modes, and stops at quit"
        )
        let section = try String(contentsOfFile: "Sources/RecentlyDeletedNotesSection.swift", encoding: .utf8)
        try expect(
            section.contains("visibleRestoredNotes"),
            "a note deleted again leaves the Restored rows"
        )
        let delegate = try String(contentsOfFile: "Sources/AppDelegate.swift", encoding: .utf8)
        try expect(
            delegate.contains("appState.stopRecentlyDeletedPurgeSchedule()"),
            "quitting stops the purge timer"
        )

        print("AppStateHistoryProtectionSourceTests passed")
    }

    private static func combinedSwiftSource(in directories: [String]) throws -> String {
        let fileManager = FileManager.default
        var source = ""
        for directory in directories {
            guard let enumerator = fileManager.enumerator(atPath: directory) else {
                throw TestFailure("Missing source directory: \(directory)")
            }
            for case let relativePath as String in enumerator where relativePath.hasSuffix(".swift") {
                let fileURL = URL(fileURLWithPath: directory).appendingPathComponent(relativePath)
                source += try String(contentsOf: fileURL, encoding: .utf8)
            }
        }
        return source
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }
}

private extension String {
    func range(from startMarker: String, to endMarker: String) throws -> Range<Index> {
        let start = try range(of: startMarker).unwrap(startMarker)
        let end = try range(of: endMarker, range: start.upperBound..<endIndex).unwrap(endMarker)
        return start.lowerBound..<end.lowerBound
    }
}

private extension Optional where Wrapped == Range<String.Index> {
    func unwrap(_ marker: String) throws -> Range<String.Index> {
        guard let self else { throw TestFailure("Missing \(marker)") }
        return self
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
