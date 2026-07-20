import AVFoundation
import CryptoKit
import Foundation
import Speech
import os.log

private let transcriptionLog = OSLog(subsystem: "com.woosublee.quill", category: "Transcription")

struct CloudTranscriptionDependencies: Sendable {
    let encodedUploadCeilingBytes: UInt64
    let upload: @Sendable (URLRequest, Data) async throws -> (Data, URLResponse)
    let checkpointStore: any CloudTranscriptionCheckpointStore
    let progress: @Sendable (CloudTranscriptionProgress) -> Void
    let temporaryRoot: URL
    let sleep: @Sendable (TimeInterval) async throws -> Void

    static var live: CloudTranscriptionDependencies {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "com.woosublee.quill",
                isDirectory: true
            )
            .appendingPathComponent("cloud-transcription", isDirectory: true)
        return CloudTranscriptionDependencies(
            encodedUploadCeilingBytes: 20_000_000,
            upload: { request, body in
                try await LLMAPITransport.upload(for: request, from: body)
            },
            checkpointStore: InMemoryCloudTranscriptionCheckpointStore(),
            progress: { _ in },
            temporaryRoot: temporaryRoot,
            sleep: { seconds in
                try await Task.sleep(for: .seconds(seconds))
            }
        )
    }
}

class TranscriptionService {
    private static let modelsSupportingVerboseJSON: Set<String> = [
        "whisper-1",
        "whisper-large-v3",
        "whisper-large-v3-turbo"
    ]

