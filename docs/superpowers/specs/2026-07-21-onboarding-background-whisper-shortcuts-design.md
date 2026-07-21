# Onboarding Background Whisper Download and Shortcut Design

## Context

The issue #185 five-step onboarding currently treats a Native Whisper download as a blocking model selection. Starting the download selects Whisper immediately, disables the Local/API cards and Apple Speech row, prevents Continue, and cancels the download when Setup or Settings closes. The Shortcut screen also edits only Hold to Talk while Toggle remains an easy-to-miss sentence.

This follow-up keeps the five-step flow while making model installation independent from setup navigation and allowing users to configure both recording workflows.

## Goals

- Keep Native Whisper downloading while the user navigates through Setup or uses Settings.
- Allow Local/API/model choices and Continue while a download is active.
- Make cancellation visible and directly actionable.
- Automatically switch to Native Whisper when a requested background install completes, unless the user explicitly chooses another backend after starting it.
- Configure both Hold to Talk and Tap to Toggle during onboarding.
- Require at least one recording shortcut before onboarding can continue.

## Non-goals

- Resuming a model download after the app process exits.
- Adding multiple concurrent model downloads.
- Adding post-processing or Context local models.
- Adding Paste Again or Recording Cancel configuration to onboarding.
- Changing Native Whisper artifact formats, checksums, or installation paths.

## Background Download Architecture

### Ownership

`AppState` remains the owner of the single Native Whisper installation task and progress state. It also owns a pending auto-selection state for the recommended Native Whisper model. This state must outlive `SetupView` and `ModelsSettingsView`, allowing both views to observe the same download after either window closes.

Starting an install from onboarding records that Native Whisper should be selected on successful completion. Existing Settings download entry points use the same AppState-owned intent so closing Settings does not lose the requested selection.

### Active Model During Download

Starting a download does not immediately change the active transcription backend. Apple Speech remains active and usable while the model downloads. The Processing screen therefore uses Apple Speech permission requirements until the download completes.

The Native Whisper row displays a non-selected download state:

- Download progress and downloaded size
- Copy explaining that Whisper will become active when ready
- The existing hover-to-reveal Cancel control (donut progress ring with an X overlay), unchanged from Settings today

The user can continue onboarding, select API Provider, explicitly select Apple Speech, or navigate backward while the download continues.

### Auto-selection Rules

A successful install automatically calls the existing:

```swift
setNoteBrowserTranscriptionChoice(
    .nativeWhisper(modelID: NativeWhisperModelCatalog.recommended.id)
)
```

Auto-selection occurs only while the AppState-owned pending selection remains active.

The pending selection is cleared when the user explicitly chooses a different backend after starting the download:

- Apple Speech
- API Standard
- Another Settings transcription choice
- Explicit download cancellation

Simply continuing from Processing while Apple Speech serves as the temporary backend does not clear the pending selection. This allows onboarding to proceed immediately and still honors the user's original request to use Whisper when ready.

If installation fails, Apple Speech remains active and the existing structured install issue is displayed. Retrying re-establishes the pending auto-selection intent.

### Window and App Lifecycle

Setup and Settings no longer cancel Native Whisper installation in `onDisappear` or window-close delegates. Closing either window leaves the AppState task running. Reopening either surface displays current progress through the existing published install state.

Explicit Cancel continues to cancel the task and delete the partial model using the existing installer cleanup path.

Quitting the app ends the active download. Download persistence or byte-range resume across app launches is outside this change. Because closing Setup or Settings no longer warns about this, `applicationShouldTerminate` shows a confirmation when a Native Whisper install is active, mirroring the existing recording-in-progress termination check (`AppState.requestTerminationWhileRecording()`). The user must confirm before the app (and the download) actually quits; canceling the quit leaves the download running.

## Processing Screen Behavior

- Local/API choice cards remain enabled during download.
- Apple Speech remains selectable during download.
- Continue remains enabled when the currently usable preset is valid.
- If the user stays on Local after requesting Whisper, Apple Speech is the temporary preset and Speech Recognition remains required.
- When Whisper installation completes, AppState switches to Native Whisper and the Permissions screen immediately stops requiring Speech Recognition.
- Selecting API or Apple Speech explicitly after starting the download cancels only the pending auto-selection, not the download itself.
- The download can finish in Setup, Settings, or while both windows are closed.

## Shortcut Screen

The single Shortcut screen contains two existing `ShortcutRoleSection` components.

### Hold to Talk

- Default: `Fn`
- Records while held and stops on release
- Supports Disabled, presets, saved custom binding, and new custom capture

### Tap to Toggle

- Default: `Cmd+Fn`
- Starts on the first press and stops on the second
- Supports Disabled, presets, saved custom binding, and new custom capture

Both sections use `AppState.setShortcut(_:for:)`, retaining existing conflict checks against each other, Paste Again, Recording Cancel, and command-mode modifiers.

### Continue Gate

Continue is enabled only when at least one of Hold to Talk or Tap to Toggle is active. If both are disabled, the screen shows a localized warning:

```text
Enable at least one recording shortcut to continue.
```

Paste Again remains disabled by default and Recording Cancel remains `Esc`. They are mentioned as later Settings options but are not editable in onboarding.

## Ready Summary

The Ready screen lists every active recording workflow separately:

- `Hold Fn to record`, when Hold to Talk is active
- `Tap Cmd+Fn to start and stop`, when Tap to Toggle is active

A disabled workflow is omitted. Since the Shortcut screen requires one active workflow, the summary always contains at least one recording instruction.

The processing summary reflects the active backend at that moment. If Whisper is still downloading, it shows Apple Speech as active and notes that Whisper will switch on when ready. If the install has completed, it shows Native Whisper.

## Localization and Accessibility

Add English and Korean catalog entries for:

- Background download and automatic-switch status
- Visible Cancel action and retry state
- Both shortcut section descriptions
- The at-least-one-shortcut warning
- Ready summary copy for active and pending processing states

The download Cancel control must have a visible label, keyboard focus support, and an accessibility label. Download progress remains exposed as text rather than only through the donut indicator.

## Testing

### SetupFlow and Source Contracts

- Downloading does not disable Local/API cards or Continue when Apple Speech is usable.
- Setup and Settings close paths do not invoke download cancellation.
- The Shortcut step contains Hold and Toggle sections and no Paste Again or Recording Cancel editor.
- Continue is blocked when both recording shortcuts are disabled.

### AppState Behavior

- Starting an install with auto-selection intent leaves Apple Speech active.
- Successful completion selects Native Whisper.
- Explicit Apple/API selection clears pending auto-selection without cancelling download.
- Explicit Cancel clears pending auto-selection and removes the partial file.
- Installation progress remains available after Setup or Settings view disappearance.
- Existing API credentials and feature settings remain unchanged.
- Quitting while a download is active prompts a confirmation; canceling the quit leaves the download running, confirming quits and cancels the download.

### UI and Bundle Verification

- Start Whisper download, navigate to Permissions and Shortcut, and verify progress continues in Settings.
- Verify the hover-to-reveal Cancel control works from both Setup and Settings.
- Verify the quit-time confirmation alert appears when quitting mid-download, and that both its Cancel and Quit-and-Cancel-Download paths behave as expected.
- Verify Apple Speech permission requirements while downloading and their removal after successful auto-switch.
- Configure Hold only, Toggle only, and both; verify Ready summary.
- Disable both and verify Continue remains disabled with localized guidance.
- Run full tests, localization bundle validation, and isolated English/Korean development builds.
