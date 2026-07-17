# Quill English/Korean Localization Design

## Goal

Make Quill's primary user experience consistently available in English and Korean using Apple's localization system, while preserving the current Makefile + direct `swiftc` build and avoiding a separate in-app language selector.

## Product decisions

- Quill supports English (`en`) and Korean (`ko`).
- English is the development and fallback language.
- Quill follows macOS system language and macOS per-app language settings.
- Language changes take effect after Quill is relaunched.
- Quill does not add its own language picker in this work.
- Developer-only Debug and Run Log surfaces remain English.

## Localization resources

`Resources/Localization/Localizable.xcstrings` is the source of truth for managed UI translations. The catalog contains an English value and a Korean value for every managed key.

The Makefile compiles the catalog with `xcstringstool` before code signing and copies the generated resources into the application bundle:

```text
Quill.app/Contents/Resources/
├── en.lproj/
│   ├── Localizable.strings
│   └── InfoPlist.strings
└── ko.lproj/
    ├── Localizable.strings
    └── InfoPlist.strings
```

`InfoPlist.strings` is maintained explicitly for the macOS privacy-purpose strings used by system permission dialogs. `Info.plist` declares English as `CFBundleDevelopmentRegion` and lists `en` and `ko` as supported localizations.

Catalog compilation is a required build step. Invalid catalog content or missing localization output fails the build. Changes to localization sources invalidate the app executable target so a normal `make` rebuild includes them.

## Source-code conventions

### SwiftUI literals

SwiftUI APIs that accept `LocalizedStringKey` keep direct English literals:

```swift
Text("Continue")
Button("Cancel") { ... }
Label("Settings", systemImage: "gearshape")
```

The English literal is the catalog key. Direct `Text("...")` literals are not prohibited because they are Apple's standard localizable SwiftUI form.

### Plain String and AppKit text

User-visible text created as `String` before it reaches a view uses `String(localized:)`. This includes:

- `AppState` status and error messages;
- `NSAlert` titles, descriptions, and buttons;
- notification titles and bodies;
- `NSOpenPanel` titles, messages, and prompts;
- model display descriptions;
- dynamic meeting and recording status text.

Example:

```swift
let message = String(localized: "Microphone access is required.")
```

Dynamic sentences use a localized interpolation as one complete key so translations can change word order:

```swift
String(localized: "Starts at \(time)")
```

### Verbatim and non-localized content

The following remain verbatim and are not catalog keys:

- provider and model identifiers;
- API field names, HTTP values, and MCP protocol text;
- SF Symbol names and asset identifiers;
- user transcripts, calendar event titles, custom vocabulary, macros, and custom prompts;
- default LLM prompt content whose language affects model behavior;
- external provider error text;
- `InstructionExecutionDetector` language-specific regex tokens;
- developer logs, debug panels, and Run Log text.

Where a plain `String` must appear verbatim in SwiftUI, the code uses `Text(verbatim:)` or another explicitly non-localized path.

## Included product surfaces

The first localization pass covers primary user-facing behavior:

- Setup and first-run permission guidance;
- regular Settings sections, excluding developer-only Debug and Run Log surfaces;
- menu-bar commands, status, and update actions;
- Note Browser empty states, actions, confirmation dialogs, playback controls, and Obsidian export;
- recording and meeting-reminder overlays;
- permission, confirmation, cancellation, and update alerts;
- Quill-owned error and recovery guidance;
- notification and file-picker copy;
- transcription model names and descriptions intended for users;
- macOS privacy-purpose strings;
- user-facing date and time labels.

## Date, time, and language labels

Hard-coded `ko_KR` locale and Korean date patterns are removed from Note Browser presentation. Date and time labels use `Date.FormatStyle` or a formatter configured from the current locale.

Transcription language and output language are independent product settings, not application-language controls. Their stored identifiers remain unchanged. Their user-visible display names are localized, so the Korean language option appears as `Korean` in the English UI and `한국어` in the Korean UI.

## Fallback and failure behavior

- English is the fallback for a missing Korean translation.
- A malformed String Catalog or failed `xcstringstool` compilation fails the build.
- A missing expected `en.lproj` or `ko.lproj` output fails the bundle verification test.
- Quill-owned wrapper text around an external provider error is localized; the provider's original error remains verbatim for diagnosis.
- Existing settings, persisted language codes, transcript content, and user prompts are not migrated or rewritten.

## Validation strategy

### Automated checks

1. Compile `Localizable.xcstrings` during the normal Makefile build.
2. Assert that the built app contains:
   - `en.lproj/Localizable.strings`;
   - `ko.lproj/Localizable.strings`;
   - `en.lproj/InfoPlist.strings`;
   - `ko.lproj/InfoPlist.strings`.
3. Parse the String Catalog and require English and Korean values for every managed key.
4. Protect the source from new unmanaged Korean UI literals using a narrow lint and explicit allowlist. Valid non-UI Korean content such as detector regexes, language self-names, and LLM prompt content is permitted.
5. Test representative plain-String lookups and dynamic interpolation in English and Korean.
6. Test that Note Browser date presentation uses the selected/current locale instead of forcing `ko_KR`.
7. Run the complete existing `make test` suite.

The lint does not ban all `Text("literal")` calls. Such a ban would reject correctly localizable SwiftUI code and miss AppKit, notification, and dynamic-string paths.

### Runtime checks

1. Build and launch Quill with English as the preferred app language.
2. Verify representative copy in Setup, regular Settings, menu bar, Note Browser, recording/meeting overlays, alerts, and date labels.
3. Set Quill's macOS per-app language to Korean and relaunch.
4. Verify the same representative flows in Korean, including dynamic values and date/time ordering.
5. Confirm Debug and Run Log surfaces remain usable in English and that user-generated content remains unchanged.

## Scope exclusions

This work does not add:

- an in-app language selector;
- live language switching without relaunch;
- translation of developer Debug or Run Log surfaces;
- translation of user content or LLM prompt defaults;
- translation or rewriting of external provider error payloads;
- broad restructuring of Settings, Setup, or AppState unrelated to localization.

## Completion criteria

- The normal Makefile build bundles valid English and Korean localization resources.
- Primary product surfaces render consistently in English and Korean after relaunch under the corresponding macOS app language.
- Managed SwiftUI and non-SwiftUI user-facing text uses localization lookup.
- Note Browser dates are locale-aware and no longer forced to Korean formatting.
- Explicit non-UI exceptions are documented and protected from accidental translation.
- All localization checks and the full test suite pass.
