import SwiftUI

/// Development-build tool: every issue style with synthetic examples, so the
/// shared issue UI can be reviewed without reproducing each failure.
struct IssueStylePreviewView: View {
    private static func presentation(
        _ code: QuillUserIssueCode,
        context: QuillUserIssueContext = QuillUserIssueContext()
    ) -> QuillUserIssuePresentation {
        QuillUserIssueRecord(code: code, context: context).presentation()
    }

    private let cleanupFailed = presentation(
        .postProcessingFailed,
        context: QuillUserIssueContext(
            modelID: "qwen2.5-7b-instruct",
            operation: .postProcessing,
            postProcessingFailureReason: .serviceRequestFailed
        )
    )
    private let contextFailed = presentation(.contextUnavailable)
    private let summaryFailed = presentation(.meetingSummaryInvalidResponse)
    private let transcriptionFailed = presentation(
        .localTranscriptionFailed,
        context: QuillUserIssueContext(modelID: "qwen3-asr-0.6b", localBackend: "Local AI")
    )
    private let keyFailed = presentation(
        .authenticationFailed,
        context: QuillUserIssueContext(httpStatus: 401, providerHost: "api.example.com")
    )
    private let modelFailed = presentation(.localAIStartFailed)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Note detail · transcript banner") {
                    QuillUserIssueView(
                        presentation: cleanupFailed,
                        style: .warningBanner,
                        action: {},
                        onDismiss: {}
                    )
                    QuillUserIssueView(
                        presentation: contextFailed,
                        style: .warningBanner,
                        onDismiss: {}
                    )
                }
                section("Note detail · info notice") {
                    QuillInfoNotice(
                        text: localizedCatalogString(
                            "Nothing to clean up; showing the original transcript."
                        ),
                        onDismiss: {}
                    )
                }
                section("Note detail · summary banner") {
                    QuillUserIssueView(
                        presentation: summaryFailed,
                        style: .warningBanner,
                        action: {},
                        actionTitleOverride: "Retry Summary",
                        onDismiss: {}
                    )
                }
                section("Note detail · centered error") {
                    QuillUserIssueView(
                        presentation: transcriptionFailed,
                        style: .full,
                        action: {}
                    )
                }
                section("Settings · inline") {
                    QuillUserIssueView(presentation: keyFailed, style: .inline, action: {})
                    QuillUserIssueView(
                        presentation: modelFailed,
                        style: .inline,
                        action: {},
                        actionTitleOverride: "Try Again"
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 640)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            content()
        }
    }
}
