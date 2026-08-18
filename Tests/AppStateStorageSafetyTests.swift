import Darwin
import Foundation

struct AppStateStorageSafetyTests {
    static func main() async throws {
        try verifiesDefaultAppStateUsesLiveStorageLayout()
        try await verifiesAppStateInstancesKeepIndependentHistoryLayouts()
        try await verifiesAppStateInstancesKeepIndependentCredentialStores()
        try await verifiesDeleteHistoryEntryRemovesOwnedAssets()
        try await verifiesClearHistoryRemovesOwnedAssets()
        try await verifiesSharedAssetsRemainWhileHistoryStillReferencesThem()
        try verifiesRemovedRowsDoNotProtectEachOthersSharedAssets()
        try verifiesAudioOnlyPersistenceFailureCleanupDecisions()
        try verifiesDegradedCombinedCaptureMessages()
        try await verifiesArchiveUsesOriginatingHistoryStoreFactory()
        try await verifiesHistoryCreatedAfterAssetsDoesNotSweep()
        try await verifiesHistoryRowsLostAfterSnapshotDoesNotSweep()
        try await verifiesUnavailableHistoryBlocksMutatingActions()
        try await verifiesExplicitArchiveCreatesFreshSeparatedHistory()
        try await verifiesArchivedNoteImportsIntoFreshHistory()
        try await verifiesRecoverySettingsAutomaticallyInspectsSnapshots()
        try await verifiesInterruptedArchiveKeepsHistoryProtected()
        try await verifiesMissingSnapshotWithUnreferencedAudioDoesNotSweep()
        try await verifiesMatchingHistorySnapshotSweepsOrphansAtStartup()
        try await verifiesTrustedHistorySweepsOrphans()
        try await verifiesArchiveCompletionAllowsImmediateAssetSavesWithoutRestart()
        try await verifiesSnapshotOnlyRecoveryFailureLeavesActiveStoreUntouched()
        try await verifiesRecoveryOperationInProgressBlocksMutation()
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let fallbackAudioURL = try await verifiesFallbackHistoryDoesNotSweepStoredAudio(
                environment: environment
            )
            try await verifiesMissingHistoryDoesNotSweepStoredAudio(
                audioURL: fallbackAudioURL,
                environment: environment
            )

            let audioDirectory = environment.storageLayout.audioDirectory.standardizedFileURL
            let transcriptDirectory = environment.storageLayout.transcriptDirectory.standardizedFileURL
            let rootPath = environment.rootDirectory.standardizedFileURL.path + "/"

            try expect(
                audioDirectory.path.hasPrefix(rootPath),
                "AppState tests write audio below their isolated root"
            )
            try expect(
                transcriptDirectory.path.hasPrefix(rootPath),
                "AppState tests write transcripts below their isolated root"
            )
        }
        print("AppStateStorageSafetyTests passed")
    }

    private static func verifiesDefaultAppStateUsesLiveStorageLayout() throws {
        let appState = AppState()
        try expect(
            appState.storageLayout.rootDirectory == AppName.applicationSupportDirectory,
            "default AppState keeps the production storage root"
        )
    }

    private static func verifiesAppStateInstancesKeepIndependentHistoryLayouts() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-instance-layouts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let firstLayout = AppStateStorageLayout(
            rootDirectory: parent.appendingPathComponent("first", isDirectory: true)
        )
        let secondLayout = AppStateStorageLayout(
            rootDirectory: parent.appendingPathComponent("second", isDirectory: true)
        )
        for layout in [firstLayout, secondLayout] {
            try FileManager.default.createDirectory(
                at: layout.rootDirectory,
                withIntermediateDirectories: true
            )
        }
        let firstItem = PipelineHistoryItem(
            timestamp: Date(timeIntervalSince1970: 1),
            rawTranscript: "first",
            postProcessedTranscript: "first",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "succeeded",
            debugStatus: "",
            customVocabulary: ""
        )
        let secondItem = PipelineHistoryItem(
            timestamp: Date(timeIntervalSince1970: 2),
            rawTranscript: "second",
            postProcessedTranscript: "second",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "succeeded",
            debugStatus: "",
            customVocabulary: ""
        )
        _ = try PipelineHistoryStore(storeURL: firstLayout.historyStoreURL)
            .upsert(firstItem, maxCount: 10, requiresDurableStore: true)
        _ = try PipelineHistoryStore(storeURL: secondLayout.historyStoreURL)
            .upsert(secondItem, maxCount: 10, requiresDurableStore: true)

        var firstDependencies = AppStateDependencies.live
        firstDependencies.storageLayout = firstLayout
        var secondDependencies = AppStateDependencies.live
        secondDependencies.storageLayout = secondLayout
        let configuredFirstDependencies = firstDependencies
        let configuredSecondDependencies = secondDependencies
        let firstState = await MainActor.run {
            AppState(dependencies: configuredFirstDependencies)
        }
        let secondState = await MainActor.run {
            AppState(dependencies: configuredSecondDependencies)
        }

        try expect(firstState.pipelineHistory.map(\.id) == [firstItem.id],
                   "first AppState loads only its history layout")
        try expect(secondState.pipelineHistory.map(\.id) == [secondItem.id],
                   "second AppState loads only its history layout")
    }

    private static func verifiesAppStateInstancesKeepIndependentCredentialStores() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-instance-credentials-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let firstStorageLayout = AppStateStorageLayout(
            rootDirectory: parent.appendingPathComponent("first-storage", isDirectory: true)
        )
        let secondStorageLayout = AppStateStorageLayout(
            rootDirectory: parent.appendingPathComponent("second-storage", isDirectory: true)
        )
        let firstCredentialLayout = CredentialStorageLayout(
            directory: parent.appendingPathComponent("first-credentials", isDirectory: true)
        )
        let secondCredentialLayout = CredentialStorageLayout(
            directory: parent.appendingPathComponent("second-credentials", isDirectory: true)
        )
        try CredentialStore(layout: firstCredentialLayout).save(
            "first-instance-key",
            account: "groq_api_key"
        )
        try CredentialStore(layout: secondCredentialLayout).save(
            "second-instance-key",
            account: "groq_api_key"
        )

        var firstDependencies = AppStateDependencies.live
        firstDependencies.storageLayout = firstStorageLayout
        firstDependencies.credentialStorageLayout = firstCredentialLayout
        var secondDependencies = AppStateDependencies.live
        secondDependencies.storageLayout = secondStorageLayout
        secondDependencies.credentialStorageLayout = secondCredentialLayout
        let configuredFirstDependencies = firstDependencies
        let configuredSecondDependencies = secondDependencies
        let firstState = await MainActor.run {
            AppState(dependencies: configuredFirstDependencies)
        }
        let secondState = await MainActor.run {
            AppState(dependencies: configuredSecondDependencies)
        }

        try expect(
            firstState.apiKey == "first-instance-key",
            "the first AppState loads its own stored API key"
        )
        try expect(
            secondState.apiKey == "second-instance-key",
            "the second AppState loads its own stored API key"
        )

        await MainActor.run {
            firstState.apiKey = "first-instance-updated-key"
        }
        try expect(
            CredentialStore(layout: firstCredentialLayout)
                .load(account: "groq_api_key") == "first-instance-updated-key",
            "updating the first AppState's API key persists to its own credential layout"
        )
        try expect(
            CredentialStore(layout: secondCredentialLayout)
                .load(account: "groq_api_key") == "second-instance-key",
            "updating the first AppState's API key does not affect the second instance's stored credential"
        )
    }

    private static func verifiesDeleteHistoryEntryRemovesOwnedAssets() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let assetStore = NoteAssetStore(
                storageLayout: environment.storageLayout
            )
            let sourceURL = environment.rootDirectory
                .appendingPathComponent("delete-owned-source.wav")
            try Data("owned audio".utf8).write(to: sourceURL)
            let audio = try assetStore.saveAudio(from: sourceURL)
            let transcriptFileName = try assetStore.saveTranscript(
                rawTranscript: "owned transcript",
                postProcessedTranscript: ""
            )
            let item = makeHistoryItem(
                audioFileName: audio.fileName,
                transcriptFileName: transcriptFileName
            )
            let historyStore = PipelineHistoryStore(
                storeURL: environment.storageLayout.historyStoreURL
            )
            _ = try historyStore.append(item, maxCount: Int.max)

            let appState = await MainActor.run {
                AppState(dependencies: environment.dependencies)
            }
            await MainActor.run {
                appState.deleteHistoryEntry(id: item.id)
            }

            let transcriptURL = environment.storageLayout.transcriptDirectory
                .appendingPathComponent(transcriptFileName)
            try expect(
                !FileManager.default.fileExists(atPath: audio.fileURL.path),
                "deleting a history entry removes its owned audio"
            )
            try expect(
                !FileManager.default.fileExists(atPath: transcriptURL.path),
                "deleting a history entry removes its owned transcript"
            )
        }
    }

    private static func verifiesClearHistoryRemovesOwnedAssets() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let assetStore = NoteAssetStore(
                storageLayout: environment.storageLayout
            )
            let historyStore = PipelineHistoryStore(
                storeURL: environment.storageLayout.historyStoreURL
            )
            var audioURLs: [URL] = []
            var transcriptURLs: [URL] = []
            for index in 0..<2 {
                let sourceURL = environment.rootDirectory
                    .appendingPathComponent("clear-owned-source-\(index).wav")
                try Data("audio \(index)".utf8).write(to: sourceURL)
                let audio = try assetStore.saveAudio(from: sourceURL)
                let transcriptFileName = try assetStore.saveTranscript(
                    rawTranscript: "transcript \(index)",
                    postProcessedTranscript: ""
                )
                let item = makeHistoryItem(
                    audioFileName: audio.fileName,
                    transcriptFileName: transcriptFileName,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index))
                )
                _ = try historyStore.append(item, maxCount: Int.max)
                audioURLs.append(audio.fileURL)
                transcriptURLs.append(
                    environment.storageLayout.transcriptDirectory
                        .appendingPathComponent(transcriptFileName)
                )
            }

            let appState = await MainActor.run {
                AppState(dependencies: environment.dependencies)
            }
            await MainActor.run {
                appState.clearPipelineHistory()
            }

            for fileURL in audioURLs + transcriptURLs {
                try expect(
                    !FileManager.default.fileExists(atPath: fileURL.path),
                    "clearing history removes every deleted entry asset"
                )
            }
        }
    }

    private static func verifiesSharedAssetsRemainWhileHistoryStillReferencesThem() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let assetStore = NoteAssetStore(
                storageLayout: environment.storageLayout
            )
            let sourceURL = environment.rootDirectory
                .appendingPathComponent("shared-source.wav")
            try Data("shared audio".utf8).write(to: sourceURL)
            let audio = try assetStore.saveAudio(from: sourceURL)
            let transcriptFileName = try assetStore.saveTranscript(
                rawTranscript: "shared transcript",
                postProcessedTranscript: ""
            )
            let removedItem = makeHistoryItem(
                audioFileName: audio.fileName,
                transcriptFileName: transcriptFileName,
                timestamp: Date(timeIntervalSince1970: 1)
            )
            let survivingItem = makeHistoryItem(
                audioFileName: audio.fileName,
                transcriptFileName: transcriptFileName,
                timestamp: Date(timeIntervalSince1970: 2)
            )
            let historyStore = PipelineHistoryStore(
                storeURL: environment.storageLayout.historyStoreURL
            )
            _ = try historyStore.append(removedItem, maxCount: Int.max)
            _ = try historyStore.append(survivingItem, maxCount: Int.max)

            let appState = await MainActor.run {
                AppState(dependencies: environment.dependencies)
            }
            await MainActor.run {
                appState.deleteHistoryEntry(id: removedItem.id)
            }

            let transcriptURL = environment.storageLayout.transcriptDirectory
                .appendingPathComponent(transcriptFileName)
            try expect(
                FileManager.default.fileExists(atPath: audio.fileURL.path),
                "shared audio remains while surviving history references it"
            )
            try expect(
                FileManager.default.fileExists(atPath: transcriptURL.path),
                "shared transcript remains while surviving history references it"
            )
            try expect(
                appState.pipelineHistory.map(\.id) == [survivingItem.id],
                "only the selected shared-reference history entry is removed"
            )
        }
    }

    private static func verifiesRemovedRowsDoNotProtectEachOthersSharedAssets() throws {
        let sharedAudio = "removed-shared.wav"
        let sharedTranscript = "removed-shared.txt"
        let removed = [
            DeletedPipelineHistoryAssets(
                historyID: UUID(),
                audioFileName: sharedAudio,
                transcriptFileName: sharedTranscript
            ),
            DeletedPipelineHistoryAssets(
                historyID: UUID(),
                audioFileName: sharedAudio,
                transcriptFileName: sharedTranscript
            )
        ]

        let deletable = AppState.deletableAssets(
            removed: removed,
            survivingHistory: []
        )

        try expect(
            deletable.count == removed.count,
            "removed rows do not count as surviving shared references"
        )
        try expect(
            deletable.allSatisfy {
                $0.audioFileName == sharedAudio
                    && $0.transcriptFileName == sharedTranscript
            },
            "shared assets are deletable when every referencing row was removed"
        )
    }

    private static func verifiesAudioOnlyPersistenceFailureCleanupDecisions() throws {
        let cases: [(
            hasJournalOwner: Bool,
            historyIsAvailableAndDurable: Bool,
            historyIsReadable: Bool,
            recordingIDExistsInHistory: Bool,
            expected: AppState.AudioOnlyPersistenceFailureCleanupDecision
        )] = [
            (true, true, true, false, .preserve),
            (false, false, true, false, .preserve),
            (false, true, false, false, .preserve),
            (false, true, true, true, .preserve),
            (false, true, true, false, .deleteUnreferencedAudio)
        ]

        for testCase in cases {
            let actual = AppState.audioOnlyPersistenceFailureCleanupDecision(
                hasJournalOwner: testCase.hasJournalOwner,
                historyIsAvailableAndDurable:
                    testCase.historyIsAvailableAndDurable,
                historyIsReadable: testCase.historyIsReadable,
                recordingIDExistsInHistory:
                    testCase.recordingIDExistsInHistory
            )
            try expect(
                actual == testCase.expected,
                "audio-only persistence failure preserves uncertain ownership"
            )
        }
    }

    // A degraded combined-capture message must name which source is
    // missing and which one recording continues with, so the notice never
    // reads as a generic, actionless "something failed".
    private static func verifiesDegradedCombinedCaptureMessages() throws {
        let missingMicMessage = AppState.degradedCombinedCaptureMessage(missing: .microphone)
        try expect(
            missingMicMessage.localizedCaseInsensitiveContains("mic"),
            "missing-microphone message names the mic"
        )
        try expect(
            missingMicMessage.localizedCaseInsensitiveContains("system audio"),
            "missing-microphone message names the surviving source"
        )

        let missingSystemAudioMessage = AppState.degradedCombinedCaptureMessage(missing: .systemAudio)
        try expect(
            missingSystemAudioMessage.localizedCaseInsensitiveContains("system audio"),
            "missing-System-Audio message names System Audio"
        )
        try expect(
            missingSystemAudioMessage.localizedCaseInsensitiveContains("mic"),
            "missing-System-Audio message names the surviving source"
        )
        try expect(
            missingMicMessage != missingSystemAudioMessage,
            "the two degraded messages are distinct"
        )
    }

    private static func makeHistoryItem(
        audioFileName: String?,
        transcriptFileName: String?,
        timestamp: Date = Date()
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            timestamp: timestamp,
            rawTranscript: "fixture",
            postProcessedTranscript: "fixture",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "succeeded",
            debugStatus: "",
            customVocabulary: "",
            audioFileName: audioFileName,
            transcriptFileName: transcriptFileName
        )
    }

    private static func verifiesArchiveUsesOriginatingHistoryStoreFactory() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let layout = environment.storageLayout
            try Data("unavailable canonical history".utf8).write(to: layout.historyStoreURL)
            let unavailableStore = PipelineHistoryStore(
                storeURL: layout.historyStoreURL,
                persistentStoreLoader: { _ in
                    TestFailure("Injected unavailable history for factory ownership")
                }
            )
            let originatingRecorder = HistoryStoreURLRecorder()
            let laterRecorder = HistoryStoreURLRecorder()
            let startupFactory = UnavailableStartupStoreFactoryState(
                startupURL: layout.historyStoreURL
            )
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = { url in
                originatingRecorder.record(url)
                return startupFactory.makeStore(
                    for: url,
                    unavailableStore: unavailableStore
                )
            }

            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            dependencies.makePipelineHistoryStore = { url in
                laterRecorder.record(url)
                return PipelineHistoryStore(storeURL: url)
            }
            let archiveAccepted = await MainActor.run {
                appState.archiveOldHistoryAndStartFresh()
            }

            try expect(archiveAccepted, "factory ownership archive is accepted")
            try await waitForArchiveCompletion(appState)
            try expect(
                originatingRecorder.contains(layout.historyStoreURL),
                "archive replacement uses the originating AppState factory"
            )
            try expect(
                originatingRecorder.count(of: layout.historyStoreURL) >= 5,
                "originating factory receives startup, archive probe, and replacement requests"
            )
            try expect(
                laterRecorder.isEmpty,
                "later dependency mutation cannot redirect archive work"
            )
            try expect(
                !appState.isHistoryUnavailable,
                "originating factory installs the verified fresh active store"
            )
        }
    }

    private static func verifiesHistoryCreatedAfterAssetsDoesNotSweep() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let audioURL = environment.storageLayout.audioDirectory
                .appendingPathComponent("history-lost.wav")
            try Data("fixture".utf8).write(to: audioURL)
            try setOldModificationDate(of: audioURL)
            try await Task.sleep(nanoseconds: 1_200_000_000)
            _ = PipelineHistoryStore(storeURL: environment.storageLayout.historyStoreURL)

            _ = await MainActor.run { AppState(dependencies: environment.dependencies) }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            try expect(
                FileManager.default.fileExists(atPath: audioURL.path),
                "history created after stored audio never treats it as an orphan"
            )
        }
    }

    private static func verifiesHistoryRowsLostAfterSnapshotDoesNotSweep() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let historyStore = PipelineHistoryStore(
                storeURL: environment.storageLayout.historyStoreURL
            )
            let audioURL = environment.storageLayout.audioDirectory
                .appendingPathComponent("history-row-lost.wav")
            try Data("fixture".utf8).write(to: audioURL)
            try setOldModificationDate(of: audioURL)
            try historyStore.saveAssetReferenceSnapshot(
                audioFileNames: [audioURL.lastPathComponent],
                transcriptFileNames: []
            )

            _ = await MainActor.run { AppState(dependencies: environment.dependencies) }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            try expect(
                FileManager.default.fileExists(atPath: audioURL.path),
                "a history snapshot mismatch never sweeps audio after history rows are lost"
            )
        }
    }

    private static func verifiesUnavailableHistoryBlocksMutatingActions() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let audioURL = environment.storageLayout.audioDirectory
                .appendingPathComponent("protected-audio.wav")
            let transcriptURL = environment.storageLayout.transcriptDirectory
                .appendingPathComponent("protected-transcript.txt")
            try Data("audio".utf8).write(to: audioURL)
            try Data("original transcript".utf8).write(to: transcriptURL)
            let unavailableStore = PipelineHistoryStore(
                storeURL: environment.storageLayout.historyStoreURL,
                persistentStoreLoader: { _ in
                    TestFailure("Injected protected history failure")
                }
            )
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = { url in
                url == environment.storageLayout.historyStoreURL
                    ? unavailableStore
                    : PipelineHistoryStore(storeURL: url)
            }

            let actionID = UUID()
            let summary = MeetingSummaryEnvelope(
                schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
                promptVersion: 1,
                generatedAt: Date(),
                sourceFingerprint: String(repeating: "a", count: 64),
                modelID: "summary/model",
                backendKind: .cloud,
                content: MeetingSummaryContent(
                    overview: MeetingSummaryEvidenceText(text: "Overview", sourceQuotes: []),
                    keyPoints: [],
                    decisions: [],
                    actionItems: [
                        MeetingSummaryActionItem(
                            id: actionID,
                            task: "Follow up",
                            owner: nil,
                            dueDate: nil,
                            sourceQuote: nil,
                            isCompleted: false
                        )
                    ],
                    openQuestions: []
                )
            )
            let item = PipelineHistoryItem(
                timestamp: Date(),
                rawTranscript: "original transcript",
                postProcessedTranscript: "original transcript",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "succeeded",
                debugStatus: "",
                customVocabulary: "",
                audioFileName: audioURL.lastPathComponent,
                transcriptFileName: transcriptURL.lastPathComponent
            ).withMeetingSummary(summary)
            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            var setActionCompletedThrew = false
            var deleteMeetingSummaryThrew = false
            let mcpRecordingStarted = await MainActor.run { () -> Bool in
                appState.pipelineHistory = [item]
                appState.clearPipelineHistory()
                appState.updateTranscript(id: item.id, text: "replacement transcript")
                appState.toggleRecording()
                appState.deleteHistoryEntry(id: item.id)
                appState.updateHistoryItemTitle(id: item.id, title: "replacement title")
                appState.retryTranscription(item: item)
                appState.transcriptionAPIKey = "protected-transcription-key"
                appState.importAudioFile(
                    URL(fileURLWithPath: "/nonexistent/protected-import.wav"),
                    choice: .apiStandard(modelID: "whisper-large-v3")
                )
                let recordingStarted = appState.startRecordingFromMCP()
                do {
                    // The item carries a real meeting summary with a matching
                    // action so a thrown error here is caused by history
                    // protection, not by the note lacking a summary to edit.
                    try appState.setMeetingSummaryActionCompleted(
                        noteID: item.id,
                        actionID: actionID,
                        isCompleted: true
                    )
                } catch {
                    setActionCompletedThrew = true
                }
                do {
                    try appState.deleteMeetingSummary(noteID: item.id)
                } catch {
                    deleteMeetingSummaryThrew = true
                }
                return recordingStarted
            }

            try expect(appState.isHistoryUnavailable, "history load failure enters protection mode")
            try expect(
                !mcpRecordingStarted,
                "protected history rejects an MCP-triggered recording start"
            )
            try expect(
                appState.pipelineHistory.map(\.id) == [item.id],
                "protected history mutations do not alter in-memory note ownership"
            )
            try expect(
                FileManager.default.fileExists(atPath: audioURL.path),
                "protected history clear does not delete audio"
            )
            let storedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
            try expect(
                storedTranscript == "original transcript",
                "protected history transcript edit does not write a sidecar"
            )
            try expect(!appState.isRecording, "protected history cannot start recording")
            try expect(setActionCompletedThrew, "protected history rejects meeting summary action updates")
            try expect(deleteMeetingSummaryThrew, "protected history rejects meeting summary deletion")
            try expect(
                appState.pipelineHistory.first?.meetingSummary?.content.actionItems.first?.isCompleted == false,
                "protected history keeps the existing meeting summary action state unchanged"
            )
        }
    }

    private static func verifiesExplicitArchiveCreatesFreshSeparatedHistory() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let storeURL = environment.storageLayout.historyStoreURL
            let originalSQLiteBytes = Data("unreadable original SQLite".utf8)
            try originalSQLiteBytes.write(to: storeURL)
            let audioURL = environment.storageLayout.audioDirectory.appendingPathComponent("archived.wav")
            let transcriptURL = environment.storageLayout.transcriptDirectory.appendingPathComponent("archived.txt")
            let cloudJobURL = environment.storageLayout.cloudTranscriptionJobsDirectory
                .appendingPathComponent("archived.json")
            try Data("archived audio".utf8).write(to: audioURL)
            try Data("archived transcript".utf8).write(to: transcriptURL)
            try FileManager.default.createDirectory(
                at: cloudJobURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("archived cloud job".utf8).write(to: cloudJobURL)

            let unavailableStore = PipelineHistoryStore(
                storeURL: storeURL,
                persistentStoreLoader: { _ in
                    TestFailure("Injected unavailable history for explicit archive")
                }
            )
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = makeUnavailableStartupStoreFactory(
                unavailableStore,
                startupURL: environment.storageLayout.historyStoreURL
            )

            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            let archiveSucceeded = await MainActor.run {
                appState.archiveOldHistoryAndStartFresh(postAction: .openRecovery)
            }

            try expect(archiveSucceeded, "explicit archive is accepted from protection mode")
            try await waitForArchiveCompletion(appState)
            try expect(!appState.isHistoryUnavailable, "verified fresh history leaves protection mode")
            try expect(
                appState.historyArchiveSafety == .unresolvedArchive,
                "published archive keeps automatic cleanup in its safe state"
            )
            try expect(
                appState.selectedSettingsTab == .recovery,
                "recovery post-action opens the recovery Settings section after a verified archive"
            )
            try expect(
                appState.historyPersistenceWarning == nil,
                "published archive does not keep a duplicate normal-history warning"
            )
            try expect(appState.pipelineHistory.isEmpty, "fresh history starts with no old notes")

            let recoveryDirectory = environment.rootDirectory.appendingPathComponent("Recovery", isDirectory: true)
            guard let snapshotDirectory = try FileManager.default.contentsOfDirectory(
                at: recoveryDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).first(where: { $0.lastPathComponent.hasPrefix("history-") }) else {
                throw TestFailure("explicit archive did not publish a recovery snapshot")
            }
            let payload = snapshotDirectory.appendingPathComponent("payload", isDirectory: true)
            let archivedSQLiteBytes = try Data(
                contentsOf: payload.appendingPathComponent("PipelineHistory.sqlite")
            )
            let archivedAudioBytes = try Data(
                contentsOf: payload.appendingPathComponent("audio/archived.wav")
            )
            let archivedTranscriptBytes = try Data(
                contentsOf: payload.appendingPathComponent("transcripts/archived.txt")
            )
            let archivedCloudJobBytes = try Data(
                contentsOf: payload.appendingPathComponent("cloud-transcription/jobs/archived.json")
            )
            try expect(
                archivedSQLiteBytes == originalSQLiteBytes,
                "archive preserves the original unavailable SQLite bytes"
            )
            try expect(
                archivedAudioBytes == Data("archived audio".utf8),
                "archive preserves old audio outside the active generation"
            )
            try expect(
                archivedTranscriptBytes == Data("archived transcript".utf8),
                "archive preserves old transcripts outside the active generation"
            )
            try expect(
                archivedCloudJobBytes == Data("archived cloud job".utf8),
                "archive preserves old cloud jobs outside the active generation"
            )

            let freshStore = PipelineHistoryStore(storeURL: storeURL)
            try expect(freshStore.availability == .ready, "active store is fresh and readable")
            try expect(freshStore.loadAllHistory().isEmpty, "active store contains no archive probe records")
            let freshItem = PipelineHistoryItem(
                timestamp: Date(),
                rawTranscript: "new generation",
                postProcessedTranscript: "new generation",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "succeeded",
                debugStatus: "",
                customVocabulary: ""
            )
            _ = try freshStore.upsert(freshItem, maxCount: Int.max)
            var relaunchDependencies = AppStateDependencies.live
            relaunchDependencies.storageLayout = environment.storageLayout
            let configuredRelaunchDependencies = relaunchDependencies

            let relaunchedAppState = await MainActor.run {
                AppState(dependencies: configuredRelaunchDependencies)
            }
            try expect(
                !relaunchedAppState.isHistoryUnavailable,
                "published archive does not turn the fresh active store into protection mode"
            )
            try expect(
                relaunchedAppState.pipelineHistory.map(\.id) == [freshItem.id],
                "published archive still loads the new active generation on restart"
            )

            let relaunchedAudioBytes = try Data(
                contentsOf: payload.appendingPathComponent("audio/archived.wav")
            )
            let relaunchedTranscriptBytes = try Data(
                contentsOf: payload.appendingPathComponent("transcripts/archived.txt")
            )
            let relaunchedCloudJobBytes = try Data(
                contentsOf: payload.appendingPathComponent("cloud-transcription/jobs/archived.json")
            )
            try expect(
                relaunchedAudioBytes == archivedAudioBytes
                    && relaunchedTranscriptBytes == archivedTranscriptBytes
                    && relaunchedCloudJobBytes == archivedCloudJobBytes,
                "restarting while a published archive is unresolved does not sweep or trim the archived generation"
            )
            let activeAudioFileCount = try FileManager.default.contentsOfDirectory(
                at: environment.storageLayout.audioDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).count
            try expect(
                activeAudioFileCount == 0,
                "restarting while a published archive is unresolved does not sweep the fresh active generation, which holds no audio yet"
            )
        }
    }

    private static func verifiesArchivedNoteImportsIntoFreshHistory() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let storeURL = environment.storageLayout.historyStoreURL
            let audioURL = environment.storageLayout.audioDirectory.appendingPathComponent("source.wav")
            let transcriptURL = environment.storageLayout.transcriptDirectory.appendingPathComponent("source.txt")
            try Data("source audio".utf8).write(to: audioURL)
            try Data("source transcript".utf8).write(to: transcriptURL)
            let sourceItem = PipelineHistoryItem(
                id: UUID(uuidString: "A3E4BA14-2F2E-4724-BFCF-1F8F1667E577")!,
                timestamp: Date(timeIntervalSince1970: 1_754_010_203),
                rawTranscript: "source transcript",
                postProcessedTranscript: "source transcript",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "succeeded",
                debugStatus: "",
                customVocabulary: "",
                audioFileName: audioURL.lastPathComponent,
                transcriptFileName: transcriptURL.lastPathComponent
            )
            let sourceStore = PipelineHistoryStore(storeURL: storeURL)
            _ = try sourceStore.upsert(
                sourceItem,
                maxCount: Int.max,
                requiresDurableStore: true
            )
            try sourceStore.detachForArchiveVerification()
            let unavailableStore = PipelineHistoryStore(
                storeURL: storeURL,
                persistentStoreLoader: { _ in
                    TestFailure("Injected unavailable history for import recovery")
                }
            )
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = makeUnavailableStartupStoreFactory(
                unavailableStore,
                startupURL: environment.storageLayout.historyStoreURL
            )

            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            let archiveAccepted = await MainActor.run {
                appState.archiveOldHistoryAndStartFresh()
            }
            try expect(archiveAccepted, "valid old history can enter the recovery archive flow")
            try await waitForArchiveCompletion(appState)
            let snapshotID = try await MainActor.run {
                guard let snapshotID = appState.historyRecoverySnapshots.first?.id else {
                    throw TestFailure("archive did not publish a recovery snapshot catalog entry")
                }
                return snapshotID
            }
            let importAccepted = await MainActor.run {
                appState.importHistoryRecoverySnapshot(id: snapshotID)
            }
            try expect(importAccepted, "recovery import is accepted after the fresh history is ready")
            try await waitForHistoryRecoveryCompletion(appState)

            let importedItem = try await MainActor.run {
                guard let item = appState.pipelineHistory.first(where: { $0.id == sourceItem.id }) else {
                    throw TestFailure("recovery import did not restore the archived note")
                }
                return item
            }
            try expect(
                importedItem.audioFileName != sourceItem.audioFileName
                    && importedItem.transcriptFileName != sourceItem.transcriptFileName,
                "AppState recovery import remaps active asset ownership"
            )
            let copiedAudioURL = environment.storageLayout.audioDirectory.appendingPathComponent(
                try required(importedItem.audioFileName)
            )
            let copiedTranscriptURL = environment.storageLayout.transcriptDirectory.appendingPathComponent(
                try required(importedItem.transcriptFileName)
            )
            let copiedAudio = try Data(contentsOf: copiedAudioURL)
            let copiedTranscript = try Data(contentsOf: copiedTranscriptURL)
            try expect(
                copiedAudio == Data("source audio".utf8)
                    && copiedTranscript == Data("source transcript".utf8),
                "AppState recovery import copies archive assets to the fresh generation"
            )
            let recoveryCompleted = await MainActor.run {
                appState.historyRecoverySnapshots.first?.state?.status == .completed
            }
            try expect(
                recoveryCompleted,
                "successful AppState import marks the archive complete for retention"
            )
            let cancellationAccepted = await MainActor.run {
                appState.cancelHistoryRecoveryScheduledDeletion(id: snapshotID)
            }
            try expect(cancellationAccepted, "completed snapshot can cancel automatic deletion")
            try await waitForHistoryRecoveryCompletion(appState)
            let deletionCancelled = await MainActor.run {
                appState.historyRecoverySnapshots.first?.scheduledDeletionAt == nil
            }
            try expect(deletionCancelled, "cancelled deletion remains visible in AppState")
            let deletionAccepted = await MainActor.run {
                appState.deleteHistoryRecoverySnapshot(id: snapshotID)
            }
            try expect(deletionAccepted, "explicit recovery snapshot deletion is accepted")
            try await waitForHistoryRecoveryCompletion(appState)
            let recoveryRemoved = await MainActor.run {
                appState.historyRecoverySnapshots.isEmpty
                    && appState.pipelineHistory.contains(where: { $0.id == sourceItem.id })
            }
            try expect(
                recoveryRemoved,
                "deleting a snapshot leaves the active imported history intact"
            )
        }
    }

    private static func verifiesRecoverySettingsAutomaticallyInspectsSnapshots() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let storeURL = environment.storageLayout.historyStoreURL
            let sourceItem = PipelineHistoryItem(
                id: UUID(uuidString: "4B5A73C8-59D4-4FDF-ABF7-2CD61094E3A8")!,
                timestamp: Date(timeIntervalSince1970: 1_754_010_203),
                rawTranscript: "automatic inspection source",
                postProcessedTranscript: "automatic inspection source",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "succeeded",
                debugStatus: "",
                customVocabulary: ""
            )
            let sourceStore = PipelineHistoryStore(storeURL: storeURL)
            _ = try sourceStore.upsert(
                sourceItem,
                maxCount: Int.max,
                requiresDurableStore: true
            )
            try sourceStore.detachForArchiveVerification()
            let unavailableStore = PipelineHistoryStore(
                storeURL: storeURL,
                persistentStoreLoader: { _ in
                    TestFailure("Injected unavailable history for automatic inspection")
                }
            )
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = makeUnavailableStartupStoreFactory(
                unavailableStore,
                startupURL: environment.storageLayout.historyStoreURL
            )

            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            let archiveAccepted = await MainActor.run {
                appState.archiveOldHistoryAndStartFresh(postAction: .openRecovery)
            }
            try expect(archiveAccepted, "automatic inspection fixture enters the archive recovery route")
            try await waitForArchiveCompletion(appState)
            let snapshotID = try await MainActor.run {
                guard let snapshotID = appState.historyRecoverySnapshots.first?.id else {
                    throw TestFailure("automatic inspection archive snapshot is missing")
                }
                return snapshotID
            }
            try await waitForHistoryRecoveryInspection(appState, snapshotID: snapshotID)

            let inspection = try await MainActor.run {
                guard let inspection = appState.historyRecoveryInspections[snapshotID] else {
                    throw TestFailure("Recovery settings did not inspect the archive automatically")
                }
                return inspection
            }
            try expect(
                inspection.readableRecordCount == 1 && inspection.importableRecordCount == 1,
                "Recovery settings automatically show the archived record count"
            )
            let recoveryWriteIsIdle = await MainActor.run {
                !appState.isHistoryRecoveryOperationInProgress
            }
            try expect(
                recoveryWriteIsIdle,
                "read-only automatic inspection never enters the active-history write gate"
            )
        }
    }

    private static func verifiesInterruptedArchiveKeepsHistoryProtected() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            _ = PipelineHistoryStore(storeURL: environment.storageLayout.historyStoreURL)
            let transactionDirectory = environment.rootDirectory
                .appendingPathComponent("Recovery/.transactions", isDirectory: true)
            try FileManager.default.createDirectory(
                at: transactionDirectory,
                withIntermediateDirectories: true
            )
            try Data("corrupt interrupted archive transaction".utf8).write(
                to: transactionDirectory.appendingPathComponent("interrupted.json")
            )

            let appState = await MainActor.run {
                AppState(dependencies: environment.dependencies)
            }

            try expect(
                appState.historyArchiveSafety == .unresolvedInterruptedTransaction,
                "unreadable transaction journal remains explicitly unresolved"
            )
            try expect(
                appState.isHistoryUnavailable,
                "unresolved archive transaction blocks history mutations even with a readable store"
            )
            try expect(
                appState.historyPersistenceWarning?.code == .historyPersistenceUnavailable,
                "unresolved archive transaction shows the protected-history warning"
            )
            let archiveAccepted = await MainActor.run {
                appState.archiveOldHistoryAndStartFresh()
            }
            try expect(
                !archiveAccepted,
                "an unresolved interrupted transaction rejects the archive-and-start-fresh recovery action"
            )
        }
    }

    private static func verifiesMissingSnapshotWithUnreferencedAudioDoesNotSweep() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let historyStore = PipelineHistoryStore(
                storeURL: environment.storageLayout.historyStoreURL
            )
            let referencedAudioURL = environment.storageLayout.audioDirectory
                .appendingPathComponent("still-referenced.wav")
            let unreferencedAudioURL = environment.storageLayout.audioDirectory
                .appendingPathComponent("history-row-lost-without-snapshot.wav")
            for fileURL in [referencedAudioURL, unreferencedAudioURL] {
                try Data("fixture".utf8).write(to: fileURL)
                try setOldModificationDate(of: fileURL)
            }
            _ = try historyStore.upsert(
                PipelineHistoryItem(
                    timestamp: Date(),
                    rawTranscript: "fixture",
                    postProcessedTranscript: "fixture",
                    postProcessingPrompt: nil,
                    contextSummary: "",
                    contextScreenshotDataURL: nil,
                    contextScreenshotStatus: "No screenshot",
                    postProcessingStatus: "succeeded",
                    debugStatus: "",
                    customVocabulary: "",
                    audioFileName: referencedAudioURL.lastPathComponent
                ),
                maxCount: 10
            )

            _ = await MainActor.run { AppState(dependencies: environment.dependencies) }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            _ = await MainActor.run { AppState(dependencies: environment.dependencies) }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            try expect(
                FileManager.default.fileExists(atPath: unreferencedAudioURL.path),
                "a missing snapshot never sweeps audio absent from the loaded history"
            )
        }
    }

    private static func verifiesMatchingHistorySnapshotSweepsOrphansAtStartup() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let historyStore = PipelineHistoryStore(
                storeURL: environment.storageLayout.historyStoreURL
            )
            try historyStore.saveAssetReferenceSnapshot(
                audioFileNames: [],
                transcriptFileNames: []
            )
            let audioURL = environment.storageLayout.audioDirectory
                .appendingPathComponent("known-orphan.wav")
            try Data("fixture".utf8).write(to: audioURL)
            try setOldModificationDate(of: audioURL)

            _ = await MainActor.run { AppState(dependencies: environment.dependencies) }
            try await waitForFileRemoval(at: audioURL)
            try expect(
                !FileManager.default.fileExists(atPath: audioURL.path),
                "matching history snapshots sweep old unreferenced audio at startup"
            )
        }
    }

    private static func verifiesTrustedHistorySweepsOrphans() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let historyStore = PipelineHistoryStore(
                storeURL: environment.storageLayout.historyStoreURL
            )
            try expect(
                historyStore.referenceTrust == .complete,
                "new persistent history is trusted before recording files exist"
            )
            let audioDirectory = environment.storageLayout.audioDirectory
            let transcriptDirectory = environment.storageLayout.transcriptDirectory
            let audioURL = audioDirectory.appendingPathComponent("trusted-orphan.wav")
            let transcriptURL = transcriptDirectory.appendingPathComponent("trusted-orphan.txt")
            for fileURL in [audioURL, transcriptURL] {
                try Data("fixture".utf8).write(to: fileURL)
            }

            NoteAssetStore(
                storageLayout: environment.storageLayout
            ).sweepOrphans(
                referencedAudioFileNames: [],
                referencedTranscriptFileNames: [],
                protectedInflightAudioFileNames: [],
                referenceTrust: .complete,
                now: Date(timeIntervalSinceNow: 301)
            )
            try expect(
                !FileManager.default.fileExists(atPath: audioURL.path),
                "trusted history removes old unreferenced audio at startup"
            )
            try expect(
                !FileManager.default.fileExists(atPath: transcriptURL.path),
                "trusted history removes old unreferenced transcripts at startup"
            )
        }
    }

    private static func verifiesArchiveCompletionAllowsImmediateAssetSavesWithoutRestart() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let storeURL = environment.storageLayout.historyStoreURL
            try Data("unreadable original SQLite".utf8).write(to: storeURL)
            let unavailableStore = PipelineHistoryStore(
                storeURL: storeURL,
                persistentStoreLoader: { _ in
                    TestFailure("Injected unavailable history for restart-free save")
                }
            )
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = makeUnavailableStartupStoreFactory(
                unavailableStore,
                startupURL: environment.storageLayout.historyStoreURL
            )

            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            let archiveAccepted = await MainActor.run {
                appState.archiveOldHistoryAndStartFresh()
            }
            try expect(archiveAccepted, "archive from protection mode is accepted")
            try await waitForArchiveCompletion(appState)
            try expect(
                !appState.isHistoryUnavailable,
                "verified fresh history leaves protection mode"
            )

            let sourceURL = environment.rootDirectory.appendingPathComponent("restart-free-import.wav")
            try Data("fixture audio".utf8).write(to: sourceURL)
            await MainActor.run {
                appState.transcriptionAPIKey = "restart-free-key"
                appState.importAudioFile(sourceURL, choice: .apiStandard(modelID: "whisper-large-v3"))
            }

            try await waitUntil {
                await MainActor.run { !appState.pipelineHistory.isEmpty }
            }
            let importedAudioFileName = try await MainActor.run { () -> String in
                guard let fileName = appState.pipelineHistory.first?.audioFileName else {
                    throw TestFailure(
                        "archive completion did not accept a new audio import without a restart"
                    )
                }
                return fileName
            }
            let importedAudioURL = environment.storageLayout.audioDirectory
                .appendingPathComponent(importedAudioFileName)
            try expect(
                FileManager.default.fileExists(atPath: importedAudioURL.path),
                "archive completion recreates the active audio directory so imports succeed immediately"
            )

            let transcriptFileName = "restart-free-transcript-\(UUID().uuidString).txt"
            await MainActor.run {
                guard let originalItem = appState.pipelineHistory.first else { return }
                let noteItem = originalItem.replacingAssetFileNames(
                    audioFileName: originalItem.audioFileName,
                    transcriptFileName: transcriptFileName
                )
                appState.pipelineHistory = [noteItem]
                appState.updateTranscript(id: noteItem.id, text: "restart-free transcript")
            }
            let importedTranscriptURL = environment.storageLayout.transcriptDirectory
                .appendingPathComponent(transcriptFileName)
            let writtenTranscript = try String(contentsOf: importedTranscriptURL, encoding: .utf8)
            try expect(
                writtenTranscript == "restart-free transcript",
                "archive completion recreates the active transcript directory so transcript writes succeed immediately"
            )
        }
    }

    private static func verifiesRecoveryOperationInProgressBlocksMutation() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let storeURL = environment.storageLayout.historyStoreURL
            let sourceItem = PipelineHistoryItem(
                id: UUID(uuidString: "9B1D9E3E-1C40-4B62-9B62-9C0E7E9C2F20")!,
                timestamp: Date(timeIntervalSince1970: 1_754_010_203),
                rawTranscript: "recovery-in-progress source",
                postProcessedTranscript: "recovery-in-progress source",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "succeeded",
                debugStatus: "",
                customVocabulary: ""
            )
            let sourceStore = PipelineHistoryStore(storeURL: storeURL)
            _ = try sourceStore.upsert(
                sourceItem,
                maxCount: Int.max,
                requiresDurableStore: true
            )
            try sourceStore.detachForArchiveVerification()
            let unavailableStore = PipelineHistoryStore(
                storeURL: storeURL,
                persistentStoreLoader: { _ in
                    TestFailure("Injected unavailable history for recovery-in-progress fixture")
                }
            )
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = makeUnavailableStartupStoreFactory(
                unavailableStore,
                startupURL: environment.storageLayout.historyStoreURL
            )

            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            let archiveAccepted = await MainActor.run {
                appState.archiveOldHistoryAndStartFresh()
            }
            try expect(
                archiveAccepted,
                "recovery-in-progress fixture enters the archive recovery route"
            )
            try await waitForArchiveCompletion(appState)

            let snapshotID = try await MainActor.run { () -> UUID in
                guard let snapshotID = appState.historyRecoverySnapshots.first?.id else {
                    throw TestFailure(
                        "archive did not publish a recovery snapshot for the recovery-in-progress fixture"
                    )
                }
                return snapshotID
            }

            let freshItem = PipelineHistoryItem(
                timestamp: Date(),
                rawTranscript: "active generation note",
                postProcessedTranscript: "active generation note",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "succeeded",
                debugStatus: "",
                customVocabulary: ""
            )
            let (deletionAccepted, historyUnchangedWhileRecovering) = await MainActor.run { () -> (Bool, Bool) in
                appState.pipelineHistory = [freshItem]
                // Starting the recovery-snapshot delete flips
                // isHistoryRecoveryOperationInProgress synchronously, before its
                // detached work runs. A mutation attempted in this same
                // synchronous window must observe the in-progress guard.
                let deletionAccepted = appState.deleteHistoryRecoverySnapshot(id: snapshotID)
                appState.clearPipelineHistory()
                let historyUnchanged = appState.pipelineHistory.map(\.id) == [freshItem.id]
                return (deletionAccepted, historyUnchanged)
            }
            try expect(deletionAccepted, "a real recovery-snapshot deletion is accepted")
            try expect(
                historyUnchangedWhileRecovering,
                "a mutation attempted while a recovery operation is in progress is rejected"
            )

            try await waitForHistoryRecoveryCompletion(appState)
            try expect(
                appState.historyRecoverySnapshots.isEmpty,
                "the recovery operation completes normally once it is allowed to run"
            )
        }
    }

    private static func verifiesSnapshotOnlyRecoveryFailureLeavesActiveStoreUntouched() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try prepareStorageDirectories(for: environment.storageLayout)
            let storeURL = environment.storageLayout.historyStoreURL
            let sourceItem = PipelineHistoryItem(
                id: UUID(uuidString: "6D1E9E3E-9C40-4B62-9B62-9C0E7E9C2F10")!,
                timestamp: Date(timeIntervalSince1970: 1_754_010_203),
                rawTranscript: "snapshot-only failure source",
                postProcessedTranscript: "snapshot-only failure source",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "succeeded",
                debugStatus: "",
                customVocabulary: ""
            )
            let sourceStore = PipelineHistoryStore(storeURL: storeURL)
            _ = try sourceStore.upsert(
                sourceItem,
                maxCount: Int.max,
                requiresDurableStore: true
            )
            try sourceStore.detachForArchiveVerification()
            let unavailableStore = PipelineHistoryStore(
                storeURL: storeURL,
                persistentStoreLoader: { _ in
                    TestFailure("Injected unavailable history for snapshot-only failure")
                }
            )
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = makeUnavailableStartupStoreFactory(
                unavailableStore,
                startupURL: environment.storageLayout.historyStoreURL
            )

            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            let archiveAccepted = await MainActor.run {
                appState.archiveOldHistoryAndStartFresh()
            }
            try expect(archiveAccepted, "snapshot-only fixture enters the archive recovery route")
            try await waitForArchiveCompletion(appState)

            let snapshotID = try await MainActor.run { () -> UUID in
                guard let snapshotID = appState.historyRecoverySnapshots.first?.id else {
                    throw TestFailure(
                        "archive did not publish a recovery snapshot for the snapshot-only fixture"
                    )
                }
                return snapshotID
            }
            let recoveryDirectory = environment.rootDirectory
                .appendingPathComponent("Recovery", isDirectory: true)
            let snapshotDirectories = try FileManager.default.contentsOfDirectory(
                at: recoveryDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasPrefix("history-") }
            guard let snapshotDirectory = snapshotDirectories.first else {
                throw TestFailure("snapshot-only fixture is missing its on-disk directory")
            }
            try FileManager.default.removeItem(at: snapshotDirectory)

            let deletionAccepted = await MainActor.run {
                appState.deleteHistoryRecoverySnapshot(id: snapshotID)
            }
            try expect(
                deletionAccepted,
                "AppState still accepts the request using its cached snapshot catalog"
            )
            try await waitForHistoryRecoveryCompletion(appState)

            try expect(
                appState.errorMessage == "Recovery snapshot operation could not be completed.",
                "a snapshot-only failure surfaces its own error rather than a silent success"
            )
            try expect(
                !appState.isHistoryUnavailable,
                "a snapshot-only failure does not put the active history into protection mode"
            )
            try expect(
                appState.historyRecoverySnapshots.isEmpty,
                "a snapshot-only failure still refreshes the catalog from disk"
            )

            let relaunchedAppState = await MainActor.run {
                AppState(dependencies: environment.dependencies)
            }
            try expect(
                !relaunchedAppState.isHistoryUnavailable,
                "a snapshot-only failure does not corrupt or replace the active Core Data store"
            )
            try expect(
                relaunchedAppState.pipelineHistory.isEmpty,
                "a snapshot-only failure does not resurrect the archived generation in the active store"
            )
        }
    }

    private static func verifiesFallbackHistoryDoesNotSweepStoredAudio(
        environment: AppStateTestEnvironment
    ) async throws -> URL {
        let audioURL = environment.storageLayout.audioDirectory
            .appendingPathComponent("fallback-history.wav")
        try Data("fixture".utf8).write(to: audioURL)
        try setOldModificationDate(of: audioURL)

        let fallbackStore = PipelineHistoryStore(
            storeURL: environment.rootDirectory.appendingPathComponent("FallbackHistory.sqlite"),
            persistentStoreLoader: { _ in
                TestFailure("Injected history load failure")
            }
        )
        var dependencies = environment.dependencies
        dependencies.makePipelineHistoryStore = { url in
            url == environment.storageLayout.historyStoreURL
                ? fallbackStore
                : PipelineHistoryStore(storeURL: url)
        }

        let configuredDependencies = dependencies
        _ = await MainActor.run { AppState(dependencies: configuredDependencies) }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        try expect(
            FileManager.default.fileExists(atPath: audioURL.path),
            "fallback history never sweeps existing audio"
        )
        return audioURL
    }

    private static func verifiesMissingHistoryDoesNotSweepStoredAudio(
        audioURL: URL,
        environment: AppStateTestEnvironment
    ) async throws {
        _ = await MainActor.run { AppState(dependencies: environment.dependencies) }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        try expect(
            FileManager.default.fileExists(atPath: audioURL.path),
            "a missing history database never sweeps existing audio"
        )
        try expect(
            FileManager.default.fileExists(
                atPath: environment.rootDirectory
                    .appendingPathComponent(
                        "History Recovery/asset-references-incomplete",
                        isDirectory: true
                    ).path
            ),
            "missing history records persistent incomplete-reference evidence"
        )
    }

    private static func makeUnavailableStartupStoreFactory(
        _ unavailableStore: PipelineHistoryStore,
        startupURL: URL
    ) -> @Sendable (URL) -> PipelineHistoryStore {
        let state = UnavailableStartupStoreFactoryState(startupURL: startupURL)
        return { url in
            state.makeStore(for: url, unavailableStore: unavailableStore)
        }
    }

    private static func prepareStorageDirectories(
        for storageLayout: AppStateStorageLayout
    ) throws {
        for directory in [
            storageLayout.audioDirectory,
            storageLayout.transcriptDirectory,
            storageLayout.cloudTranscriptionJobsDirectory
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    private static func waitUntil(
        timeoutSeconds: Double = 6,
        failureMessage: @autoclosure () -> String = "condition did not become true within the test timeout",
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw TestFailure(failureMessage())
    }

    private static func waitForArchiveCompletion(_ appState: AppState) async throws {
        try await waitUntil(
            failureMessage: "archive transition completes within the test timeout"
        ) {
            await MainActor.run { !appState.isHistoryArchiveTransitioning }
        }
    }

    private static func waitForHistoryRecoveryCompletion(_ appState: AppState) async throws {
        try await waitUntil(
            failureMessage: "history recovery operation completes within the test timeout"
        ) {
            await MainActor.run { !appState.isHistoryRecoveryOperationInProgress }
        }
    }

    private static func waitForHistoryRecoveryInspection(
        _ appState: AppState,
        snapshotID: UUID
    ) async throws {
        try await waitUntil(
            failureMessage: "automatic recovery inspection did not complete within the test timeout"
        ) {
            await MainActor.run {
                appState.historyRecoveryInspectionSnapshotID == nil
                    && appState.historyRecoveryInspections[snapshotID] != nil
            }
        }
    }

    private static func waitForFileRemoval(at fileURL: URL) async throws {
        try await waitUntil(
            failureMessage: "\(fileURL.lastPathComponent) was not removed within the test timeout"
        ) {
            !FileManager.default.fileExists(atPath: fileURL.path)
        }
    }

    private static func setOldModificationDate(of fileURL: URL) throws {
        let seconds = time_t(Date(timeIntervalSinceNow: -301).timeIntervalSince1970)
        var timestamps = [
            timeval(tv_sec: seconds, tv_usec: 0),
            timeval(tv_sec: seconds, tv_usec: 0)
        ]
        let result = fileURL.withUnsafeFileSystemRepresentation { path in
            utimes(path, &timestamps)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw TestFailure("missing required value") }
        return value
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }

    private final class HistoryStoreURLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        var isEmpty: Bool {
            lock.withLock { urls.isEmpty }
        }

        func record(_ url: URL) {
            lock.withLock { urls.append(url) }
        }

        func contains(_ url: URL) -> Bool {
            lock.withLock { urls.contains(url) }
        }

        func count(of url: URL) -> Int {
            lock.withLock { urls.filter { $0 == url }.count }
        }
    }

    private final class UnavailableStartupStoreFactoryState: @unchecked Sendable {
        private let lock = NSLock()
        private let startupURL: URL
        private var didReturnUnavailableStore = false

        init(startupURL: URL) {
            self.startupURL = startupURL
        }

        func makeStore(
            for url: URL,
            unavailableStore: PipelineHistoryStore
        ) -> PipelineHistoryStore {
            lock.lock()
            defer { lock.unlock() }
            guard url == startupURL, !didReturnUnavailableStore else {
                return PipelineHistoryStore(storeURL: url)
            }
            didReturnUnavailableStore = true
            return unavailableStore
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