    private let apiKey: String
    private let baseURL: URL
    private let useLocalTranscription: Bool
    private let localWhisperPath: String?
    private let useLegacyMlxWhisper: Bool
    private let transcriptionLanguage: TranscriptionLanguage
    private let localTranscriptionModel: TranscriptionModel
    private let transcriptionModel: String
    private let language: String?
    private let cloudDependencies: CloudTranscriptionDependencies
    private let cloudExecutionContext: CloudTranscriptionExecutionContext?
    private var transcriptionResponseFormat: String {
        Self.responseFormat(forModel: transcriptionModel)
    }
    private var transcriptionTimeoutSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "transcription_timeout_seconds")
        return override > 0 ? override : 20
    }
    private let localTranscriptionTimeoutSeconds: TimeInterval = 3600

    init(
        apiKey: String,
        baseURL: String = "https://api.groq.com/openai/v1",
        useLocalTranscription: Bool = false,
        localWhisperPath: String? = nil,
        useLegacyMlxWhisper: Bool = false,
        transcriptionLanguage: TranscriptionLanguage = .auto,
        localTranscriptionModel: TranscriptionModel = .default,
        transcriptionModel: String = AppState.defaultTranscriptionModel,
        language: String? = nil,
        cloudDependencies: CloudTranscriptionDependencies = .live,
        cloudExecutionContext: CloudTranscriptionExecutionContext? = nil
    ) throws {
        self.apiKey = apiKey
        self.baseURL = try CloudTranscriptionExecutionSnapshot.normalizedBaseURL(
            from: baseURL
        )
        self.useLocalTranscription = useLocalTranscription
        self.localWhisperPath = localWhisperPath
        self.useLegacyMlxWhisper = useLegacyMlxWhisper
        self.transcriptionLanguage = transcriptionLanguage
        self.localTranscriptionModel = localTranscriptionModel
        let trimmedModel = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transcriptionModel = trimmedModel.isEmpty ? AppState.defaultTranscriptionModel : trimmedModel
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = (trimmedLanguage?.isEmpty == false)
            ? trimmedLanguage
            : transcriptionLanguage.whisperArgument
        self.cloudDependencies = cloudDependencies
        self.cloudExecutionContext = cloudExecutionContext
    }

    static func responseFormat(forModel model: String) -> String {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return modelsSupportingVerboseJSON.contains(normalizedModel) ? "verbose_json" : "json"
    }

    static func appleSpeechAuthorizationIssue(
        for status: SFSpeechRecognizerAuthorizationStatus
    ) -> QuillUserIssueError? {
        guard status != .authorized else { return nil }
        return QuillUserIssueError.local(
            code: .speechRecognitionPermissionDenied,
            backend: "Apple Speech",
            diagnostic: "SFSpeechRecognizer authorization status \(status.rawValue)"
        )
    }

    // Validate API key by hitting a lightweight endpoint
    static func validateAPIKey(_ key: String, baseURL: String = AppState.defaultAPIBaseURL) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let baseURL = try? CloudTranscriptionExecutionSnapshot
            .normalizedBaseURL(from: baseURL) else {
            return false
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await LLMAPITransport.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200
        } catch {
            return false
        }
    }

    // Upload audio file, submit for transcription, poll until done, return text
    func transcribe(fileURL: URL) async throws -> String {
        do {
            return try await performTranscription(fileURL: fileURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let issue as QuillUserIssueError {
            throw issue
        } catch {
            throw classifiedIssue(for: error)
        }
    }

    private func performTranscription(fileURL: URL) async throws -> String {
        guard !Task.isCancelled else {
            throw CancellationError()
        }

        if useLocalTranscription {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [weak self] in
                    guard let self else {
                        throw TranscriptionError.submissionFailed("Service deallocated")
                    }
                    return try await self.transcribeAudioLocally(fileURL: fileURL)
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(self.localTranscriptionTimeoutSeconds))
                    throw TranscriptionError.transcriptionTimedOut(self.localTranscriptionTimeoutSeconds)
                }

                guard let result = try await group.next() else {
                    throw TranscriptionError.submissionFailed("No transcription result")
                }
                group.cancelAll()
                return result
            }
        }

        if try shouldUseLargeCloudChunkPath(fileURL: fileURL) {
            return try await transcribeLargeCanonicalWAV(fileURL: fileURL)
        }

        let timeoutSeconds = transcriptionTimeoutSeconds
        let raceState = TranscriptionTimeoutRaceState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                raceState.setContinuation(continuation)

                let transcriptionTask = Task { [weak self] in
                    do {
                        guard let self else {
                            throw TranscriptionError.transcriptionFailed("Transcription service deallocated")
                        }
                        let result = try await self.transcribeAudio(fileURL: fileURL)
                        raceState.finish(.success(result))
                    } catch {
                        raceState.finish(.failure(Self.transcriptionTimeoutErrorIfNeeded(
                            error,
                            timeoutSeconds: timeoutSeconds
                        )))
                    }
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                        raceState.finish(.failure(TranscriptionError.transcriptionTimedOut(timeoutSeconds)))
                    } catch is CancellationError {
                    } catch {
                        raceState.finish(.failure(error))
                    }
                }

                raceState.setTasks([transcriptionTask, timeoutTask])
            }
        } onCancel: {
            raceState.cancel()
        }
    }

    private func classifiedIssue(for error: Error) -> QuillUserIssueError {
        if let urlError = error as? URLError {
            return QuillUserIssueError.cloudTransport(
                urlError,
                providerHost: baseURL.host,
                modelID: transcriptionModel
            )
        }
        if let transcriptionError = error as? TranscriptionError {
            switch transcriptionError {
            case .transcriptionTimedOut:
                if useLocalTranscription {
                    return QuillUserIssueError.local(
                        code: .localTranscriptionFailed,
                        backend: localBackendName,
                        modelID: localTranscriptionModel.id,
                        diagnostic: transcriptionError.localizedDescription
                    )
                }
                return QuillUserIssueError.cloudTransport(
                    transcriptionError,
                    timedOut: true,
                    providerHost: baseURL.host,
                    modelID: transcriptionModel
                )
            case .invalidBaseURL:
                return QuillUserIssueError(
                    record: QuillUserIssueRecord(
                        code: .providerConfigurationInvalid,
                        context: QuillUserIssueContext(
                            providerHost: baseURL.host,
                            modelID: transcriptionModel
                        )
                    ),
                    privateDiagnostic: transcriptionError.localizedDescription
                )
            case .audioPreparationFailed:
                return QuillUserIssueError.local(
                    code: .audioPreparationFailed,
                    backend: localBackendName,
                    modelID: useLocalTranscription
                        ? localTranscriptionModel.id
                        : transcriptionModel,
                    diagnostic: transcriptionError.localizedDescription
                )
            case .pollFailed:
                if !useLocalTranscription {
                    return QuillUserIssueError(
                        record: QuillUserIssueRecord(
                            code: .invalidProviderResponse,
                            context: QuillUserIssueContext(
                                providerHost: baseURL.host,
                                modelID: transcriptionModel
                            )
                        ),
                        privateDiagnostic: transcriptionError.localizedDescription
                    )
                }
            case .uploadFailed, .submissionFailed, .transcriptionFailed:
                break
            }
        }
        if useLocalTranscription {
            return QuillUserIssueError.local(
                code: .localTranscriptionFailed,
                backend: localBackendName,
                modelID: localTranscriptionModel.id,
                diagnostic: error.localizedDescription
            )
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return QuillUserIssueError(
                record: QuillUserIssueRecord(
                    code: .audioUnreadable,
                    context: QuillUserIssueContext(
                        providerHost: baseURL.host,
                        modelID: transcriptionModel
                    )
                ),
                privateDiagnostic: "\(nsError.domain) \(nsError.code)"
            )
        }
        return QuillUserIssueError.cloudTransport(
            error,
            providerHost: baseURL.host,
            modelID: transcriptionModel
        )
    }

    private var localBackendName: String {
        if localTranscriptionModel.isAppleSpeech { return "Apple Speech" }
        return useLegacyMlxWhisper ? "Legacy mlx-whisper" : "Native Whisper"
    }

    // Run local transcription: Apple Speech, native Whisper, or legacy mlx_whisper
    private func transcribeAudioLocally(fileURL: URL) async throws -> String {
        if localTranscriptionModel.isAppleSpeech {
            return try await transcribeWithAppleSpeech(fileURL: fileURL)
        }
        if useLegacyMlxWhisper {
            return try await transcribeWithMlxWhisper(fileURL: fileURL)
        }
        return try await transcribeWithNativeWhisper(fileURL: fileURL)
    }

    private func transcribeWithNativeWhisper(fileURL: URL) async throws -> String {
        let model = NativeWhisperModelCatalog.recommended
        let store = NativeWhisperModelStore()
        guard store.installStatus(for: model) == .ready else {
            throw QuillUserIssueError.local(
                code: .localModelMissing,
                backend: "Native Whisper",
                modelID: model.id,
                diagnostic: "Recommended Native Whisper model is not installed"
            )
        }
        let runtime = NativeWhisperRuntime()
        let modelURL = store.modelURL(for: model)
        do {
            try runtime.validateRunnerAndModel(modelURL: modelURL)
        } catch let error as NativeWhisperRuntimeError {
            throw error.userIssue(modelID: model.id)
        }

        let preparedAudio: PreparedNativeWhisperAudio
        do {
            preparedAudio = try await AudioImportConversionService()
                .prepareForNativeWhisper(fileURL)
        } catch {
            throw QuillUserIssueError.local(
                code: .audioPreparationFailed,
                backend: "Native Whisper",
                modelID: model.id,
                diagnostic: error.localizedDescription
            )
        }
        defer { preparedAudio.cleanup() }

        do {
            let transcript = try await runtime.transcribe(
                audioURL: preparedAudio.fileURL,
                modelURL: modelURL,
                languageCode: transcriptionLanguage.whisperArgument
            )
            return normalizedTranscriptText(transcript)
        } catch let error as NativeWhisperRuntimeError {
            throw error.userIssue(modelID: model.id)
        }
    }

    private func transcribeWithAppleSpeech(fileURL: URL) async throws -> String {
        let authStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        if let issue = Self.appleSpeechAuthorizationIssue(for: authStatus) {
            throw issue
        }

        let locale = transcriptionLanguage.sfSpeechLocale
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw QuillUserIssueError.local(
                code: .localTranscriptionFailed,
                backend: "Apple Speech",
                diagnostic: "Recognizer unavailable for locale \(locale.identifier)"
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error = error {
                    resumed = true
                    let nsError = error as NSError
                    continuation.resume(throwing: QuillUserIssueError.local(
                        code: .localTranscriptionFailed,
                        backend: "Apple Speech",
                        diagnostic: "\(nsError.domain) \(nsError.code)"
                    ))
                    return
                }
                if let result = result, result.isFinal {
                    resumed = true
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: text)
                }
            }
        }
    }

    // Run mlx_whisper locally and return transcript text
    private func transcribeWithMlxWhisper(fileURL: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [localWhisperPath, transcriptionLanguage, localTranscriptionModel] in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let whisperBin = (localWhisperPath?.isEmpty == false)
                ? localWhisperPath!
                : "\(home)/.local/bin/mlx_whisper"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: whisperBin)
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(home)/.local/bin",
                "HOME": home
            ]

            let outputDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outputDir) }

            var arguments = [
                fileURL.path,
                "--model", localTranscriptionModel.id,
                "--output-format", "json",
                "--output-dir", outputDir.path,
                "--condition-on-previous-text", "False",
                "--verbose", "False"
            ]
            if let langCode = transcriptionLanguage.whisperArgument {
                arguments += ["--language", langCode]
            }
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                let nsError = error as NSError
                throw QuillUserIssueError.local(
                    code: .localRuntimeMissing,
                    backend: "Legacy mlx-whisper",
                    modelID: localTranscriptionModel.id,
                    diagnostic: "Runtime \(whisperBin): \(nsError.domain) \(nsError.code)"
                )
            }

            let stdoutReader = Task.detached(priority: .userInitiated) {
                String(
                    data: stdout.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let stderrReader = Task.detached(priority: .userInitiated) {
                String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            process.waitUntilExit()
            try Task.checkCancellation()

            let stdoutText = await stdoutReader.value
            let stderrText = await stderrReader.value
            let allOutputFiles = (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)) ?? []
            let jsonFiles = allOutputFiles.filter { $0.pathExtension.lowercased() == "json" }

            func summarizedOutput(_ text: String) -> String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return "" }
                let lines = trimmed.split(separator: "\n").map(String.init)
                let head = lines.prefix(8).joined(separator: "\n")
                if lines.count > 8 {
                    return head + "\n... (\(lines.count - 8) more lines)"
                }
                return head
            }

            func jsonFileSummary() -> String {
                if jsonFiles.isEmpty { return "none" }
                return jsonFiles.map(\.lastPathComponent).joined(separator: ", ")
            }

            func summarizedJSON(at fileURL: URL?) -> String {
                guard let fileURL,
                      let data = try? Data(contentsOf: fileURL),
                      let text = String(data: data, encoding: .utf8) else {
                    return ""
                }
                return summarizedOutput(text)
            }

            if stderrText.contains("No such file or directory: 'ffmpeg'") {
                throw QuillUserIssueError.local(
                    code: .localDependencyMissing,
                    backend: "Legacy mlx-whisper",
                    modelID: localTranscriptionModel.id,
                    processExitCode: process.terminationStatus,
                    diagnostic: summarizedOutput(stderrText)
                )
            }

            guard process.terminationStatus == 0 else {
                let summarizedStderr = summarizedOutput(stderrText)
                let summarizedStdout = summarizedOutput(stdoutText)
                let detail = !summarizedStderr.isEmpty ? summarizedStderr : summarizedStdout
                throw QuillUserIssueError.local(
                    code: .localTranscriptionFailed,
                    backend: "Legacy mlx-whisper",
                    modelID: localTranscriptionModel.id,
                    processExitCode: process.terminationStatus,
                    diagnostic: "json files: \(jsonFiles.count) [\(jsonFileSummary())] \(detail)"
                )
            }

            let inputName = fileURL.deletingPathExtension().lastPathComponent
            let expectedOutputFile = outputDir.appendingPathComponent(inputName).appendingPathExtension("json")
            let outputFile: URL?
            if FileManager.default.fileExists(atPath: expectedOutputFile.path) {
                outputFile = expectedOutputFile
            } else if jsonFiles.count == 1 {
                outputFile = jsonFiles[0]
            } else {
                outputFile = nil
            }

            let rawJSONString = outputFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let sanitizedJSONString = rawJSONString.map(Self.sanitizeNonFiniteJSONNumbers)
            let parsedJSONData = sanitizedJSONString?.data(using: .utf8)
            let parsedJSONObject = parsedJSONData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let parsedText = parsedJSONObject?["text"] as? String

            guard outputFile != nil,
                  let json = parsedJSONObject,
                  let text = parsedText else {
                let details = [
                    "json files: \(jsonFiles.count) [\(jsonFileSummary())]",
                    summarizedJSON(at: outputFile),
                    summarizedOutput(stderrText),
                    summarizedOutput(stdoutText)
                ].filter { !$0.isEmpty }.joined(separator: " | ")
                throw QuillUserIssueError.local(
                    code: .localTranscriptionFailed,
                    backend: "Legacy mlx-whisper",
                    modelID: localTranscriptionModel.id,
                    processExitCode: process.terminationStatus,
                    diagnostic: details
                )
            }

            if self.isHallucination(text: text, json: json) {
                return ""
            }

            let normalizedText = self.normalizedTranscriptText(text)
            guard !normalizedText.isEmpty else {
                return ""
            }
            return normalizedText
        }.value
    }

    private func shouldUseLargeCloudChunkPath(fileURL: URL) throws -> Bool {
        let physicalByteCount = try physicalByteCount(for: fileURL)
        let multipart = cloudMultipartLayout
        let encodedByteCount = try multipart.encodedByteCount(
            audioDataByteCount: physicalByteCount,
            fileName: fileURL.lastPathComponent,
            contentType: audioContentType(for: fileURL.lastPathComponent)
        )
        guard encodedByteCount > cloudDependencies.encodedUploadCeilingBytes else {
            return false
        }
        return (try? CanonicalPCM16WAV.validateFile(at: fileURL)) != nil
    }

    private func transcribeLargeCanonicalWAV(fileURL: URL) async throws -> String {
        let sourceLayout = try CanonicalPCM16WAV.validateFile(at: fileURL)
        let sourceIdentity = try CloudTranscriptionSourceIdentityBuilder.make(
            fileURL: fileURL,
            layout: sourceLayout
        )
        let multipart = cloudMultipartLayout
        let plan = try CloudTranscriptionChunkPlanner().plan(
            fileURL: fileURL,
            source: sourceIdentity,
            wavLayout: sourceLayout,
            multipart: multipart,
            encodedUploadCeilingBytes: cloudDependencies.encodedUploadCeilingBytes
        )
        let providerID = SHA256.hash(data: Data(baseURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let identity = CloudTranscriptionJobIdentity(
            providerID: providerID,
            model: transcriptionModel,
            language: language,
            responseFormat: transcriptionResponseFormat,
            source: sourceIdentity,
            planID: plan.planID
        )
        let retryPolicy = CloudTranscriptionRetryPolicy(
            maximumAttempts: 3,
            jitter: { _ in Double.random(in: 0...0.25) }
        )
        let core = CloudTranscriptionCore(
            configuration: CloudTranscriptionConfiguration(
                model: transcriptionModel,
                language: language,
                responseFormat: transcriptionResponseFormat,
                encodedUploadCeilingBytes: cloudDependencies.encodedUploadCeilingBytes,
                minimumAttemptTimeoutSeconds: transcriptionTimeoutSeconds,
                maximumAttemptTimeoutSeconds: 300
            ),
            materializer: CloudTranscriptionChunkMaterializer(
                temporaryRoot: cloudDependencies.temporaryRoot,
                copyBufferByteCount: 1_048_576
            ),
            retryPolicy: retryPolicy,
            sleep: cloudDependencies.sleep
        )
        let checkpointStore = cloudExecutionContext?.checkpointStore
            ?? cloudDependencies.checkpointStore
        let progress = cloudExecutionContext?.progress
            ?? cloudDependencies.progress
        do {
            return try await core.transcribe(
                sourceURL: fileURL,
                sourceLayout: sourceLayout,
                sourceIdentity: sourceIdentity,
                plan: plan,
                identity: identity,
                multipart: multipart,
                checkpointStore: checkpointStore,
                request: { [self] chunkURL, timeoutSeconds in
                    try await transcribeCloudFile(
                        fileURL: chunkURL,
                        timeoutSeconds: timeoutSeconds,
                        useStructuredHTTPFailure: true
                    )
                },
                progress: progress
            )
        } catch let failure as CloudTranscriptionHTTPFailure {
            throw QuillUserIssueError.cloudHTTP(
                status: failure.statusCode,
                providerCode: failure.providerCode,
                providerType: failure.providerType,
                providerHost: baseURL.host,
                modelID: transcriptionModel
            )
        } catch is CloudTranscriptionInvalidResponseFailure {
            throw QuillUserIssueError(
                record: QuillUserIssueRecord(
                    code: .invalidProviderResponse,
                    context: QuillUserIssueContext(
                        providerHost: baseURL.host,
                        modelID: transcriptionModel
                    )
                ),
                privateDiagnostic: "Cloud transcription returned an invalid response"
            )
        }
    }

    // Send audio file for transcription and return text
    private func transcribeAudio(fileURL: URL) async throws -> String {
        try await transcribeCloudFile(
            fileURL: fileURL,
            timeoutSeconds: transcriptionTimeoutSeconds,
            useStructuredHTTPFailure: false
        )
    }

    private func transcribeCloudFile(
        fileURL: URL,
        timeoutSeconds: TimeInterval,
        useStructuredHTTPFailure: Bool
    ) async throws -> String {
        let url = baseURL
            .appendingPathComponent("audio")
            .appendingPathComponent("transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)
        let body = makeMultipartBody(
            audioData: audioData,
            fileName: fileURL.lastPathComponent,
            model: transcriptionModel,
            responseFormat: transcriptionResponseFormat,
            language: language,
            boundary: boundary
        )

        do {
            let (data, response) = try await cloudDependencies.upload(request, body)
            return try validateTranscriptionResponse(
                data: data,
                response: response,
                fileURL: fileURL,
                useStructuredHTTPFailure: useStructuredHTTPFailure
            )
        } catch {
            let nsError = error as NSError
            os_log(
                .error,
                log: transcriptionLog,
                "URLSession upload failed for %{private}@ (bytes=%{public}lld): domain=%{public}@ code=%ld",
                fileURL.lastPathComponent,
                fileSizeBytes(for: fileURL),
                nsError.domain,
                nsError.code
            )
            throw error
        }
    }

    private func validateTranscriptionResponse(
        data: Data,
        response: URLResponse,
        fileURL: URL,
        useStructuredHTTPFailure: Bool
    ) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            if useStructuredHTTPFailure {
                throw CloudTranscriptionHTTPFailure(statusCode: 0)
            }
            throw QuillUserIssueError(
                record: QuillUserIssueRecord(
                    code: .invalidProviderResponse,
                    context: QuillUserIssueContext(
                        providerHost: baseURL.host,
                        modelID: transcriptionModel
                    )
                ),
                privateDiagnostic: "Cloud transcription returned no HTTP response"
            )
        }

        guard httpResponse.statusCode == 200 else {
            os_log(
                .error,
                log: transcriptionLog,
                "URLSession upload returned HTTP %ld for %{public}@ (bytes=%{public}lld)",
                httpResponse.statusCode,
                fileURL.lastPathComponent,
                fileSizeBytes(for: fileURL)
            )
            let failure = structuredHTTPFailure(
                data: data,
                response: httpResponse
            )
            if useStructuredHTTPFailure {
                throw failure
            }
            throw QuillUserIssueError.cloudHTTP(
                status: failure.statusCode,
                providerCode: failure.providerCode,
                providerType: failure.providerType,
                providerHost: baseURL.host,
                modelID: transcriptionModel
            )
        }

        do {
            return try parseTranscript(from: data)
        } catch {
            if useStructuredHTTPFailure {
                throw CloudTranscriptionInvalidResponseFailure()
            }
            throw error
        }
    }

    private func structuredHTTPFailure(
        data: Data,
        response: HTTPURLResponse
    ) -> CloudTranscriptionHTTPFailure {
        let retryAfterSeconds = response.value(
            forHTTPHeaderField: "Retry-After"
        ).flatMap(TimeInterval.init)
        let errorObject = (
            try? JSONSerialization.jsonObject(with: data)
        ) as? [String: Any]
        let providerError = errorObject?["error"] as? [String: Any]
        return CloudTranscriptionHTTPFailure(
            statusCode: response.statusCode,
            retryAfterSeconds: retryAfterSeconds,
            providerCode: safeProviderErrorField(providerError?["code"]),
            providerType: safeProviderErrorField(providerError?["type"]),
            sanitizedMessage: safeProviderErrorField(providerError?["message"])
        )
    }

    private func safeProviderErrorField(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let sanitized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(256)
        return sanitized.isEmpty ? nil : String(sanitized)
    }
    private var cloudMultipartLayout: CloudTranscriptionMultipartLayout {
        CloudTranscriptionMultipartLayout(
            model: transcriptionModel,
            responseFormat: transcriptionResponseFormat,
            language: language
        )
    }

    private func physicalByteCount(for fileURL: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        guard let size = attributes[.size] as? NSNumber else {
            throw TranscriptionError.audioPreparationFailed(
                "Unable to determine audio file size."
            )
        }
        return size.uint64Value
    }

    private func audioContentType(for fileName: String) -> String {
        if fileName.lowercased().hasSuffix(".wav") {
            return "audio/wav"
        }
        if fileName.lowercased().hasSuffix(".mp3") {
            return "audio/mpeg"
        }
        if fileName.lowercased().hasSuffix(".m4a") {
            return "audio/mp4"
        }
        return "audio/mp4"
    }

    private func fileSizeBytes(for fileURL: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func makeMultipartBody(
        audioData: Data,
        fileName: String,
        model: String,
        responseFormat: String,
        language: String?,
        boundary: String
    ) -> Data {
        var body = Data()

        func append(_ value: String) {
            body.append(Data(value.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("\(responseFormat)\r\n")

        if let language, !language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(audioContentType(for: fileName))\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        return body
    }

    private static func sanitizeNonFiniteJSONNumbers(_ json: String) -> String {
        json.replacingOccurrences(
            of: #"(:\s*|,\s*|\[\s*)(-?Infinity|NaN)\b(?=\s*[,}\]])"#,
            with: "$1null",
            options: .regularExpression
        )
    }

    private static func transcriptionTimeoutErrorIfNeeded(
        _ error: Error,
        timeoutSeconds: TimeInterval
    ) -> Error {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return TranscriptionError.transcriptionTimedOut(timeoutSeconds)
        }
        return error
    }

    // Whisper-large-v3 hallucinates common short phrases on silence/background
    // noise. Drop them when whisper itself reports a high no_speech_prob.
    // Add a new (phrase, minNoSpeechProb) pair here to filter more hallucinations.
    //
    // Thresholds tuned on ~500 samples from quiet and noisy environments, including
    // both positive cases (real "thank you" speech) and empty-audio cases. Kept
    // conservative to minimize false positives (filtering real user speech).
    // Normal speech included audios have very low no_speech_prob.
    private let hallucinationPhrases = [
        "thank you",
        "thank you for watching",
        "thank you very much",
        "thank you so much",
        "thanks for watching",
        "please subscribe",
        "like and subscribe",
        "subtitles by",
        "subtitles by the amara.org community"
    ]

    private let hallucinationNoSpeechThreshold = 0.1

    private func parseTranscript(from data: Data) throws -> String {
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            if isHallucination(text: text, json: json) {
                return ""
            }
            return normalizedTranscriptText(text)
        }

        let plainText = String(data: data, encoding: .utf8) ?? ""
        let text = plainText
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.pollFailed("Invalid response")
        }

        return text
    }

    private func isHallucination(text: String, json: [String: Any]) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        guard hallucinationPhrases.contains(normalized) else {
            return false
        }

        guard let segments = json["segments"] as? [[String: Any]] else {
            os_log(
                .info,
                log: transcriptionLog,
                "Skipping hallucination filter for '%{public}@': provider response has no segments/no_speech metadata",
                normalized
            )
            return false
        }

        guard let noSpeechProb = segments.first?["no_speech_prob"] as? Double else {
            os_log(
                .info,
                log: transcriptionLog,
                "Skipping hallucination filter for '%{public}@': provider response omitted no_speech_prob",
                normalized
            )
            return false
        }
        return noSpeechProb >= hallucinationNoSpeechThreshold
    }

    private func normalizedTranscriptText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let reducedPunctuation = trimmed.replacingOccurrences(
            of: #"([!?.,])\1+"#,
            with: #"$1"#,
            options: .regularExpression
        )
        let collapsedWhitespace = reducedPunctuation.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let normalized = collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentOnly = normalized.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        return contentOnly.isEmpty ? "" : normalized
    }
}

