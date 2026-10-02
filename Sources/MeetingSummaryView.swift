import SwiftUI

/// The Summary tab. Like the transcript, the summary is always editable and
/// saves on its own: Return adds a row below, ⌫ on an empty row removes it,
/// and only the caret shows where you are typing (#262).
struct MeetingSummaryView<Notices: View>: View {
    let envelope: MeetingSummaryEnvelope
    /// False while a new summary is being made, so edits can't be lost.
    let isEditable: Bool
    let sourceQuoteIsValid: (String) -> Bool
    let onToggleAction: (UUID, Bool) -> Void
    /// Saves edited content; false when it couldn't be saved.
    let onEditContent: (MeetingSummaryContent) -> Bool
    let onRevert: () -> Void
    let onViewSource: (String) -> Void
    /// Lets the note view save waiting typing before it replaces the summary.
    let draftSaver: MeetingSummaryDraftSaver
    /// One-line notices above the summary, such as a stale transcript.
    let notices: Notices

    @State private var draft: MeetingSummaryContent
    @State private var saveTask: Task<Void, Never>?
    /// The draft as last handed to `onEditContent`, to tell that save coming
    /// back apart from a summary that changed elsewhere.
    @State private var lastSavedDraft: MeetingSummaryContent?
    @State private var hoveredRowID: UUID?
    @State private var showsRevertConfirmation = false
    @FocusState private var focusedField: SummaryField?

    /// Waits this long after the last keystroke before saving, like the transcript.
    private static var saveDelay: Duration { .milliseconds(500) }

