# Notch-side Recording Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional recording-only notch-side overlay layout that keeps Quill's existing centered overlay as the default and fallback.

**Architecture:** Add a small persisted `RecordingOverlayLayout` setting in `AppState`, pass it into `RecordingOverlayManager`, and let the manager choose between the existing centered frame/content path and a new recording-only notch-side frame/content path. Keep transcribing, feedback, update, and concurrent transcription ownership flows unchanged.

**Tech Stack:** Swift, SwiftUI, AppKit `NSPanel`/`NSScreen`, UserDefaults, Makefile-based macOS app build.

---

## File structure

- `Sources/RecordingOverlay.swift`
  - Add `RecordingOverlayLayout` enum.
  - Store selected layout in `RecordingOverlayState` so layout updates are published consistently.
  - Add notch-side geometry helpers inside `RecordingOverlayManager`.
  - Keep existing centered `overlayFrame`, `overlayWidth`, and `RecordingOverlayView` behavior intact.
  - Add a notch-side recording root view that renders equal-width left/right visible regions inside one transparent panel.

- `Sources/AppState.swift`
  - Add `recording_overlay_layout` UserDefaults key.
  - Add `@Published var recordingOverlayLayout`.
  - Load the setting in `init()` with default `.centered`.
  - Pass the setting to `overlayManager` during init and whenever the setting changes.

- `Sources/SettingsView.swift`
  - Add a small picker for `Recording Overlay Layout`.
  - Place it near shortcut/recording behavior settings, not in transcription model settings.
  - Explain that `Notch Sides` applies only while recording on notch MacBooks.

- `Tests/RecordingOverlayLayoutTests.swift`
  - Add focused tests for enum raw-value decoding/fallback if test harness allows importing the source directly.
  - If the project cannot compile tests independently, keep this task scoped to a parse/build verification and do not add brittle UI tests.

---

### Task 1: Add the overlay layout setting model

**Files:**
- Modify: `Sources/RecordingOverlay.swift`
- Modify: `Sources/AppState.swift`

- [ ] **Step 1: Add `RecordingOverlayLayout` enum near `OverlayPhase`**

In `Sources/RecordingOverlay.swift`, add this enum after `OverlayPhase`:

```swift
enum RecordingOverlayLayout: String, CaseIterable, Identifiable {
    case centered
    case notchSides

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .centered: return "Centered"
        case .notchSides: return "Notch Sides"
        }
    }

    var helpText: String {
        switch self {
        case .centered:
            return "Show the recording overlay centered below the notch."
        case .notchSides:
            return "Show recording controls beside the notch when supported. Other states stay centered."
        }
    }

    static func find(rawValue: String?) -> RecordingOverlayLayout {
        guard let rawValue, let layout = RecordingOverlayLayout(rawValue: rawValue) else { return .centered }
        return layout
    }
}
```

- [ ] **Step 2: Add setting storage key to `AppState`**

In `Sources/AppState.swift`, add the key near other private storage keys:

```swift
private let recordingOverlayLayoutStorageKey = "recording_overlay_layout"
```

Place it after `dictationAudioInterruptionEnabledStorageKey` and before `pendingMutedAudioRestoreStorageKey`.

- [ ] **Step 3: Add published property to `AppState`**

In `Sources/AppState.swift`, add this property near `dictationAudioInterruptionEnabled`:

```swift
@Published var recordingOverlayLayout: RecordingOverlayLayout {
    didSet {
        UserDefaults.standard.set(recordingOverlayLayout.rawValue, forKey: recordingOverlayLayoutStorageKey)
        overlayManager.setRecordingOverlayLayout(recordingOverlayLayout)
    }
}
```

- [ ] **Step 4: Load the setting in `AppState.init()`**

In `init()`, after loading `dictationAudioInterruptionEnabled`, add:

```swift
let recordingOverlayLayout = RecordingOverlayLayout.find(
    rawValue: UserDefaults.standard.string(forKey: recordingOverlayLayoutStorageKey)
)
```

Then assign it after `self.dictationAudioInterruptionEnabled = dictationAudioInterruptionEnabled`:

```swift
self.recordingOverlayLayout = recordingOverlayLayout
self.overlayManager.setRecordingOverlayLayout(recordingOverlayLayout)
```

- [ ] **Step 5: Add the manager setter stub**

In `Sources/RecordingOverlay.swift`, add a property to `RecordingOverlayState`:

```swift
@Published var recordingOverlayLayout: RecordingOverlayLayout = .centered
```

