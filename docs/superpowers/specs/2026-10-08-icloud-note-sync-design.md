# iCloud Note Sync Across Macs — Design

**Date:** 2026-10-08
**Status:** Draft — awaiting review
**Mockup:** https://claude.ai/artifact/4na7Q5WmB7yP8NGePqbMPH

## Goal

Let one person see and manage the same Quill notes on every Mac signed in
to their iCloud account: transcripts, summaries, titles, calendar events,
and audio. Notes that already exist on each Mac move into the shared list
when sync is turned on. The record format is shared with a future iPhone
app, which lives in the private `quill-universal` repository.

## Decisions

| Topic | Decision |
|---|---|
| Repository | Public Quill. Mac-to-Mac sync is free. The iPhone app, its purchase, and its sync client stay in the private repository and use the same container. This replaces the 2026-08-13 rule that CloudKit lives only in the private fork. Only apps signed by the team can open the container, so the public code alone does not give anyone access to it. |
| Engine | `CKSyncEngine` against the private database. Sync needs macOS 14 or later. On macOS 13 the app runs as today and the sync tab says sync needs macOS 14. |
| Storage model | Local first. The Core Data store and asset files stay the source the app reads. iCloud is the channel and the shared copy. |
| What syncs | Notes only. Settings, vocabulary, prompts, API keys, and calendar sign-ins do not sync. |
| Fields | Fields the user sees sync. Screenshots, window titles, app names, bundle IDs, selected and captured text, and raw prompts stay on the Mac that made the note. |
| Audio | All audio syncs. Other Macs download it only when it is played, retranscribed, or exported. |
| Conflicts | Per field: the later edit wins. Different fields edited on two Macs both survive. |
| Deletion | A delete reaches every Mac. The note sits in Recently Deleted for 30 days, then it is purged everywhere. |
| Existing notes | Turning sync on uploads every finished note on that Mac, audio included. Each Mac that turns sync on adds its notes, so the lists merge. |

## Current state

- `PipelineHistoryStore` (Core Data, `PipelineHistory.sqlite` in
  `AppName.applicationSupportDirectory`) holds one `PipelineHistoryEntry`
  for each `PipelineHistoryItem`. It is the only writer: `append`, `update`,
  and `delete`.
- `NoteAssetStore` keeps audio files in `audio/` and transcript files in
  `transcripts/`, named by UUID and referenced from the item.
- History is not trimmed (`maxPipelineHistoryCount = Int.max`). Deleting a
  note removes the entry and its assets right away. There is no trash.
- Notes still in progress are marked by `postProcessingStatus`: live
  recording, importing, cloud transcribing, and recovery placeholders.
- The app targets macOS 13. Entitlements: audio input, disabled library
  validation, calendars. No iCloud entitlement or provisioning profile.
- Builds are signed with Developer ID (`release.yml`, local `make`).

## Architecture

New units, each with one job:

1. **`NoteSyncRecord`** (pure). It maps a `PipelineHistoryItem` to the
   CloudKit fields of a `Note` record and maps them back. It drops every
   local-only field. It carries `schemaVersion` and keeps any field it does
   not know, so a note written by a newer build survives a round trip
   through an older one.
2. **`NoteFieldClock`** (pure). It stores one modification time per synced
   field group: title, raw transcript, edited transcript, summary, calendar
   match, recording times, language, and deletion. `merge(local:remote:)`
   keeps, for each group, the value with the later time. A tie goes to the
   larger device ID so that every Mac resolves it the same way.
3. **`NoteSyncCoordinator`** (macOS 14, `CKSyncEngine` delegate).
   - It loads and saves the engine's state serialization in
     `Application Support/Quill/Sync/engine-state`.
   - It turns `append`, `update`, and `delete` calls from
     `PipelineHistoryStore` into pending record changes.
   - It merges fetched records with `NoteFieldClock` and writes the result
     through the store.
   - It handles account changes, quota errors, and retries.
   - It reaches CloudKit through a small protocol, so tests use a fake.
4. **`NoteAudioSync`**. It uploads audio as `NoteAudio` records in a
   separate zone, splits large files into parts, and downloads parts on
   demand with `CKFetchRecordsOperation`.
5. **`SyncSettingsView`** and **`RecentlyDeletedView`**: the UI.

`PipelineHistoryStore` stays the only writer. The coordinator observes it
through one hook added to `append`, `update`, and `delete`. View code
changes only for Recently Deleted and the audio download states.

### Core Data changes (lightweight migration)

