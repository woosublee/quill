import AppKit
import SwiftUI

struct NoteFileExportView: View {
    let source: NoteFileExportSource
    let suggestedBaseName: String
    let onDismiss: () -> Void
    let onSaved: (String) -> Void

    @AppStorage("note_file_export_last_directory")
    private var lastDirectoryPath = ""
    @State private var includeTranscript: Bool
    @State private var includeSummary: Bool
    @State private var includeAudio: Bool
    @State private var textFormat = NoteFileExportTextFormat.plainText
    @State private var baseName: String
    @State private var destinationDirectory: URL?
    @State private var pendingReplacementRequest: NoteFileExportRequest?
    @State private var showReplaceConfirmation = false
    @State private var resultMessage: String?
    @State private var resultHasPartialSuccess = false
    @State private var isSaving = false

    init(
        source: NoteFileExportSource,
        suggestedBaseName: String,
        onDismiss: @escaping () -> Void,
        onSaved: @escaping (String) -> Void
    ) {
        self.source = source
        self.suggestedBaseName = suggestedBaseName
        self.onDismiss = onDismiss
        self.onSaved = onSaved
        _includeTranscript = State(initialValue: source.transcript != nil)
        _includeSummary = State(initialValue: source.summary != nil)
        _includeAudio = State(initialValue: source.audioURL != nil)
        _baseName = State(initialValue: suggestedBaseName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Save Files")
                .font(.headline)
                .padding(.bottom, 4)
            Text("Choose what to save and where.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)

            ScrollView(.vertical) {
                exportFields
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, -4)

            Divider().padding(.vertical, 16)
            HStack {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: { prepareSave() }) {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(saveButtonTitle)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isSaving)
            }
        }
        .padding(24)
        .frame(width: 500, height: 520)
        .onAppear { loadInitialDirectory() }
        .confirmationDialog(
            "Replace Existing Files?",
            isPresented: $showReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                guard let request = pendingReplacementRequest else { return }
                performSave(request, replaceExisting: true)
            }
            Button("Cancel", role: .cancel) {
                pendingReplacementRequest = nil
            }
        } message: {
            Text(conflictMessage)
        }
    }

    private var exportFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldLabel("Items to Save")
            Toggle("Transcript Text", isOn: $includeTranscript)
                .toggleStyle(.checkbox)
                .disabled(source.transcript == nil)
            if source.transcript == nil {
                Text("No transcript text is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
            if source.summary != nil {
                HStack(alignment: .center, spacing: 8) {
                    Toggle("Summary", isOn: $includeSummary)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                    if source.isSummaryStale {
                        Text(
                            verbatim: "(" + localizedCatalogString(
                                "Transcript changed after this summary was generated."
                            ) + ")"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
            }
            Toggle("Recording File", isOn: $includeAudio)
                .toggleStyle(.checkbox)
                .disabled(source.audioURL == nil)
                .padding(.top, 6)
            if source.audioURL == nil {
                Text("The saved recording file could not be found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }

            if source.transcript != nil || source.summary != nil {
                fieldLabel("Text Format")
                    .padding(.top, 14)
                Picker("Text Format", selection: $textFormat) {
                    Text("Plain Text (.txt)")
                        .tag(NoteFileExportTextFormat.plainText)
                    Text("Markdown (.md)")
                        .tag(NoteFileExportTextFormat.markdown)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(
                    !selectedItems.contains(.transcript) && !selectedItems.contains(.summary)
                )
            }

            fieldLabel("File Name")
                .padding(.top, 14)
            TextField("File Name", text: $baseName)
                .textFieldStyle(.roundedBorder)
            filePreview
            Text("A file name is too long. Shorten the name before saving.")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .opacity(fileNameIsTooLong ? 1 : 0)
                .accessibilityHidden(!fileNameIsTooLong)

            fieldLabel("Save Location")
                .padding(.top, 14)
            HStack(spacing: 8) {
                Text(destinationDirectory?.path ?? "")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                Button("Change") { chooseDirectory() }
                    .controlSize(.small)
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(
                        resultHasPartialSuccess ? Color.orange : Color.red
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedItems: Set<NoteFileExportItem> {
        var items = Set<NoteFileExportItem>()
        if includeTranscript, source.transcript != nil { items.insert(.transcript) }
        if includeSummary, source.summary != nil { items.insert(.summary) }
        if includeAudio, source.audioURL != nil { items.insert(.audio) }
        return items
    }

    private var fileNameIsTooLong: Bool {
        guard let request = currentRequest else { return false }
        return !NoteFileExporter.fileNameFailures(for: request).isEmpty
    }

    private var canSave: Bool {
        !selectedItems.isEmpty
            && destinationDirectory != nil
            && !baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !fileNameIsTooLong
    }

    private var saveButtonTitle: LocalizedStringKey {
        switch selectedItems.count {
        case 3: return "Save 3 Files"
        case 2: return "Save 2 Files"
        default: return "Save File"
        }
    }

    private var conflictMessage: String {
        guard let request = pendingReplacementRequest else { return "" }
        return NoteFileExporter.conflicts(for: request)
            .map(\.lastPathComponent)
            .joined(separator: "\n")
    }

    private var filePreview: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 3) {
                ForEach(0..<source.availableItems.count, id: \.self) { _ in
                    Text(verbatim: " ")
                        .lineLimit(1)
                }
            }
            .hidden()

            if let request = currentRequest {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(
                        NoteFileExporter.destinationURLs(for: request)
                            .values
                            .map(\.lastPathComponent)
                            .sorted(),
                        id: \.self
                    ) { fileName in
                        Text(fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    private var currentRequest: NoteFileExportRequest? {
        guard let destinationDirectory, !selectedItems.isEmpty else { return nil }
        return NoteFileExportRequest(
            source: source,
            selectedItems: selectedItems,
            textFormat: textFormat,
            baseName: NoteFileExporter.sanitizedBaseName(
                baseName,
                fallback: suggestedBaseName
            ),
            destinationDirectory: destinationDirectory
        )
    }

    private func fieldLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }

    private func loadInitialDirectory() {
        let fileManager = FileManager.default
        if !lastDirectoryPath.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: lastDirectoryPath,
                isDirectory: &isDirectory
            ), isDirectory.boolValue,
               fileManager.isWritableFile(atPath: lastDirectoryPath) {
                destinationDirectory = URL(
                    fileURLWithPath: lastDirectoryPath,
                    isDirectory: true
                )
                return
            }
            resultHasPartialSuccess = true
            resultMessage = localizedCatalogString(
                "The previous save folder is unavailable. Choose another folder."
            )
        }
        destinationDirectory = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = localizedCatalogString("Choose")
        panel.message = localizedCatalogString(
            "Choose a folder for the exported files."
        )
        panel.directoryURL = destinationDirectory
        if panel.runModal() == .OK, let url = panel.url {
            destinationDirectory = url
        }
    }

    private func prepareSave() {
        guard canSave, let request = currentRequest else { return }
        let conflicts = NoteFileExporter.conflicts(for: request)
        if conflicts.isEmpty {
            performSave(request, replaceExisting: false)
        } else {
            pendingReplacementRequest = request
            showReplaceConfirmation = true
        }
    }

    private func performSave(
        _ request: NoteFileExportRequest,
        replaceExisting: Bool
    ) {
        isSaving = true
        resultMessage = nil
        resultHasPartialSuccess = false
        pendingReplacementRequest = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                NoteFileExporter.export(
                    request,
                    replaceExisting: replaceExisting
                )
            }.value
            isSaving = false
            if !result.savedItems.isEmpty {
                lastDirectoryPath = request.destinationDirectory.path
            }
            if result.failures.isEmpty {
                onSaved(successMessage(for: result.savedItems))
                onDismiss()
            } else {
                resultHasPartialSuccess = !result.savedItems.isEmpty
                resultMessage = resultMessage(for: result)
            }
        }
    }

    private func successMessage(
        for items: [NoteFileExportItem]
    ) -> String {
        let set = Set(items)
        if set.count == 3 {
            return localizedCatalogString("Saved 3 files.")
        }
        if set.count == 2 {
            return localizedCatalogString("Saved 2 files.")
        }
        if set == [.audio] {
            return localizedCatalogString("Recording file saved.")
        }
        if set == [.summary] {
            return localizedCatalogString("Summary saved.")
        }
        return localizedCatalogString("Transcript text saved.")
    }

    private func resultMessage(for result: NoteFileExportResult) -> String {
        var lines: [String] = []
        if !result.savedItems.isEmpty {
            lines.append(successMessage(for: result.savedItems))
        }
        lines.append(contentsOf: result.failures.map { failure in
            if failure.reason == .fileNameTooLong {
                return localizedCatalogString(
                    "A file name is too long. Shorten the name before saving."
                )
            }
            switch failure.item {
            case .transcript:
                return localizedCatalogString(
                    "The transcript text could not be saved."
                )
            case .summary:
                return localizedCatalogString(
                    "The summary could not be saved."
                )
            case .audio:
                return localizedCatalogString(
                    "The recording file could not be saved."
                )
            }
        })
        return lines.joined(separator: "\n")
    }
}
