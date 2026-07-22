import SwiftUI

/// A reusable dropdown for selecting a model from predefined options,
/// or providing a custom model string if "Custom..." is chosen.
struct ModelDropdownView: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let predefinedModels: [String]
    let defaultModel: String
    
    @Binding var textDraft: String
    @Binding var isEditing: Bool
    let onCommit: () -> Void
    let onReset: () -> Void

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey?,
        predefinedModels: [String],
        defaultModel: String,
        textDraft: Binding<String>,
        isEditing: Binding<Bool> = .constant(false),
        onCommit: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.predefinedModels = predefinedModels
        self.defaultModel = defaultModel
        self._textDraft = textDraft
        self._isEditing = isEditing
        self.onCommit = onCommit
        self.onReset = onReset
    }

    @State private var isCustom: Bool = false
    @FocusState private var isEditingCustom: Bool
    
    private var effectiveSelection: Binding<String> {
        Binding(
            get: {
                if predefinedModels.contains(textDraft) && !isCustom {
                    return textDraft
                } else {
                    return "Custom..."
                }
            },
            set: { newValue in
                if newValue == "Custom..." {
                    isCustom = true
                    if predefinedModels.contains(textDraft) {
                        textDraft = ""
                    }
                } else {
                    isCustom = false
                    textDraft = newValue
                    onCommit()
                }
            }
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            
            HStack(spacing: 8) {
                Picker("", selection: effectiveSelection) {
                    ForEach(predefinedModels, id: \.self) { model in
                        Text(verbatim: model).tag(model)
                    }
                    Divider()
                    Text("Custom...").tag("Custom...")
                }
                .labelsHidden()
                
                if effectiveSelection.wrappedValue == "Custom..." {
                    TextField(defaultModel, text: $textDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($isEditingCustom)
                        .onSubmit {
                            onCommit()
                        }
                        .onChange(of: isEditingCustom) { focused in
                            isEditing = focused
                            if !focused {
                                onCommit()
                            }
                        }
                }
                
                Button("Reset to Default") {
                    isCustom = false
                    onReset()
                }
                .font(.caption)
            }
            
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if !predefinedModels.contains(textDraft) && !textDraft.isEmpty {
                isCustom = true
            }
        }
        .onChange(of: textDraft) { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !isEditingCustom {
                isCustom = !predefinedModels.contains(trimmed)
            }
        }
    }
}