Then add this method inside `RecordingOverlayManager` after `setRecordingTriggerMode`:

```swift
func setRecordingOverlayLayout(_ layout: RecordingOverlayLayout) {
    DispatchQueue.main.async {
        self.overlayState.recordingOverlayLayout = layout
        self.updateOverlayLayout(animated: false)
    }
}
```

- [ ] **Step 6: Parse-check the new setting model**

Run:

```bash
swiftc -parse Sources/RecordingOverlay.swift Sources/AppState.swift
```

Expected: this may fail because these files reference types from other files when parsed together in isolation. If it fails due to unrelated missing symbols, continue to the full Makefile build in the next step. It must not fail due to `RecordingOverlayLayout` or `recordingOverlayLayout` being undefined.

- [ ] **Step 7: Build with Makefile**

Run:

```bash
make clean && make CODESIGN_IDENTITY="Apple Development: dntjqdlekd+kr@gmail.com (8GMU2DP9ND)"
```

Expected: build succeeds and prints `Built build/Quill.app`.

- [ ] **Step 8: Commit**

```bash
git add Sources/RecordingOverlay.swift Sources/AppState.swift
git commit -m "Add recording overlay layout setting."
```

---

### Task 2: Add Settings UI for the layout option

**Files:**
- Modify: `Sources/SettingsView.swift`

- [ ] **Step 1: Locate recording/shortcut settings section**

Search for the settings area that contains hold/toggle shortcut, shortcut start delay, or recording behavior controls:

```bash
git grep -n "shortcutStartDelay\|Hold Shortcut\|Toggle Shortcut\|Recording" Sources/SettingsView.swift
```

Use the section that already groups recording behavior. Do not put this control inside provider model settings.

- [ ] **Step 2: Add picker UI**

Add this block near other recording behavior controls:

```swift
VStack(alignment: .leading, spacing: 6) {
    Text("Recording Overlay Layout")
        .font(.caption.weight(.semibold))

    Picker("Recording Overlay Layout", selection: $appState.recordingOverlayLayout) {
        ForEach(RecordingOverlayLayout.allCases) { layout in
            Text(layout.displayName).tag(layout)
        }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .accessibilityLabel("Recording Overlay Layout")

    Text(appState.recordingOverlayLayout.helpText)
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

If the surrounding section uses `SettingsCard` or `Divider()`, match that style exactly.

- [ ] **Step 3: Build with Makefile**

Run:

```bash
make clean && make CODESIGN_IDENTITY="Apple Development: dntjqdlekd+kr@gmail.com (8GMU2DP9ND)"
```

Expected: build succeeds and prints `Built build/Quill.app`.

- [ ] **Step 4: Run the built app for Settings smoke test**

Run:

```bash
open build/Quill.app
```

Expected: app launches. Open Settings manually and confirm the new picker appears and defaults to `Centered`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SettingsView.swift
git commit -m "Expose recording overlay layout setting."
```

---

### Task 3: Implement notch-side recording geometry

**Files:**
- Modify: `Sources/RecordingOverlay.swift`

- [ ] **Step 1: Add notch-side layout constants**

Inside `RecordingOverlayManager`, near `lockedOverlayWidth`, add:

```swift
private let notchSideRegionWidth: CGFloat = 92
private let notchSidePanelHeight: CGFloat = 38
private let notchSideHorizontalInset: CGFloat = 8
```

- [ ] **Step 2: Add geometry struct**

Inside `RecordingOverlayManager`, add this private struct near the constants:

```swift
private struct NotchSideGeometry {
    let frame: NSRect
    let leftContentFrame: CGRect
    let rightContentFrame: CGRect
}
```

- [ ] **Step 3: Add active-layout predicate**

Inside `RecordingOverlayManager`, add:

```swift
private var usesNotchSideRecordingLayout: Bool {
    overlayState.recordingOverlayLayout == .notchSides
        && overlayState.phase == .recording
        && screenHasNotch
        && notchSideGeometry != nil
}
```

- [ ] **Step 4: Add notch-side geometry helper**

Inside `RecordingOverlayManager`, add:

