# Localization Follow-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Quill's English/Korean UI terminology intentional by keeping selected feature names in English, localizing Google Calendar health messages, and completing the regular-user Recording Overlay settings translations.

**Architecture:** Preserve the existing String Catalog and `localizedCatalogString`/`localizedCatalogFormat` helpers. Explicit English exceptions render verbatim or use catalog entries marked non-translatable, while ordinary UI and complete Calendar health sentences remain catalog-backed; persisted values, provider details, device names, and display names never change.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, Foundation localization, `Localizable.xcstrings`, `xcstringstool`, Make, macOS 13 deployment target.

## Global Constraints

- Supported application locales remain exactly `en` and `ko`.
- Keep `Note Browser`, `Recording Overlay`, and `Google Calendar` in English as product or feature names.
- Keep the Note Browser headings `Recordings` and `Transcription` in English as explicit user-approved exceptions.
- Translate ordinary section names, option labels, explanatory copy, and accessibility values into Korean.
- Keep developer-only Debug and Run Log surfaces in English.
- Do not translate provider error details, device names, display names, model IDs, URLs, checksums, enum raw values, or persisted identifiers.
- Do not change overlay layout behavior, Calendar health state transitions, token handling, persistence, geometry, or animation.
- Preserve the Makefile + direct `swiftc` build, the `CODESIGN_IDENTITY=Quill` development build policy, Sparkle integration, and macOS 13 minimum.
- Do not modify or install `/Applications/Quill.app`; runtime verification uses `build/Quill Dev.app` with bundle ID `com.woosublee.quill.dev`.

## File Structure

- `Sources/NoteBrowserView.swift` — render the two approved English headings verbatim.
- `Sources/SettingsView.swift` — keep approved feature card titles in English, localize ordinary Settings card titles, Calendar health fallbacks, Recording Overlay options, and accessibility values.
- `Sources/AppState.swift` — generate localized Calendar health messages at the point where health state is recorded while preserving external error details.
- `Resources/Localization/Localizable.xcstrings` — remain the source of truth for English/Korean values and intentional non-translatable feature names.
- `Tests/LocalizationResourceTests.swift` — audit verbatim exceptions, all regular-user `SettingsCard` titles, Calendar health call sites, and Recording Overlay catalog coverage.
- `Tests/SettingsLocalizationTests.swift` — validate representative English/Korean Calendar and Recording Overlay strings from compiled resources.

---

### Task 1: Make section-title language policy explicit

**Files:**
- Modify: `Sources/NoteBrowserView.swift:517-597`
- Modify: `Resources/Localization/Localizable.xcstrings`
- Modify: `Tests/LocalizationResourceTests.swift:56-58, 462-496`
- Modify: `Tests/SettingsLocalizationTests.swift:5-10, 63-70`

**Interfaces:**
- Consumes: `SettingsCard.init(_ title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content)`.
- Produces: two explicit `Text(verbatim:)` Note Browser headings; catalog-backed ordinary Settings card titles; intentional English feature-name entries with `shouldTranslate: false`.

- [ ] **Step 1: Write failing audits for the Note Browser exceptions and all regular Settings cards**

In `Tests/LocalizationResourceTests.swift`, call a new audit after the existing task-specific coverage:

```swift
try assertIntentionalEnglishProductCopy(root: root, catalogStrings: strings)
try assertRegularSettingsCardTitleCoverage(root: root, catalogStrings: strings)
```

Add these functions:

