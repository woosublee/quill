import Foundation

@main
struct AppStateRecordingJournalIntegrationSourceTests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )

        precondition(source.contains("private let recordingJournalStore: RecordingJournalStore"))
        precondition(source.contains("private var activeSingleSourceJournalController: SingleSourceRecordingJournalController?"))
        precondition(source.contains("private var activeRecordingID: UUID?"))
        precondition(source.contains("recoverRecordingJournalsBeforeHistoryLoad"))
        precondition(source.contains("RecordingJournalRecoveryExecutor("))
        precondition(source.contains("executor.recoverAll()"))
        precondition(source.contains("RecordingRecoveryHistory("))
        precondition(source.contains("guard fileName != \"inflight\" else { continue }"))
        precondition(source.contains("protectedInflightAudioFileNames"))
        precondition(source.contains("!protectedInflightAudioFileNames.contains(fileName)"))
        precondition(source.contains("audioRecorder.normalizedPCM16Sink = controller.sink"))
        precondition(source.contains("systemAudioRecorder.normalizedPCM16Sink = controller.sink"))
        precondition(source.contains("controller.startCheckpointing"))
        precondition(source.contains("finishActiveSingleSourceJournal"))
        precondition(source.contains("discardActiveSingleSourceJournal"))
        precondition(source.contains("preserveActiveSingleSourceJournalForRecovery"))
        precondition(source.contains("savedAudioFileForStoppedRecording"))
        precondition(source.contains("pipelineHistoryStore.upsert("))
        precondition(source.contains("discardRecordingJournalAfterSuccessfulTranscription"))
        precondition(source.contains("recordingJournalID(forAudioFileName:"))
        precondition(source.contains("let entryID = existingID ?? (journalRecordingID ?? UUID())"))
        precondition(source.contains("if !isJournalAudioFile {"))
        precondition(source.contains("completePromotedRecordingJournal("))
        precondition(source.contains("recordingID: journalRecordingID"))
        precondition(source.contains("recoverableJournalID"))
        precondition(source.contains("recordingID: recoverableJournalID"))

        let startupRecoveryBody = try functionBody(
            named: "recoverRecordingJournalsBeforeHistoryLoad",
            in: source
        )
        precondition(!startupRecoveryBody.contains("retryTranscription"))

        let beginBody = try functionBody(named: "beginRecording", in: source)
        precondition(beginBody.contains("AudioInputDevice.isSingleSource(audioInputID)"))

        let startBody = try functionBody(
            named: "startSelectedAudioRecorder",
            in: source
        )
        precondition(startBody.contains("makeActiveSingleSourceJournalController("))
        precondition(startBody.contains("inputID: inputID"))
        precondition(startBody.contains("try await systemAudioRecorder.startRecording()"))
        precondition(startBody.contains("try audioRecorder.startRecording(deviceUID: inputID)"))
        precondition(!startBody.contains("systemDefaultAndSystemAudioRecorder.normalizedPCM16Sink"))
        let makeControllerBody = try functionBody(
            named: "makeActiveSingleSourceJournalController",
            in: source
        )
        precondition(makeControllerBody.contains("sourceMode = .systemAudio"))
        precondition(makeControllerBody.contains("sourceKind = .systemAudio"))
        precondition(makeControllerBody.contains("sourceFileName = \"system-audio.wav.part\""))

        let stopBody = try functionBody(
            named: "stopActiveAudioRecorder",
            in: source
        )
        precondition(stopBody.contains("systemAudioRecorder.normalizedPCM16Sink = nil"))
        precondition(stopBody.contains("audioRecorder.normalizedPCM16Sink = nil"))
        precondition(stopBody.contains("finishStoppedSingleSourceRecording"))
        let finishStoppedBody = try functionBody(
            named: "finishStoppedSingleSourceRecording",
            in: source
        )
        precondition(finishStoppedBody.contains("detachActiveSingleSourceJournalForFinish"))
        precondition(finishStoppedBody.contains("recordingJournalFinalizationQueue.async"))
        precondition(finishStoppedBody.contains("finishActiveSingleSourceJournal"))
        precondition(finishStoppedBody.contains("DispatchQueue.main.async"))

        let cancelBody = try functionBody(
            named: "cancelActiveAudioRecorder",
            in: source
        )
        precondition(cancelBody.contains("systemAudioRecorder.normalizedPCM16Sink = nil"))
        precondition(cancelBody.contains("systemAudioRecorder.cancelRecording { [weak self] in"))
        precondition(cancelBody.contains("self?.discardActiveSingleSourceJournal()"))
        precondition(cancelBody.contains("audioRecorder.normalizedPCM16Sink = nil"))

        let preserveBody = try functionBody(
            named: "preserveActiveSingleSourceJournalForRecovery",
            in: source
        )
        precondition(preserveBody.contains("audioRecorder.normalizedPCM16Sink = nil"))
        precondition(preserveBody.contains("systemAudioRecorder.normalizedPCM16Sink = nil"))
        precondition(preserveBody.contains("controller?.preserveForRecovery()"))

        let switchBody = try functionBody(
            named: "switchActiveRecordingInput",
            in: source
        )
        precondition(
            switchBody.contains(
                "let journalToDiscardAfterDrain = detachActiveSingleSourceJournalForDiscard()"
            )
        )
        precondition(switchBody.contains("try? journalToDiscardAfterDrain?.discard()"))
        let stopRange = try requiredRange(of: "stopActiveAudioRecorder", in: switchBody)
        let discardRange = try requiredRange(
            of: "try? journalToDiscardAfterDrain?.discard()",
            in: switchBody
        )
        precondition(stopRange.lowerBound < discardRange.lowerBound)

        let sweepBody = try functionBody(named: "sweepOrphanStoredFiles", in: source)
        precondition(sweepBody.contains("guard fileName != \"inflight\" else { continue }"))

        print("AppStateRecordingJournalIntegrationSourceTests passed")
    }

    private static func requiredRange(
        of needle: String,
        in text: String
    ) throws -> Range<String.Index> {
        guard let range = text.range(of: needle) else {
            throw TestFailure("missing text: \(needle)")
        }
        return range
    }

    private static func functionBody(named name: String, in text: String) throws -> String {
        let signatures = ["private func \(name)", "private static func \(name)", "func \(name)"]
        guard let signatureRange = signatures.compactMap({ text.range(of: $0) }).first,
              let openBrace = text[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw TestFailure("missing function \(name)")
        }

        var depth = 0
        var index = openBrace
        while index < text.endIndex {
            switch text[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(text[text.index(after: openBrace)..<index])
                }
            default:
                break
            }
            index = text.index(after: index)
        }
        throw TestFailure("unterminated function \(name)")
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