```swift
private var notchSideGeometry: NotchSideGeometry? {
    guard let screen = NSScreen.main, screenHasNotch else { return nil }
    guard let leftArea = screen.auxiliaryTopLeftArea,
          let rightArea = screen.auxiliaryTopRightArea else { return nil }

    let availableSideWidth = min(leftArea.width, rightArea.width)
    let contentWidth = min(notchSideRegionWidth, max(0, availableSideWidth - notchSideHorizontalInset * 2))
    guard contentWidth >= 64 else { return nil }

    let notchMinX = leftArea.maxX
    let notchMaxX = rightArea.minX
    guard notchMaxX > notchMinX else { return nil }

    let panelMinX = leftArea.maxX - contentWidth - notchSideHorizontalInset
    let panelMaxX = rightArea.minX + contentWidth + notchSideHorizontalInset
    let height = notchSidePanelHeight + notchOverlap
    let frame = NSRect(
        x: panelMinX,
        y: screen.frame.maxY - height,
        width: panelMaxX - panelMinX,
        height: height
    )

    let contentY = notchOverlap
    let leftFrame = CGRect(
        x: notchSideHorizontalInset,
        y: contentY,
        width: contentWidth,
        height: notchSidePanelHeight
    )
    let rightFrame = CGRect(
        x: frame.width - notchSideHorizontalInset - contentWidth,
        y: contentY,
        width: contentWidth,
        height: notchSidePanelHeight
    )

    return NotchSideGeometry(frame: frame, leftContentFrame: leftFrame, rightContentFrame: rightFrame)
}
```

- [ ] **Step 5: Route `overlayFrame` through notch-side geometry**

At the top of `overlayFrame`, after `guard let screen = NSScreen.main else { return .zero }`, add:

```swift
if let geometry = notchSideGeometry,
   overlayState.recordingOverlayLayout == .notchSides,
   overlayState.phase == .recording {
    return geometry.frame
}
```

- [ ] **Step 6: Build with Makefile**

Run:

```bash
make clean && make CODESIGN_IDENTITY="Apple Development: dntjqdlekd+kr@gmail.com (8GMU2DP9ND)"
```

Expected: build succeeds and prints `Built build/Quill.app`.

- [ ] **Step 7: Commit**

```bash
git add Sources/RecordingOverlay.swift
git commit -m "Add notch-side recording overlay geometry."
```

---

### Task 4: Render notch-side recording content

**Files:**
- Modify: `Sources/RecordingOverlay.swift`

- [ ] **Step 1: Add a generic clear panel content helper**

After `makeNotchContent`, add:

```swift
private func makeTransparentContent<V: View>(
    width: CGFloat,
    height: CGFloat,
    rootView: V
) -> NSView {
    let hosting = NSHostingView(rootView: rootView.frame(width: width, height: height))
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    hosting.autoresizingMask = [.width, .height]
    return hosting
}
```

- [ ] **Step 2: Add notch-side content route**

At the top of `makeOverlayContent(frame:)`, add:

```swift
if let geometry = notchSideGeometry,
   overlayState.recordingOverlayLayout == .notchSides,
   overlayState.phase == .recording {
    return makeNotchSideRecordingContent(frame: frame, geometry: geometry)
}
```

- [ ] **Step 3: Add `makeNotchSideRecordingContent`**

Inside `RecordingOverlayManager`, after `makeOverlayContent(frame:)`, add:

```swift
private func makeNotchSideRecordingContent(frame: NSRect, geometry: NotchSideGeometry) -> NSView {
    makeTransparentContent(
        width: frame.width,
        height: frame.height,
        rootView: NotchSideRecordingOverlayView(
            state: overlayState,
            leftContentFrame: geometry.leftContentFrame,
            rightContentFrame: geometry.rightContentFrame,
            onStopButtonPressed: { [weak self] in
                self?.onStopButtonPressed?()
            }
        )
    )
}
```

- [ ] **Step 4: Add visible notch-side pill helper**

Before `RecordingOverlayView`, add:

```swift
private struct NotchSidePill<Content: View>: View {
    let frame: CGRect
    let content: Content

    init(frame: CGRect, @ViewBuilder content: () -> Content) {
        self.frame = frame
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: frame.width, height: frame.height)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .position(x: frame.midX, y: frame.midY)
    }
}
```

- [ ] **Step 5: Add notch-side recording view**

Before `RecordingOverlayView`, add:

```swift
private struct NotchSideRecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    let leftContentFrame: CGRect
    let rightContentFrame: CGRect
    let onStopButtonPressed: () -> Void

    private var showsStopButton: Bool {
        state.recordingTriggerMode == .toggle
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            NotchSidePill(frame: leftContentFrame) {
                ZStack {
                    WaveformView(audioLevel: state.audioLevel, showsActivityPulse: true)
                        .padding(.horizontal, 12)
                    if state.isCommandMode {
                        HStack {
                            CommandModeIndicator()
                                .padding(.leading, 8)
                            Spacer()
                        }
                    }
                }
            }

            NotchSidePill(frame: rightContentFrame) {
                ZStack {
                    if showsStopButton {
                        Button(action: onStopButtonPressed) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.red.opacity(0.92)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: state.audioLevel)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: state.recordingTriggerMode)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: state.isCommandMode)
    }
}
```