```swift
private static func assertIntentionalEnglishProductCopy(
    root: URL,
    catalogStrings: [String: Any]
) throws {
    let noteBrowser = try managedSource("Sources/NoteBrowserView.swift", root: root)
    assert(noteBrowser.contains("Text(verbatim: \"Recordings\")"))
    assert(noteBrowser.contains("Text(verbatim: \"Transcription\")"))
    assert(!noteBrowser.contains("Text(\"Recordings\")"))
    assert(!noteBrowser.contains("Text(\"Transcription\")"))

    for key in ["Note Browser", "Recording Overlay", "Google Calendar"] {
        let entry = catalogStrings[key] as? [String: Any]
        assert(entry?["shouldTranslate"] as? Bool == false, "Feature name must be an explicit English exception: \(key)")
        let localizations = entry?["localizations"] as? [String: Any]
        for language in ["en", "ko"] {
            let value = (((localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String)
            assert(value == key, "Feature name must stay English for \(language): \(key)")
        }
    }
}

private static func assertRegularSettingsCardTitleCoverage(
    root: URL,
    catalogStrings: [String: Any]
) throws {
    let settings = try managedSource("Sources/SettingsView.swift", root: root)
    let pattern = try NSRegularExpression(pattern: #"SettingsCard\(\"((?:\\.|[^\"\\])*)\""#)
    let range = NSRange(settings.startIndex..., in: settings)
    let englishFeatureNames: Set<String> = ["Note Browser", "Recording Overlay", "Google Calendar"]

    for match in pattern.matches(in: settings, range: range) {
        guard let titleRange = Range(match.range(at: 1), in: settings) else { continue }
        let key = String(settings[titleRange])
        assertCatalogTranslations(
            for: key,
            catalogStrings: catalogStrings,
            requiresTranslation: !englishFeatureNames.contains(key)
        )
    }
}
```

Remove the marker-limited implementation of `assertLocalizedStringKeyHelperLiteralCoverage` and its call, because the new regular-card audit scans the entire non-debug `SettingsView` returned by `managedSource`.

- [ ] **Step 2: Add failing compiled-resource expectations for title policy**

In `Tests/SettingsLocalizationTests.swift`, invoke and add:

```swift
try testSettingsSectionTitlePolicy()

private static func testSettingsSectionTitlePolicy() throws {
    let bundle = try compiledLocalizationBundle()

    for key in ["Note Browser", "Recording Overlay", "Google Calendar"] {
        assert(localizedCatalogString(key, language: "en", bundle: bundle) == key)
        assert(localizedCatalogString(key, language: "ko", bundle: bundle) == key)
    }

    let ordinaryKoreanTitles: [String: String] = [
        "App Appearance": "앱 외관",
        "Meeting Recording Reminders": "회의 녹음 알림",
        "Language": "언어",
        "System Prompt": "시스템 프롬프트",
        "Instruction Guard": "명령 보호",
        "Context Prompt": "컨텍스트 프롬프트",
        "Dictation Shortcuts": "받아쓰기 단축키",
        "Audio During Dictation": "받아쓰기 중 오디오",
        "Clipboard": "클립보드",
        "Voice Macros": "음성 매크로",
        "Sound Volume": "소리 크기",
        "Build": "빌드"
    ]
    for (key, expected) in ordinaryKoreanTitles {
        assert(localizedCatalogString(key, language: "ko", bundle: bundle) == expected)
    }
}
```

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```bash
make /tmp/LocalizationResourceTests
/tmp/LocalizationResourceTests
swiftc -parse-as-library \
  Sources/LocalizedStringLookup.swift \
  Sources/TranscriptionLanguage.swift \
  Sources/TranscriptionModel.swift \
  Sources/NativeWhisperModel.swift \
  Sources/AudioImportOptions.swift \
  Tests/SettingsLocalizationTests.swift \
  -o /tmp/SettingsLocalizationTests
/tmp/SettingsLocalizationTests
```

Expected: `LocalizationResourceTests` fails because the two headings are localized literals and feature-name catalog entries are missing; `SettingsLocalizationTests` fails on missing ordinary card-title translations.

- [ ] **Step 4: Render the two approved headings verbatim**

In `Sources/NoteBrowserView.swift`, replace only the two heading initializers:

```swift
Text(verbatim: "Recordings")
```

```swift
Text(verbatim: "Transcription")
```

Do not change the nearby record button, transcription picker, search field, or empty-state copy.

- [ ] **Step 5: Add explicit feature-name and ordinary-card catalog entries**

Update `Resources/Localization/Localizable.xcstrings` without changing unrelated entries. Add `Note Browser`, `Recording Overlay`, and `Google Calendar` with English and Korean values equal to the English key and `shouldTranslate: false`.

Add or complete ordinary card-title translations using this exact mapping:

```python
ordinary_titles = {
    "App Appearance": ("App Appearance", "앱 외관"),
    "Meeting Recording Reminders": ("Meeting Recording Reminders", "회의 녹음 알림"),
    "Language": ("Language", "언어"),
    "System Prompt": ("System Prompt", "시스템 프롬프트"),
    "Instruction Guard": ("Instruction Guard", "명령 보호"),
    "Context Prompt": ("Context Prompt", "컨텍스트 프롬프트"),
    "Dictation Shortcuts": ("Dictation Shortcuts", "받아쓰기 단축키"),
    "Audio During Dictation": ("Audio During Dictation", "받아쓰기 중 오디오"),
    "Clipboard": ("Clipboard", "클립보드"),
    "Voice Macros": ("Voice Macros", "음성 매크로"),
    "Sound Volume": ("Sound Volume", "소리 크기"),
    "Build": ("Build", "빌드"),
}
```

Retain existing translations such as `App`, `Updates`, `Permissions`, `Transcription`, `Custom Vocabulary`, `Edit Mode`, and `Microphone`; the full-card audit must validate those too.

- [ ] **Step 6: Recompile resources and verify GREEN**

Run:

```bash
rm -rf build/localization
make build/localization/.compiled
make /tmp/LocalizationResourceTests
/tmp/LocalizationResourceTests
swiftc -parse-as-library \
  Sources/LocalizedStringLookup.swift \
  Sources/TranscriptionLanguage.swift \
  Sources/TranscriptionModel.swift \
  Sources/NativeWhisperModel.swift \
  Sources/AudioImportOptions.swift \
  Tests/SettingsLocalizationTests.swift \
  -o /tmp/SettingsLocalizationTests
/tmp/SettingsLocalizationTests
```

Expected: both binaries print their `passed` message.

- [ ] **Step 7: Commit the title-policy change**

```bash
git add Sources/NoteBrowserView.swift Resources/Localization/Localizable.xcstrings \
  Tests/LocalizationResourceTests.swift Tests/SettingsLocalizationTests.swift
git commit -m "Clarify localized section titles" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Localize Google Calendar health messages

**Files:**
- Modify: `Sources/AppState.swift:2163-2176, 2213-2252, 2338-2363, 6035-6136`
- Modify: `Sources/SettingsView.swift:888-910`
- Modify: `Resources/Localization/Localizable.xcstrings`
- Modify: `Tests/LocalizationResourceTests.swift:227-255`
- Modify: `Tests/SettingsLocalizationTests.swift:5-11, 63-70`

**Interfaces:**
- Consumes: `localizedCatalogString(_:language:bundle:)` and `localizedCatalogFormat(_:_:language:bundle:)` from `Sources/LocalizedStringLookup.swift`.
- Produces: localized `GoogleCalendarHealth.message` values while preserving `error.localizedDescription` as a verbatim `%@` argument.

- [ ] **Step 1: Write failing Calendar health source and catalog audits**

Invoke a new function from `LocalizationResourceTests.main()`:

```swift
try assertGoogleCalendarHealthMessageCoverage(root: root, catalogStrings: strings)
```

Add:

```swift
private static func assertGoogleCalendarHealthMessageCoverage(
    root: URL,
    catalogStrings: [String: Any]
) throws {
    let appState = try managedSource("Sources/AppState.swift", root: root)
    let settings = try managedSource("Sources/SettingsView.swift", root: root)
    let fixedKeys = [
        "Google Calendar needs reconnecting.",
        "Google Calendar needs reconnecting. Reconnect to restore meeting reminders and calendar-based note titles.",
        "Google Calendar needs reconnecting. Reconnect to restore meeting reminders.",
        "Google Calendar needs reconnecting. Calendar-based note titles may be unavailable.",
        "Some Google calendars could not be refreshed. Reminders may be incomplete.",
        "Some Google calendars could not be refreshed. Calendar-based note titles may be incomplete.",
        "Quill can’t access Google Calendar. Reconnect to restore meeting reminders and calendar-based note titles.",
        "Quill couldn’t refresh Google Calendar just now. Recording still works; reminders or note titles may be incomplete.",
        "Reconnect Google Calendar to keep meeting recording reminders working.",
        "Calendar reminders may be incomplete until the next successful refresh."
    ]
    let formattedKeys = [
        "Unable to refresh Google Calendar reminders: %@",
        "Unable to refresh Google Calendar: %@",
        "Unable to refresh Google Calendar for note titles: %@"
    ]

    for key in fixedKeys + formattedKeys {
        assertCatalogTranslations(for: key, catalogStrings: catalogStrings, requiresTranslation: true)
    }
    for key in fixedKeys where appState.contains(key) {
        assert(appState.contains("localizedCatalogString(\"\(key)\")"), "Calendar message bypasses the catalog: \(key)")
    }
    for key in fixedKeys where settings.contains(key) {
        assert(settings.contains("localizedCatalogString(\"\(key)\")"), "Settings fallback bypasses the catalog: \(key)")
    }
    for key in formattedKeys {
        assert(appState.contains("localizedCatalogFormat(\"\(key)\", error.localizedDescription)"), "Calendar detail must stay a verbatim format argument: \(key)")
    }
}
```

- [ ] **Step 2: Add failing English/Korean Calendar copy assertions**

In `SettingsLocalizationTests.swift`, invoke and add:

```swift
try testGoogleCalendarHealthMessagesLocalizeWithoutChangingDetail()

