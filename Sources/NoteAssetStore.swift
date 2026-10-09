import Foundation

enum NoteAssetStoreError: Error {
    case audioSaveFailed(underlying: Error)
    case transcriptSaveFailed(underlying: Error)
    case transcriptLoadFailed(underlying: Error)
}

/// The instance-owned filesystem boundary for note audio and transcript
/// assets under an `AppStateStorageLayout`.
///
/// Workflow decisions remain in `AppState`: history ownership, shared
/// references, recording-journal protection, and cleanup ordering. This store
/// receives those decisions as explicit file names and performs only path
/// resolution, persistence, deletion, and orphan sweeping.
struct NoteAssetStore: Sendable {
    let storageLayout: AppStateStorageLayout

    /// Directory preparation intentionally stays best-effort, matching the
    /// existing `AppState` directory-preparation contract established when
    /// instance-owned storage layouts were introduced: callers proceed with
    /// the directory URL regardless of creation success, and the subsequent
    /// save/load operation is what surfaces a failure.
    @discardableResult
    func prepareDirectories() -> (audioDirectory: URL, transcriptDirectory: URL) {
        (
            Self.preparedDirectory(storageLayout.audioDirectory),
            Self.preparedDirectory(storageLayout.transcriptDirectory)
        )
    }

    func saveAudio(from tempURL: URL) throws -> AppState.SavedAudioFile {
        let fileName = UUID().uuidString + "." + AudioImportOptions.storageExtension(
            for: tempURL.lastPathComponent
        )
        let destURL = storageLayout.audioDirectory.appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            do {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: destURL.path
                )
            } catch {
                try? FileManager.default.removeItem(at: destURL)
                throw error
            }
            return AppState.SavedAudioFile(fileName: fileName, fileURL: destURL)
        } catch {
            throw NoteAssetStoreError.audioSaveFailed(underlying: error)
        }
    }

    func adoptOrSaveStoppedAudio(
        from fileURL: URL
    ) throws -> AppState.SavedAudioFile {
        let audioDirectory = storageLayout.audioDirectory.standardizedFileURL
        let standardizedURL = fileURL.standardizedFileURL
        guard standardizedURL.deletingLastPathComponent() == audioDirectory,
              standardizedURL.pathExtension.lowercased() == "wav",
              (try? RecordingCanonicalWAV.validateFile(at: standardizedURL)) != nil else {
            return try saveAudio(from: fileURL)
        }
        return AppState.SavedAudioFile(
            fileName: standardizedURL.lastPathComponent,
            fileURL: standardizedURL
        )
    }

    func saveSecurityScopedAudio(from fileURL: URL) async throws -> AppState.SavedAudioFile {
        try await Task.detached(priority: .userInitiated) {
            let accessGranted = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            return try self.saveAudio(from: fileURL)
        }.value
    }

    func deleteAudio(fileName: String) throws {
        guard let fileURL = Self.storedFileURL(
            fileName: fileName,
            in: storageLayout.audioDirectory
        ) else {
            return
        }
        try Self.removeItemIfPresent(at: fileURL)
    }

    func saveTranscript(
        rawTranscript: String,
        postProcessedTranscript: String
    ) throws -> String {
        let fileName = UUID().uuidString + ".txt"
        let fileURL = storageLayout.transcriptDirectory.appendingPathComponent(fileName)
        let content = postProcessedTranscript.isEmpty ? rawTranscript : postProcessedTranscript
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileName
        } catch {
            throw NoteAssetStoreError.transcriptSaveFailed(underlying: error)
        }
    }

    /// Writes a transcript file under the name another Mac gave it. Names
    /// are a UUID plus `.txt`; anything else is refused.
    func writeTranscript(fileName: String, content: String) throws {
        guard fileName.hasSuffix(".txt"),
              UUID(uuidString: String(fileName.dropLast(4))) != nil,
              let fileURL = Self.storedFileURL(
                  fileName: fileName,
                  in: prepareDirectories().transcriptDirectory
              ) else {
            throw NoteAssetStoreError.transcriptSaveFailed(
                underlying: CocoaError(.fileWriteInvalidFileName)
            )
        }
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw NoteAssetStoreError.transcriptSaveFailed(underlying: error)
        }
    }

    func loadTranscript(fileName: String) throws -> String {
        guard let fileURL = Self.storedFileURL(
            fileName: fileName,
            in: storageLayout.transcriptDirectory
        ) else {
            throw NoteAssetStoreError.transcriptLoadFailed(
                underlying: CocoaError(.fileReadInvalidFileName)
            )
        }
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw NoteAssetStoreError.transcriptLoadFailed(underlying: error)
        }
    }

    func deleteTranscript(fileName: String) throws {
        guard let fileURL = Self.storedFileURL(
            fileName: fileName,
            in: storageLayout.transcriptDirectory
        ) else {
            return
        }
        try Self.removeItemIfPresent(at: fileURL)
    }

    /// Attempts both deletions independently — matching the existing
    /// best-effort semantics of `AppState`'s asset cleanup — so a failure
    /// deleting one asset never skips the other. If either deletion fails,
    /// the first failure is thrown after both have been attempted.
    func deleteAssets(audioFileName: String?, transcriptFileName: String?) throws {
        var firstError: Error?
        if let audioFileName {
            do {
                try deleteAudio(fileName: audioFileName)
            } catch {
                firstError = error
            }
        }
        if let transcriptFileName {
            do {
                try deleteTranscript(fileName: transcriptFileName)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    func sweepOrphans(
        referencedAudioFileNames: Set<String>,
        referencedTranscriptFileNames: Set<String>,
        protectedInflightAudioFileNames: Set<String> = [],
        referenceTrust: PipelineHistoryReferenceTrust,
        now: Date = Date()
    ) {
        guard referenceTrust.permitsStartupReferenceCleanup else { return }

        sweepOrphans(
            in: storageLayout.audioDirectory,
            referencedFileNames: referencedAudioFileNames,
            protectedFileNames: protectedInflightAudioFileNames.union(["inflight"]),
            now: now
        )
        sweepOrphans(
            in: storageLayout.transcriptDirectory,
            referencedFileNames: referencedTranscriptFileNames,
            protectedFileNames: [],
            now: now
        )
    }

    func storedAudioURL(for item: PipelineHistoryItem) -> URL? {
        item.audioFileName.flatMap(storedAudioURL(fileName:))
    }

    /// Where a note's audio file lives, after the safe-name check. The file
    /// may not exist.
    func storedAudioURL(fileName: String) -> URL? {
        Self.storedFileURL(fileName: fileName, in: storageLayout.audioDirectory)
    }

    private func sweepOrphans(
        in directory: URL,
        referencedFileNames: Set<String>,
        protectedFileNames: Set<String>,
        now: Date
    ) {
        let fileManager = FileManager.default
        let gracePeriod: TimeInterval = 300
        guard let fileNames = try? fileManager.contentsOfDirectory(
            atPath: directory.path
        ) else {
            return
        }
        for fileName in fileNames
        where !referencedFileNames.contains(fileName)
            && !protectedFileNames.contains(fileName) {
            let fileURL = directory.appendingPathComponent(fileName)
            guard let attributes = try? fileManager.attributesOfItem(
                atPath: fileURL.path
            ),
            let modificationDate = attributes[.modificationDate] as? Date,
            now.timeIntervalSince(modificationDate) > gracePeriod else {
                continue
            }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private static func storedFileURL(
        fileName: String,
        in directory: URL
    ) -> URL? {
        guard !fileName.isEmpty,
              URL(fileURLWithPath: fileName).lastPathComponent == fileName,
              !fileName.contains("/"),
              !fileName.contains("\\") else {
            return nil
        }
        return directory.appendingPathComponent(fileName)
    }

    private static func preparedDirectory(_ directory: URL) -> URL {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory
    }

    /// Deleting an already-missing file is treated as success (matching the
    /// idempotent delete semantics used throughout `AppState`'s existing
    /// asset cleanup). Any other failure — permissions, a read-only volume,
    /// a directory that cannot be removed — propagates to the caller.
    private static func removeItemIfPresent(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError {
                return
            }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
                return
            }
            throw error
        }
    }
}