    init(
        envelope: MeetingSummaryEnvelope,
        isEditable: Bool,
        sourceQuoteIsValid: @escaping (String) -> Bool,
        onToggleAction: @escaping (UUID, Bool) -> Void,
        onEditContent: @escaping (MeetingSummaryContent) -> Bool,
        onRevert: @escaping () -> Void,
        onViewSource: @escaping (String) -> Void,
        draftSaver: MeetingSummaryDraftSaver,
        @ViewBuilder notices: () -> Notices
    ) {
        self.envelope = envelope
        self.isEditable = isEditable
        self.sourceQuoteIsValid = sourceQuoteIsValid
        self.onToggleAction = onToggleAction
        self.onEditContent = onEditContent
        self.onRevert = onRevert
        self.onViewSource = onViewSource
        self.draftSaver = draftSaver
        self.notices = notices()
        _draft = State(initialValue: envelope.content)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                notices
                if envelope.isEdited {
                    editedMarker
                }
                summaryContent
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 14)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onChange(of: draft) { _ in scheduleSave() }
        .onChange(of: focusedField) { field in
            // Leaving the summary saves right away.
            if field == nil { saveNow() }
        }
        .onChange(of: envelope) { newEnvelope in
            // The draft's own save comes back without its empty rows; keep
            // the draft then, since the person may be typing in a new row.
            // A regenerated or reverted summary replaces the draft.
            if newEnvelope.content == draft.removingEmptyItems() { return }
            if let lastSavedDraft,
               newEnvelope.content.hasSameText(as: lastSavedDraft.removingEmptyItems()) {
                draft = draft.keepingCompletion(from: newEnvelope.content)
                return
            }
            saveTask?.cancel()
            lastSavedDraft = nil
            draft = newEnvelope.content
        }
        .onAppear { draftSaver.saveNow = { saveNow() } }
        .onDisappear {
            saveNow()
            draftSaver.saveNow = { true }
        }
        .confirmationDialog(
            "Revert to the original summary?",
            isPresented: $showsRevertConfirmation,
            titleVisibility: .visible
        ) {
            Button("Revert to Original") {
                saveTask?.cancel()
                onRevert()
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Your edits will be replaced by the summary Quill made. Completed action items stay checked.")
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Saves the draft now. False only when there was something to save
    /// and saving failed; the draft then stays as typed.
    @discardableResult
    private func saveNow() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard isEditable,
              !draft.removingEmptyItems().hasSameText(as: envelope.content) else { return true }
        // Empty rows only disappear from the saved copy; the draft keeps
        // an empty row the person is still typing in.
        guard onEditContent(draft) else { return false }
        lastSavedDraft = draft
        return true
    }

    // MARK: Content

    /// Sized like `QuillInfoNotice`, the app's one-line notes.
    private var editedMarker: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .medium))
            Text("Edited summary")
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
            Button("Revert to Original") {
                showsRevertConfirmation = true
            }
            .buttonStyle(.link)
            .disabled(!isEditable)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            summarySection(title: "Overview") {
                TextField(
                    "Overview",
                    text: $draft.overview.text,
                    prompt: Text("Add an overview"),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .labelsHidden()
                .disabled(!isEditable)
                .focused($focusedField, equals: .overview)
            }
            pointSection(title: "Key Points", points: \.keyPoints)
            pointSection(title: "Decisions", points: \.decisions)
            actionSection
            pointSection(title: "Open Questions", points: \.openQuestions)
        }
    }

    private func pointSection(
        title: LocalizedStringKey,
        points: WritableKeyPath<MeetingSummaryContent, [MeetingSummaryPoint]>
    ) -> some View {
        summarySection(title: title) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(draft[keyPath: points]) { point in
                    pointRow(point, in: points)
                }
                newRowButton(title: "New Item", marker: bulletMarker) {
                    appendPoint(to: points)
                }
            }
        }
    }

    private func pointRow(
        _ point: MeetingSummaryPoint,
        in points: WritableKeyPath<MeetingSummaryContent, [MeetingSummaryPoint]>
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            bulletMarker
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                TextField(
                    "Item",
                    text: pointText(point.id, in: points),
                    prompt: Text("New Item"),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .labelsHidden()
                .disabled(!isEditable)
                .focused($focusedField, equals: .point(point.id))
                .onSubmit { insertPoint(after: point.id, in: points) }
                .modifier(DeleteWhenEmpty(text: point.text) {
                    removePoint(point.id, from: points)
                })
                if focusedField != .point(point.id),
                   let quote = nonempty(point.sourceQuote),
                   sourceQuoteIsValid(quote) {
                    sourceButton(quote)
                }
            }
            removeButton(rowID: point.id, isFocused: focusedField == .point(point.id)) {
                removePoint(point.id, from: points)
            }
        }
        .onHover { hoveredRowID = $0 ? point.id : (hoveredRowID == point.id ? nil : hoveredRowID) }
    }

    private var actionSection: some View {
        summarySection(title: "Action Items") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(draft.actionItems) { item in
                    actionRow(item)
                }
                newRowButton(title: "New Action Item", marker: checkboxMarker) {
                    appendAction()
                }
            }
        }
    }

    private func actionRow(_ item: MeetingSummaryActionItem) -> some View {
        let isFocused = focusedField == .task(item.id)
            || focusedField == .owner(item.id)
            || focusedField == .dueDate(item.id)
        return HStack(alignment: .top, spacing: 10) {
            Toggle(
                item.task,
                isOn: Binding(
                    get: { item.isCompleted },
                    set: { setCompleted(item.id, $0) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(item.task)

            VStack(alignment: .leading, spacing: 5) {
                TextField(
                    "Action item",
                    text: actionBinding(item.id, \.task),
                    prompt: Text("New Action Item"),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .labelsHidden()
                .disabled(!isEditable)
                .strikethrough(item.isCompleted)
                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                .focused($focusedField, equals: .task(item.id))
                .onSubmit { insertAction(after: item.id) }
                .modifier(DeleteWhenEmpty(text: item.task) {
                    removeAction(item.id)
                })
                HStack(spacing: 8) {
                    TextField(
                        "Owner",
                        text: optionalActionBinding(item.id, \.owner),
                        prompt: Text("Owner needs review")
                    )
                    .focused($focusedField, equals: .owner(item.id))
                    .fixedSize()
                    Text(verbatim: "·")
                        .foregroundStyle(.tertiary)
                    TextField(
                        "Due date",
                        text: optionalActionBinding(item.id, \.dueDate),
                        prompt: Text("Due date needs review")
                    )
                    .focused($focusedField, equals: .dueDate(item.id))
                    .fixedSize()
                }
                .textFieldStyle(.plain)
                .labelsHidden()
                .disabled(!isEditable)
                .font(.caption)
                .foregroundStyle(.secondary)
                if !isFocused,
                   let quote = nonempty(item.sourceQuote),
                   sourceQuoteIsValid(quote) {
                    sourceButton(quote)
                }
            }
            removeButton(rowID: item.id, isFocused: isFocused) {
                removeAction(item.id)
            }
        }
        .onHover { hoveredRowID = $0 ? item.id : (hoveredRowID == item.id ? nil : hoveredRowID) }
    }

    // MARK: Rows

    private var bulletMarker: some View {
        Circle()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 4, height: 4)
    }

    private var checkboxMarker: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
            .frame(width: 13, height: 13)
    }

    /// A dimmed row at the end of a section that adds one more.
    private func newRowButton<Marker: View>(
        title: LocalizedStringKey,
        marker: Marker,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                marker
                Text(title)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .disabled(!isEditable)
        .accessibilityLabel(Text(title))
    }

    /// Shown while the row is hovered or being edited.
    private func removeButton(
        rowID: UUID,
        isFocused: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isEditable && (hoveredRowID == rowID || isFocused) ? 1 : 0)
        .disabled(!isEditable)
        .help("Remove")
        .accessibilityLabel(Text("Remove"))
    }

    private func sourceButton(_ quote: String) -> some View {
        Button {
            onViewSource(quote)
        } label: {
            Label("View in Transcript", systemImage: "text.magnifyingglass")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func summarySection<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    // MARK: Editing

    private func pointText(
        _ id: UUID,
        in points: WritableKeyPath<MeetingSummaryContent, [MeetingSummaryPoint]>
    ) -> Binding<String> {
        Binding(
            get: { draft[keyPath: points].first { $0.id == id }?.text ?? "" },
            set: { newValue in
                guard let index = draft[keyPath: points].firstIndex(where: { $0.id == id }) else { return }
                draft[keyPath: points][index].text = newValue
            }
        )
    }

    private func actionBinding(
        _ id: UUID,
        _ field: WritableKeyPath<MeetingSummaryActionItem, String>
    ) -> Binding<String> {
        Binding(
            get: { draft.actionItems.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { newValue in
                guard let index = draft.actionItems.firstIndex(where: { $0.id == id }) else { return }
                draft.actionItems[index][keyPath: field] = newValue
            }
        )
    }

    /// Owner and due date are optional; clearing one saves no value.
    private func optionalActionBinding(
        _ id: UUID,
        _ field: WritableKeyPath<MeetingSummaryActionItem, String?>
    ) -> Binding<String> {
        Binding(
            get: { draft.actionItems.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { newValue in
                guard let index = draft.actionItems.firstIndex(where: { $0.id == id }) else { return }
                draft.actionItems[index][keyPath: field] = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private func appendPoint(
        to points: WritableKeyPath<MeetingSummaryContent, [MeetingSummaryPoint]>
    ) {
        let point = MeetingSummaryPoint(id: UUID(), text: "", sourceQuote: nil)
        draft[keyPath: points].append(point)
        focus(.point(point.id))
    }

    private func insertPoint(
        after id: UUID,
        in points: WritableKeyPath<MeetingSummaryContent, [MeetingSummaryPoint]>
    ) {
        guard let index = draft[keyPath: points].firstIndex(where: { $0.id == id }) else { return }
        let point = MeetingSummaryPoint(id: UUID(), text: "", sourceQuote: nil)
        draft[keyPath: points].insert(point, at: index + 1)
        focus(.point(point.id))
    }

    private func removePoint(
        _ id: UUID,
        from points: WritableKeyPath<MeetingSummaryContent, [MeetingSummaryPoint]>
    ) {
        draft[keyPath: points].removeAll { $0.id == id }
    }

    private func appendAction() {
        let item = Self.emptyAction()
        draft.actionItems.append(item)
        focus(.task(item.id))
    }

    private func insertAction(after id: UUID) {
        guard let index = draft.actionItems.firstIndex(where: { $0.id == id }) else { return }
        let item = Self.emptyAction()
        draft.actionItems.insert(item, at: index + 1)
        focus(.task(item.id))
    }

    private func removeAction(_ id: UUID) {
        draft.actionItems.removeAll { $0.id == id }
    }

    /// A checkbox saves on its own through the existing completion path and
    /// doesn't count as an edit.
    private func setCompleted(_ id: UUID, _ isCompleted: Bool) {
        guard let index = draft.actionItems.firstIndex(where: { $0.id == id }) else { return }
        draft.actionItems[index].isCompleted = isCompleted
        // Save typed text first, so the checkbox applies to the saved row
        // and the returning summary doesn't replace unsaved typing.
        saveNow()
        let task = draft.actionItems[index].task
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onToggleAction(id, isCompleted)
    }

    /// Focuses a row added in this update, once it exists.
    private func focus(_ field: SummaryField) {
        DispatchQueue.main.async {
            focusedField = field
        }
    }

    private static func emptyAction() -> MeetingSummaryActionItem {
        MeetingSummaryActionItem(
            id: UUID(),
            task: "",
            owner: nil,
            dueDate: nil,
            sourceQuote: nil,
            isCompleted: false
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Saves typing that is still waiting out the save delay. The note view calls
/// it before an action that replaces the summary, such as Regenerate.
@MainActor
final class MeetingSummaryDraftSaver {
    /// False when waiting typing couldn't be saved.
    var saveNow: () -> Bool = { true }
}

private enum SummaryField: Hashable {
    case overview
    case point(UUID)
    case task(UUID)
    case owner(UUID)
    case dueDate(UUID)
}

/// ⌫ on an empty row removes it, like Reminders. Key handling needs macOS 14;
/// on macOS 13 the row's remove button does the same.
private struct DeleteWhenEmpty: ViewModifier {
    let text: String
    let remove: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(.delete) {
                guard text.isEmpty else { return .ignored }
                remove()
                return .handled
            }
        } else {
            content
        }
    }
}