private static func testGoogleCalendarHealthMessagesLocalizeWithoutChangingDetail() throws {
    let bundle = try compiledLocalizationBundle()
    let detail = "HTTP 503: upstream unavailable"

    assert(
        localizedCatalogString(
            "Google Calendar needs reconnecting. Reconnect to restore meeting reminders and calendar-based note titles.",
            language: "ko",
            bundle: bundle
        ) == "Google Calendar를 다시 연결해야 합니다. 회의 알림과 캘린더 기반 노트 제목을 복원하려면 다시 연결하세요."
    )
    assert(
        localizedCatalogFormat(
            "Unable to refresh Google Calendar: %@",
            detail,
            language: "ko",
            bundle: bundle
        ) == "Google Calendar를 새로 고치지 못했습니다: \(detail)"
    )
}
```

- [ ] **Step 3: Run focused tests and verify RED**

Run the same two binaries from Task 1.

Expected: failures report missing Calendar keys and raw English call sites.

- [ ] **Step 4: Route fixed and formatted Calendar messages through catalog helpers**

Apply these patterns in `Sources/AppState.swift`:

```swift
private static func googleCalendarReconnectMessage() -> String {
    localizedCatalogString("Google Calendar needs reconnecting. Reconnect to restore meeting reminders and calendar-based note titles.")
}
```

```swift
message: localizedCatalogString("Google Calendar needs reconnecting. Reconnect to restore meeting reminders.")
```

```swift
message: localizedCatalogFormat(
    "Unable to refresh Google Calendar reminders: %@",
    error.localizedDescription
)
```

```swift
message: localizedCatalogString("Google Calendar needs reconnecting. Calendar-based note titles may be unavailable.")
```

Use the equivalent catalog helper for every fixed or formatted message listed in Step 1. In `GoogleCalendarHealthError.errorDescription`, return:

```swift
localizedCatalogString("Google Calendar needs reconnecting.")
```

In `Sources/SettingsView.swift`, change all four fallback branches to `localizedCatalogString(...)` while leaving status enums and icons unchanged.

- [ ] **Step 5: Add exact Calendar translations to the catalog**

Add English values equal to each key and these Korean values:

```python
calendar_messages = {
    "Google Calendar needs reconnecting.": "Google Calendar를 다시 연결해야 합니다.",
    "Google Calendar needs reconnecting. Reconnect to restore meeting reminders and calendar-based note titles.": "Google Calendar를 다시 연결해야 합니다. 회의 알림과 캘린더 기반 노트 제목을 복원하려면 다시 연결하세요.",
    "Google Calendar needs reconnecting. Reconnect to restore meeting reminders.": "Google Calendar를 다시 연결해야 합니다. 회의 알림을 복원하려면 다시 연결하세요.",
    "Google Calendar needs reconnecting. Calendar-based note titles may be unavailable.": "Google Calendar를 다시 연결해야 합니다. 캘린더 기반 노트 제목을 사용할 수 없을 수 있습니다.",
    "Unable to refresh Google Calendar reminders: %@": "Google Calendar 알림을 새로 고치지 못했습니다: %@",
    "Some Google calendars could not be refreshed. Reminders may be incomplete.": "일부 Google 캘린더를 새로 고치지 못했습니다. 알림이 누락될 수 있습니다.",
    "Unable to refresh Google Calendar: %@": "Google Calendar를 새로 고치지 못했습니다: %@",
    "Some Google calendars could not be refreshed. Calendar-based note titles may be incomplete.": "일부 Google 캘린더를 새로 고치지 못했습니다. 캘린더 기반 노트 제목이 불완전할 수 있습니다.",
    "Unable to refresh Google Calendar for note titles: %@": "노트 제목에 사용할 Google Calendar를 새로 고치지 못했습니다: %@",
    "Quill can’t access Google Calendar. Reconnect to restore meeting reminders and calendar-based note titles.": "Quill에서 Google Calendar에 접근할 수 없습니다. 회의 알림과 캘린더 기반 노트 제목을 복원하려면 다시 연결하세요.",
    "Quill couldn’t refresh Google Calendar just now. Recording still works; reminders or note titles may be incomplete.": "현재 Quill에서 Google Calendar를 새로 고치지 못했습니다. 녹음은 계속 사용할 수 있지만 알림이나 노트 제목이 불완전할 수 있습니다.",
    "Reconnect Google Calendar to keep meeting recording reminders working.": "회의 녹음 알림을 계속 사용하려면 Google Calendar를 다시 연결하세요.",
    "Calendar reminders may be incomplete until the next successful refresh.": "다음 새로 고침에 성공할 때까지 캘린더 알림이 누락될 수 있습니다."
}
```

Keep the `%@` placeholder exactly once and in the same order in both locales.

- [ ] **Step 6: Recompile resources and verify GREEN**

Run:

```bash
rm -rf build/localization
make build/localization/.compiled
make /tmp/LocalizationResourceTests
/tmp/LocalizationResourceTests
swiftc -parse-as-library \
  Sources/LocalizedStringLookup.swift \
  Sources/TranscriptionLanguage.swift \
  Sources/TranscriptionModel.swift \
  Sources/NativeWhisperModel.swift \
  Sources/AudioImportOptions.swift \
  Tests/SettingsLocalizationTests.swift \
  -o /tmp/SettingsLocalizationTests