- `fieldClockJSON: Data?` holds the `NoteFieldClock`.
- `deletedAt: Date?`: a non-nil value means the note is in Recently Deleted.
- `audioAvailability: String?`: local, remote (not downloaded), or
  uploading elsewhere.

Existing notes get a clock stamped with their `timestamp` the first time
they load.

### CloudKit layout

- Container `iCloud.com.woosublee.quill`, private database.
- Zone `Notes`, record type `Note`, record name = the note's UUID. The
  fields are the synced fields plus the field clock and `deletedAt`. The
  transcript file goes in a `CKAsset`.
- Zone `NoteAudio`, record type `NoteAudio`, record name
  `<note UUID>-<part>`. Each part is a `CKAsset` of up to 50 MB, plus a
  part count and the SHA-256 of the whole file.
- The engine fetches `Notes` only (`FetchChangesOptions.scope` excludes
  `NoteAudio`). Audio is fetched by record ID when needed.

### What is never uploaded

`contextScreenshotDataURL`, `contextScreenshotStatus`, `contextWindowTitle`,
`contextAppName`, `contextBundleIdentifier`, `selectedText`,
`capturedSelection`, `postProcessingPrompt`, `systemPrompt`,
`contextSystemPrompt`, `contextPrompt`, `contextSummary`, `debugStatus`,
`customSystemPrompt`, and `customVocabulary`. A received note leaves these
empty. A test asserts this list against the record mapping.

Notes in progress (live recording, importing, cloud transcribing,
recovered or unrecovered placeholders) are not sent until they settle.
Recovery archives and in-flight audio never sync.

## Data flow

**Local change.** The store saves, the hook enqueues
`.saveRecord(noteID)`, and the engine asks for the record. The coordinator
builds it from the current item. Text goes first. Audio parts are
enqueued after the note record has been sent.

**Remote change.** The engine delivers the fetched `Note`. The coordinator
decodes it, merges it with the local item if one exists, and saves through
the store with the hook muted, so the change is not sent back. The note
list updates through the normal `pipelineHistory` publishing.

**Audio on another Mac.** The note shows `audioAvailability = remote`.
The existing audio bar stays. Only its play button changes: a download
button before the audio is local, a filling ring with a stop mark while
downloading, and a dimmed button with the reason in the time label when it
can't download. The waveform shows flat placeholder bars until the file
arrives, and the duration comes from the recording times. When the
download finishes, playback starts. Retranscribe and Export download first
in the same way. The file is saved under `audio/` once its hash matches,
and later uses are local.

**Delete.** Deleting sets `deletedAt` and syncs. The note moves to Recently
Deleted on every Mac. Restore clears `deletedAt`. "Delete Now", or 30 days
after `deletedAt`, deletes the `Note` and `NoteAudio` records and the local
entry and assets. Each Mac purges on its own after 30 days, and a server
delete that arrives is applied as a purge.

## Turning sync on and off

The sync settings tab comes after Calendar.

- **On.** A confirmation says "Upload N notes from this Mac (X MB of
  audio) to iCloud." Uploading runs in the background, and the status line
  shows progress (`Uploading · 12 of 80`). Other Macs' notes download at
  the same time.
- **Status.** Up to date with a time, uploading with progress, paused for
  no network, iCloud storage full, iCloud account changed, or "this build
  doesn't support iCloud sync".
- **Off.** Two choices:
  - **Turn Off Sync** keeps local notes and iCloud data.
  - **Turn Off and Delete from iCloud** deletes both zones. Every Mac
    stops syncing on its next fetch, and local notes stay.
  - If notes with audio not yet downloaded exist, the dialog gives their
    count.
- **Account change or sign out.** Sync pauses with a message. Nothing local
  is deleted. Sync resumes only when the user turns it on again, so notes
  never cross into a different account.

**Recently Deleted.** A trash button sits in the note list's title row, next
to search and import, and appears only when deleted notes exist, with their
count. It is not at the bottom, because the floating Record button lives
there. The button switches the list to Recently Deleted, with Done to go
back. The Record button is hidden in that mode. Each note shows its days
left. The opened note is read-only and has Restore and Delete Now. It works with sync off
too, kept on that Mac only.

## Build and signing

- Apple Developer setup (one time):
  - the container `iCloud.com.woosublee.quill`;
  - the iCloud capability on `com.woosublee.quill` and
    `com.woosublee.quill.dev`;
  - a Developer ID provisioning profile for each.

  The profiles are created with the App Store Connect API key when its role
  allows. Otherwise they are made in the portal.
- `Makefile`: when `PROVISIONING_PROFILE` points to a profile, embed it as
  `Contents/embedded.provisionprofile` and sign with an entitlements file
  that adds the iCloud container, the CloudKit service, the container
  environment, the application identifier, and the team identifier.
  Without a profile, sign with today's entitlements. A restricted
  entitlement without a profile stops the app from launching.
