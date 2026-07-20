import Foundation

struct CloudTranscriptionExecutionContext: Sendable {
    let historyID: UUID
    let session: CloudTranscriptionJobSession
    let checkpointStore: any CloudTranscriptionCheckpointStore
    let progress: @Sendable (CloudTranscriptionProgress) -> Void
}