/tmp/SettingsLocalizationTests
```

Expected: both pass, and the test detail remains byte-for-byte `HTTP 503: upstream unavailable` inside the Korean sentence.

- [ ] **Step 7: Commit Calendar message localization**

```bash
git add Sources/AppState.swift Sources/SettingsView.swift \
  Resources/Localization/Localizable.xcstrings \
  Tests/LocalizationResourceTests.swift Tests/SettingsLocalizationTests.swift
git commit -m "Localize Calendar health messages" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Complete Recording Overlay settings localization

**Files:**
- Modify: `Sources/SettingsView.swift:536-605, 628-723`
- Modify: `Resources/Localization/Localizable.xcstrings`
- Modify: `Tests/LocalizationResourceTests.swift:257-285`
- Modify: `Tests/SettingsLocalizationTests.swift:5-11, 63-70`

**Interfaces:**
- Consumes: existing `LocalizedStringKey` option-row title and subtitle properties.
- Produces: catalog-backed layout/waveform options and localized VoiceOver selection values; no changes to `RecordingOverlayLayout` or `OverlayWaveformDisplayMode`.

- [ ] **Step 1: Extend the overlay resource audit with all regular-user option keys**

Add these keys to the regular-user overlay array in `assertTask6OverlayCoverage`:

```swift
"Recording Overlay",
"Notch-side menu-bar overlay",
"Shows recording status beside the camera notch when supported, without covering app tabs or toolbars.",
"Centered drop-down pill",
"Shows a single centered pill below the menu bar. More visible, but it can cover a thin strip of the active app.",
"Waveform display",
"Waveform only",
"Show the live audio waveform while recording.",
"Show elapsed time on hover",
"Show the waveform; hover it to peek the elapsed recording time.",
"Show elapsed time instead of waveform",
"Replace the waveform with a running elapsed-time counter.",
"Show on",
"Active window (default)",
"Primary display",
"Selected",
"Not selected"
```