extension TranscriptionExecutionSnapshot {
    func makeTranscriptionService(
        cloudDependencies: CloudTranscriptionDependencies = .live,
        cloudExecutionContext: CloudTranscriptionExecutionContext? = nil
    ) throws -> TranscriptionService {
        switch self {
        case .cloud(let cloud, _):
            let dependencies = CloudTranscriptionDependencies(
                encodedUploadCeilingBytes: cloud.encodedUploadCeilingBytes,
                upload: cloudDependencies.upload,
                checkpointStore: cloudDependencies.checkpointStore,
                progress: cloudDependencies.progress,
                temporaryRoot: cloudDependencies.temporaryRoot,
                sleep: cloudDependencies.sleep
            )
            return try TranscriptionService(
                apiKey: cloud.apiKey,
                baseURL: cloud.baseURL.absoluteString,
                useLocalTranscription: false,
                transcriptionModel: cloud.model,
                language: cloud.language,
                cloudDependencies: dependencies,
                cloudExecutionContext: cloudExecutionContext
            )
        case .local(let local, _):
            return try TranscriptionService(
                apiKey: "",
                useLocalTranscription: true,
                localWhisperPath: local.localWhisperPath,
                useLegacyMlxWhisper: local.useLegacyMlxWhisper,
                transcriptionLanguage: local.language,
                localTranscriptionModel: local.model,
                cloudDependencies: cloudDependencies,
                cloudExecutionContext: nil
            )
        }
    }
}

enum TranscriptionError: LocalizedError {
    case invalidBaseURL(String)
    case uploadFailed(String)
    case submissionFailed(String)
    case transcriptionFailed(String)
    case transcriptionTimedOut(TimeInterval)
    case pollFailed(String)
    case audioPreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let msg): return "Invalid provider URL: \(msg)"
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        case .submissionFailed(let msg): return "Submission failed: \(msg)"
        case .transcriptionTimedOut(let seconds): return "Transcription timed out after \(Int(seconds))s"
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        case .pollFailed(let msg): return "Polling failed: \(msg)"
        case .audioPreparationFailed(let msg): return "Audio preparation failed: \(msg)"
        }
    }
}

private final class TranscriptionTimeoutRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private var continuation: CheckedContinuation<String, Error>?
    private var tasks: [Task<Void, Never>] = []

    func setContinuation(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if didFinish {
            lock.unlock()
            tasks.forEach { $0.cancel() }
            return
        }

        self.tasks = tasks
        lock.unlock()
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }

        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()

        tasks.forEach { $0.cancel() }

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }
}

private struct PreparedUploadAudio {
    let fileURL: URL
    let deleteOnCleanup: Bool

    func cleanup() {
        guard deleteOnCleanup else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