- Environment: Quill Dev uses CloudKit Development, and releases use
  Production. Test data never reaches real notes. The schema is promoted to
  Production before the release that ships sync.
- At runtime, sync is available when the entitlement is present, the OS is
  macOS 14 or later, and an account is signed in.
- `release.yml` decodes the profile from a new secret and passes it to
  `make`. The signing identity, Sparkle keys, and notarization stay the
  same. This is a high-risk workflow change and is reviewed in its own PR.

## Errors

| Situation | Behavior |
|---|---|
| Offline | Works locally. The engine resumes when the network returns. |
| Signed out or account changed | Pause, message, keep local data. |
| iCloud storage full | Pause uploads, show it in Settings, resume when space frees. |
| Note from a newer build | Unknown fields kept. Known fields merged. |
| Same field edited on two Macs | The later edit wins. |
| Corrupt or undecodable record | That record is skipped and reported by count. The rest continue. |
| Audio still uploading from another Mac | "Audio is still uploading from another Mac." |
| Audio requested offline | "Connect to the internet to download this audio." |
| Audio never uploaded (the source Mac turned sync off) | "This note's audio is only on another Mac." |
| Downloaded audio hash mismatch | Discard and retry once, then show an error. |

## Privacy and risk

- Sync is opt-in and off by default. Data goes only to the user's own
  iCloud private database. No new server, telemetry, or third party.
- Screenshots, window and app context, selected text, and prompts are
  never uploaded (see the list above).
- Logs give counts and states only, never note content, titles, or file
  names.
- README and in-app privacy copy are updated to say that notes stay on the
  Mac unless iCloud sync is on.
- High-risk areas to call out in the PRs: storage (Core Data migration,
  soft delete), data transmission (CloudKit), entitlements and provisioning
  (Makefile), and `release.yml`.
- Downgrade: an older build ignores the new Core Data attributes and still
  shows notes in Recently Deleted as normal notes. The Recently Deleted PR
  release notes say so.

## Testing

Automated (synthetic data, fake CloudKit):

- The record mapping round-trips synced fields and never emits a
  local-only field. A test lists the excluded keys.
- Unknown fields from a newer schema are kept.
- `NoteFieldClock` merges different fields from two Macs, the later edit
  on the same field wins, and ties resolve the same way on both sides.
- Existing notes get a clock from `timestamp`.
- Notes in progress are not enqueued. A note is enqueued once it settles.
- Soft delete, restore, Delete Now, and the 30-day purge, with an injected
  clock.
- The initial upload list includes every finished note, and the
  confirmation has the right counts and sizes.
- Audio is split into parts and rejoined, and a hash mismatch is rejected.
- An account change pauses sync without deleting anything.
- A fetched record is applied without being sent back (no echo).
- Builds without a profile carry the same entitlements as today, checked
  by a Makefile test.

Manual (Quill Dev, CloudKit Development, two Macs or two macOS users on the
same iCloud account):

- Turn sync on with existing notes on both, and the lists merge.
- Edit the title on one and the summary on the other while offline, then
  reconnect. Both edits survive.
- Delete, restore, and Delete Now across Macs.
- Play audio recorded on the other Mac, then retranscribe it.
- Sign out of iCloud, and sync pauses with notes intact.
- Turn off and delete from iCloud.

## Delivery

1. **Recently Deleted and field clock.** Core Data attributes, soft delete,
   the 30-day purge, the Recently Deleted view, and clock stamping. Useful
   without sync and can ship alone.
2. **Record mapping and merge.** `NoteSyncRecord` and `NoteFieldClock`
   with tests. No CloudKit calls.
3. **iCloud entitlements in the build.** Apple Developer setup, Makefile
   profile embedding, and runtime availability checks for Quill Dev.
4. **Note text sync.** `NoteSyncCoordinator`, the sync settings tab,
   on/off, initial upload, remote merge, and account handling.
5. **Audio sync.** `NoteAudioSync`, upload in parts, on-demand download,
   and the UI states.
6. **Release readiness.** Schema promotion to Production, the
   `release.yml` profile secret, and privacy copy.

Item 1 can ship on its own. Items 2–6 ship together in one minor release.

## Out of scope

- Syncing settings, vocabulary, prompts, or summary templates (next
  project).
- Freeing local audio that is already in iCloud.
- The iPhone client and purchase flow (private repository).
- Sharing notes with other iCloud users.
- Syncing in-progress recordings live.