For `Recording Overlay`, call `assertCatalogTranslations` without `requiresTranslation` and separately rely on Task 1's English-feature exception audit. Require translation for every other key.

Also assert:

```swift
let settings = try managedSource("Sources/SettingsView.swift", root: root)
assert(settings.components(separatedBy: "localizedCatalogString(isSelected ? \"Selected\" : \"Not selected\")").count == 3)
```

- [ ] **Step 2: Add failing representative Korean overlay assertions**

In `SettingsLocalizationTests.swift`, invoke and add:

```swift
try testRecordingOverlaySettingsCopyLocalizes()

private static func testRecordingOverlaySettingsCopyLocalizes() throws {
    let bundle = try compiledLocalizationBundle()
    let expected: [String: String] = [
        "Notch-side menu-bar overlay": "노치 양옆 메뉴 막대 오버레이",
        "Centered drop-down pill": "중앙 드롭다운 필",
        "Waveform display": "파형 표시",
        "Waveform only": "파형만 표시",
        "Show elapsed time on hover": "포인터를 올리면 경과 시간 표시",
        "Show elapsed time instead of waveform": "파형 대신 경과 시간 표시",
        "Selected": "선택됨",
        "Not selected": "선택되지 않음"
    ]
    for (key, value) in expected {
        assert(localizedCatalogString(key, language: "ko", bundle: bundle) == value)
    }
}
```

- [ ] **Step 3: Run focused tests and verify RED**

Run the two focused test binaries from Task 1.

Expected: missing overlay keys fail the catalog audit and compiled-resource expectations.

- [ ] **Step 4: Localize the dynamic accessibility values explicitly**

In both `OverlayLayoutOptionRow` and `OverlayWaveformModeOptionRow`, replace:

```swift
.accessibilityValue(isSelected ? "Selected" : "Not selected")
```

with:

```swift
.accessibilityValue(localizedCatalogString(isSelected ? "Selected" : "Not selected"))
```

This is required because the ternary expression produces a dynamic `String` rather than a `LocalizedStringKey`.

- [ ] **Step 5: Add exact Recording Overlay translations**

Add English values equal to each key and these Korean values:

```python
overlay_messages = {
    "Notch-side menu-bar overlay": "노치 양옆 메뉴 막대 오버레이",
    "Shows recording status beside the camera notch when supported, without covering app tabs or toolbars.": "지원되는 경우 앱 탭이나 도구 막대를 가리지 않고 카메라 노치 양옆에 녹음 상태를 표시합니다.",
    "Centered drop-down pill": "중앙 드롭다운 필",
    "Shows a single centered pill below the menu bar. More visible, but it can cover a thin strip of the active app.": "메뉴 막대 아래 중앙에 하나의 필을 표시합니다. 더 잘 보이지만 활성 앱의 얇은 영역을 가릴 수 있습니다.",
    "Waveform display": "파형 표시",
    "Waveform only": "파형만 표시",
    "Show the live audio waveform while recording.": "녹음 중 실시간 오디오 파형을 표시합니다.",
    "Show elapsed time on hover": "포인터를 올리면 경과 시간 표시",
    "Show the waveform; hover it to peek the elapsed recording time.": "파형을 표시하고 포인터를 올리면 녹음 경과 시간을 잠시 보여 줍니다.",
    "Show elapsed time instead of waveform": "파형 대신 경과 시간 표시",
    "Replace the waveform with a running elapsed-time counter.": "파형을 실행 중인 경과 시간 카운터로 바꿉니다.",
    "Selected": "선택됨",
    "Not selected": "선택되지 않음"
}
```

Retain the existing Korean values for `Show on`, `Active window (default)`, and `Primary display`. Keep physical `NSScreen.localizedName` values rendered with `Text(verbatim:)`.

- [ ] **Step 6: Recompile resources and verify GREEN**

