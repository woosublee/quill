# Local-only setup and notification permission design

## Goal

First-time setup should let users finish Quill setup without a Groq or other API key when they plan to use local transcription. Setup should also introduce notification permission for calendar recording reminders without making that permission mandatory.

## Current behavior

`SetupView` places the API Key step near the start of onboarding. The Continue button is disabled while the API key field is empty, and the only forward path validates the entered key before advancing. Notification permission can be granted later from Settings, but setup does not mention it.

## Proposed setup flow

Keep the existing onboarding sequence and add two focused changes:

1. The API Key step keeps the existing provider validation path and adds a secondary `Skip for local-only` action.
2. A new Notifications step appears with the other permission-oriented setup steps.

This avoids a larger mode-selection redesign while making the local-only path explicit.

## API Key step behavior

The primary Continue button remains the API validation path:

- Trim the entered API key and provider base URL.
- Persist the resolved base URL.
- Validate the key with the current `TranscriptionService.validateAPIKey` behavior.
- Persist the key only when validation succeeds.

The new `Skip for local-only` action:

- Does not call API validation.
- Sets `appState.useLocalTranscription = true`.
- Sets `appState.localTranscriptionModel` to the Apple Speech model.
- Disables post-processing, context capture, realtime streaming, and Edit Mode until the user enables/configures API-backed features later.
- Leaves API key storage empty.
- Advances to the next setup step.

The API step copy should state that an API provider is needed for cloud transcription, AI post-processing/context features, and Edit Mode, but can be configured later in Settings.

## Notifications step behavior

Add a setup step that uses `AppNotificationManager.shared.notificationSettings()` and `requestAuthorization()`.

The step shows:

- Granted state when authorization is `.authorized` or `.provisional`.
- `Grant Access` when authorization has not been requested.
- `Open Settings` when authorization is `.denied`.
- A clear note that notification access is optional and can be enabled later in Settings.

Continue is always enabled on this step. Denying or skipping notification access must not block setup completion.

## Data flow

- Setup loads existing API/provider settings from `AppState` on appear.
- API validation continues to update API provider values through existing `AppState` properties.
- Local-only skip updates the transcription mode and local model properties needed for immediate API-free transcription, and turns off API-backed post-processing/context/realtime/Edit Mode defaults.
- `AppState.makeTranscriptionService()` uses the current local transcription configuration so setup test transcription and shared transcription paths honor local-only mode.
- Notification status is local view state refreshed on appear and when the app becomes active.
- Calendar reminder scheduling already checks notification authorization before adding requests, so setup does not need to special-case scheduler behavior.

## Error handling

- Existing API validation errors remain inline on the API step.
- Local-only skip has no network or validation error path.
- Notification authorization failures are reflected by refreshed authorization status. If denied, the action changes to opening System Settings.

## Testing and verification

Add or update lightweight tests only where practical for pure logic. The main verification is app-level because the changes are SwiftUI setup flow and macOS permission UI:

- Build through the Makefile using the development app name, development bundle ID, and explicit code signing identity.
- Run the built development app.
- Reset setup state for the development bundle if needed.
- Verify API key entry still validates and advances.
- Verify empty API key no longer blocks when using `Skip for local-only`.
- Verify skip selects local transcription with Apple Speech, disables API-backed post-processing/context/realtime/Edit Mode defaults, and allows the test transcription step to proceed without an API key.
- Verify shared transcription service creation preserves local mode, local model, local whisper path, and transcription language settings.
- Verify the Notifications step shows Grant Access/Open Settings/Granted states and Continue remains available in every state.
- Verify Settings still exposes API provider and notification permission controls after setup.
