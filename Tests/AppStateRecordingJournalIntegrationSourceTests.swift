import Foundation

@main
struct AppStateRecordingJournalIntegrationSourceTests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )

        precondition(source.contains("private let recordingJournalStore: RecordingJournalStore"))
        precondition(source.contains("private var activeMicrophoneJournalController: MicrophoneRecordingJournalController?"))
        precondition(source.contains("private var activeRecordingID: UUID?"))
        precondition(source.contains("recoverRecordingJournalsBeforeHistoryLoad"))
        precondition(source.contains("RecordingJournalRecoveryExecutor("))
        precondition(source.contains("executor.recoverAll()"))
        precondition(source.contains("RecordingRecoveryHistory("))
        precondition(source.contains("guard fileName != \"inflight\" else { continue }"))
        precondition(source.contains("protectedInflightAudioFileNames"))
        precondition(source.contains("!protectedInflightAudioFileNames.contains(fileName)"))
        precondition(source.contains("audioRecorder.normalizedPCM16Sink = controller.sink"))
        precondition(source.contains("controller.startCheckpointing"))
        precondition(source.contains("finishActiveMicrophoneJournal"))
        precondition(source.contains("discardActiveMicrophoneJournal"))
        precondition(source.contains("preserveActiveMicrophoneJournalForRecovery"))
        precondition(source.contains("savedAudioFileForStoppedRecording"))
        precondition(source.contains("pipelineHistoryStore.upsert("))
        precondition(source.contains("discardRecordingJournalAfterSuccessfulTranscription"))
        precondition(source.contains("isProtectedRecordingJournalAudioFile"))
        precondition(source.contains("let entryID = existingID ?? (isJournalAudioFile ? jobID : UUID())"))
        precondition(source.contains("if !isJournalAudioFile {"))
        precondition(source.contains("completePromotedRecordingJournal(recordingID: jobID)"))

        let startupRecoveryBody = try functionBody(named: "recoverRecordingJournalsBeforeHistoryLoad", in: source)
        precondition(!startupRecoveryBody.contains("retryTranscription"))

        let startBody = try functionBody(named: "startSelectedAudioRecorder", in: source)
        precondition(startBody.contains("makeActiveMicrophoneJournalController"))
        precondition(startBody.contains("try audioRecorder.startRecording(deviceUID: inputID)"))

        let switchBody = try functionBody(named: "switchActiveRecordingInput", in: source)
        precondition(switchBody.contains("let journalToDiscardAfterDrain = detachActiveMicrophoneJournalForDiscard()"))
        precondition(switchBody.contains("try? journalToDiscardAfterDrain?.discard()"))
        let stopRange = try requiredRange(of: "stopActiveAudioRecorder", in: switchBody)
        let discardRange = try requiredRange(of: "try? journalToDiscardAfterDrain?.discard()", in: switchBody)
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