Run:

```bash
rm -rf build/localization
make build/localization/.compiled
make /tmp/LocalizationResourceTests
/tmp/LocalizationResourceTests
swiftc -parse-as-library \
  Sources/LocalizedStringLookup.swift \
  Sources/TranscriptionLanguage.swift \
  Sources/TranscriptionModel.swift \
  Sources/NativeWhisperModel.swift \
  Sources/AudioImportOptions.swift \
  Tests/SettingsLocalizationTests.swift \
  -o /tmp/SettingsLocalizationTests
/tmp/SettingsLocalizationTests
```

Expected: both pass with Korean overlay option values.

- [ ] **Step 7: Commit Recording Overlay copy**

```bash
git add Sources/SettingsView.swift Resources/Localization/Localizable.xcstrings \
  Tests/LocalizationResourceTests.swift Tests/SettingsLocalizationTests.swift
git commit -m "Localize Recording Overlay settings" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Run full regression and Quill Dev runtime verification

**Files:**
- Verify only: all files changed in Tasks 1-3
- Do not modify: `/Applications/Quill.app`

**Interfaces:**
- Consumes: committed outputs from Tasks 1-3.
- Produces: fresh full-test, packaged-bundle, and Korean GUI evidence.

- [ ] **Step 1: Run the full test suite**

```bash
make test
```

Expected: every test binary prints `passed`; no test exits nonzero.

- [ ] **Step 2: Validate the actual packaged app localization resources**

```bash
make localization-bundle-test CODESIGN_IDENTITY="Quill"
codesign --verify --deep --strict build/Quill.app
```

Expected: `LocalizationResourceTests bundle validation passed` and `codesign` exits 0. Do not install the app.

- [ ] **Step 3: Rebuild and open the development app in Korean**

```bash
pkill -f '/Quill Dev.app/Contents/MacOS/Quill Dev' 2>/dev/null || true
make run CODESIGN_IDENTITY="Quill"
```

If the current per-app language is not Korean, relaunch only the built development executable:

```bash
pkill -f '/Quill Dev.app/Contents/MacOS/Quill Dev' 2>/dev/null || true
'build/Quill Dev.app/Contents/MacOS/Quill Dev' -AppleLanguages '(ko)' -AppleLocale ko_KR
```

Expected: process path is under `build/Quill Dev.app`, bundle ID is `com.woosublee.quill.dev`, and the production app remains untouched.

- [ ] **Step 4: Inspect the Note Browser title policy**

Open the Note Browser and verify:

- `Recordings` remains English.
- `Transcription` remains English.
- record actions, search, and empty-state copy remain Korean.

Capture the Note Browser window as evidence.

- [ ] **Step 5: Inspect ordinary Settings titles and Recording Overlay options**

Open Settings → Appearance and verify:

- `Note Browser` and `Recording Overlay` remain English.
- ordinary card title `앱 외관` is Korean.
- both overlay layout titles and descriptions are Korean.
- all waveform option titles and descriptions are Korean.
- display names remain unchanged/verbatim.

Capture the Settings window as evidence.

- [ ] **Step 6: Exercise the Calendar reconnect state**

Use only the development bundle's preferences and token state to produce a connected-metadata/no-valid-token health check. Open Settings → Calendar and verify:

- `Google Calendar` remains English.
- the reconnect status and explanatory health message are Korean.
- no provider/OAuth detail is translated or altered when one is present.

Do not reset or alter the production `com.woosublee.quill` bundle's preferences or permissions. Capture the Calendar settings window.

- [ ] **Step 7: Run final diff and repository checks**

```bash
git diff --check
git status --short --branch
git log --oneline -6
```

Expected: no whitespace errors; only intentional follow-up commits exist; working tree is clean.

- [ ] **Step 8: Request one final focused code review**

Review the range from commit `4f4df48` to `HEAD` for only:

- intentional English exceptions versus missing translations
- Calendar external-detail preservation
- complete regular-user Recording Overlay coverage
- Debug/Run Log exclusion preservation

Fix only verified Critical or Important issues, rerun Steps 1-7 after any fix, and avoid repeated review loops.
