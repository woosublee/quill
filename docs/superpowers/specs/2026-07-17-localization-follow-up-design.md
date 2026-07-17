# Localization Follow-up Design

## Context

The English/Korean localization implementation for issue #177 is complete, but runtime review found three consistency gaps:

1. The Note Browser headings `Recordings` and `Transcription` should remain English by explicit product preference.
2. Google Calendar reconnect and refresh-health messages are stored as raw English strings and therefore bypass localization.
3. The regular-user `Recording Overlay` settings card contains layout and waveform option copy that is missing from the String Catalog.

This follow-up keeps the existing localization architecture and makes only targeted copy and catalog changes.

## Display Language Policy

Use Korean for ordinary section names and explanatory UI when Korean is the preferred app language. Keep product and feature names in English, including `Note Browser`, `Recording Overlay`, and `Google Calendar`.

`Recordings` and `Transcription` are explicit exceptions: the two Note Browser headings remain English even though they are ordinary terms. Their rendering must make the verbatim intent visible in source code and localization audits.

Device and display names, persisted IDs, enum raw values, URLs, checksums, and provider error details remain unchanged.

## Note Browser

Change only the two headings at the top of the Note Browser sidebar:

- `Recordings`
- `Transcription`

Render them verbatim rather than through `LocalizedStringKey`. The record button, search field, empty states, actions, and other Note Browser copy continue to follow the selected language.

## Google Calendar Health Messages

Localize fixed user-facing health messages generated in `AppState` and fallback messages rendered by `SettingsView`, including:

- reconnect required for reminders and note titles
- reconnect required for reminders only
- reconnect required for calendar-based note titles
- temporary refresh failure messages
- partial calendar refresh messages

Use catalog-backed complete sentences for fixed messages. For messages containing `error.localizedDescription`, localize the surrounding prefix or sentence template and interpolate the original detail verbatim. Keep `Google Calendar` in English inside Korean translations.

Do not change health status enums, affected-feature values, token handling, or persistence.

## Recording Overlay Settings

Keep the card title `Recording Overlay` in English. Add English and Korean catalog entries for its ordinary option copy:

- notch-side and centered layout option titles
- both layout descriptions
- waveform section title
- waveform-only, hover-time, and time-only option titles
- all waveform option descriptions
- VoiceOver selection states `Selected` and `Not selected`

The existing display selector (`Show on`, `Active window (default)`, `Primary display`) remains catalog-backed. Physical display names remain verbatim.

Do not change overlay layout behavior, previews, persisted enum values, geometry, or animation.

## Validation

Extend localization resource tests to verify:

- the two Note Browser headings use explicit verbatim rendering and are allowlisted as intentional English exceptions
- `Note Browser`, `Recording Overlay`, and `Google Calendar` remain English product/feature names where required
- all Calendar health message keys have English and Korean values with compatible placeholders
- all regular-user Recording Overlay option and accessibility keys have English and Korean values
- Debug/Run Log-only overlay controls remain non-translatable

Run the full test suite and actual app-bundle localization validation. Rebuild and launch `Quill Dev` in Korean, then inspect the Note Browser, Calendar settings health state, and Appearance → Recording Overlay options. Production `/Applications/Quill.app` is not modified.

## Out of Scope

- a general terminology framework or centralized product-name registry
- changes to Debug/Run Log localization policy
- new UI, layout, behavior, or language picker
- translation of external provider details, device names, or display names