- [ ] **Step 6: Build with Makefile**

Run:

```bash
make clean && make CODESIGN_IDENTITY="Apple Development: dntjqdlekd+kr@gmail.com (8GMU2DP9ND)"
```

Expected: build succeeds and prints `Built build/Quill.app`.

- [ ] **Step 7: Commit**

```bash
git add Sources/RecordingOverlay.swift
git commit -m "Render notch-side recording overlay."
```

---

### Task 5: Verify behavior in the built app

**Files:**
- No code changes expected unless verification finds a defect.

- [ ] **Step 1: Launch the built app**

Run:

```bash
open build/Quill.app
```

Expected: the built worktree app launches.

- [ ] **Step 2: Verify default centered mode**

Manual steps:

1. Open Settings.
2. Confirm `Recording Overlay Layout` is `Centered`.
3. Start recording.
4. Confirm the overlay appears in the existing centered/below-notch position.
5. Stop recording.
6. Confirm transcribing/processing remains centered.

Expected: behavior matches current app.

- [ ] **Step 3: Verify notch-side mode in hold recording**

Manual steps:

1. Set `Recording Overlay Layout` to `Notch Sides`.
2. Start hold-mode recording.
3. Confirm waveform appears on the left side of the notch.
4. Confirm the right side has a balanced black pill but no stop button.
5. Stop recording.
6. Confirm transcribing/processing returns to the centered overlay.

Expected: recording-only notch-side layout works and processing is centered.

- [ ] **Step 4: Verify notch-side mode in toggle recording**

Manual steps:

1. Start toggle-mode recording.
2. Confirm waveform appears on the left side of the notch.
3. Confirm stop button appears on the right side.
4. Click the stop button.
5. Confirm recording stops and processing appears centered.

Expected: stop button is clickable and does not regress toggle mode.

- [ ] **Step 5: Verify concurrent transcription ownership**

Manual steps:

1. Use a transcription mode that takes long enough to process.
2. Record and stop once.
3. Start a second recording while the first transcription is still processing.
4. Confirm the second recording controls the visible recording overlay.
5. Confirm the first transcription completion does not dismiss or overwrite the second recording overlay.

Expected: current `activeTranscriptionJobs` / `overlayTranscriptionID` behavior is preserved.

- [ ] **Step 6: Commit verification fixes if needed**

If verification required code changes, run the Makefile build again and commit:

```bash
git add Sources/RecordingOverlay.swift Sources/AppState.swift Sources/SettingsView.swift
git commit -m "Fix notch-side overlay verification issues."
```

If no changes are needed, do not create an empty commit.

---

### Task 6: Prepare PR

**Files:**
- Existing commits only.

- [ ] **Step 1: Review final diff**

Run:

```bash
git status --short --branch
git log --oneline origin/main..HEAD
git diff --stat origin/main...HEAD
```

Expected: worktree is on `issue-53-notch-side-overlay`, contains the design commit plus implementation commits, and has no uncommitted changes.

- [ ] **Step 2: Push branch to origin**

Run:

```bash
git push -u origin issue-53-notch-side-overlay
```

Expected: branch is pushed to `woosublee/freeflow`.

- [ ] **Step 3: Create PR**

Run:

```bash
gh pr create --repo woosublee/freeflow --base main --head issue-53-notch-side-overlay --title "Add optional notch-side recording overlay" --body "$(cat <<'EOF'
## Summary
- Add an optional recording overlay layout setting with existing centered behavior as the default.
- Render recording waveform and toggle stop control beside the MacBook notch when Notch Sides is selected.
- Keep transcribing, failure, update, and non-notch layouts on the existing centered path.

## Test plan
- [ ] Makefile build succeeds with the local Apple Development signing identity.
- [ ] Launch `build/Quill.app` and verify default Centered layout.
- [ ] Verify Notch Sides hold-mode recording.
- [ ] Verify Notch Sides toggle stop button.
- [ ] Verify transcribing/processing remains centered.
- [ ] Verify concurrent recording/transcription overlay ownership.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR is created against `woosublee/freeflow:main`.
