import Foundation

/// Recognizes context summaries that only say inference failed, so they stay
/// out of AI prompts. Quill reports the failure itself through QuillUserIssue.
enum ContextInferenceFailure {
    static func isFailureSummary(_ summary: String) -> Bool {
        // Include upstream and older messages so retrying earlier history
        // entries also leaves the diagnostic text out.
        let value = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("Context summary failed:")
            || value.hasPrefix("Could not reliably infer a two-sentence summary")
            || value.hasPrefix("Could not refresh app context at stop time;")
            || value == "You are dictating in an unrecognized context."
    }

    /// The CONTEXT line for a prompt, or nothing when there is no usable summary.
    static func promptSection(for summary: String) -> String {
        let usable = usableSummary(summary).trimmingCharacters(in: .whitespacesAndNewlines)
        return usable.isEmpty ? "" : "CONTEXT: \"\(usable)\"\n"
    }

    static func usableSummary(_ summary: String) -> String {
        isFailureSummary(summary) ? "" : summary
    }
}
