# Issue #181 설계: 녹음 Journal 저장 실패 시 안전 중단·즉시 복구

## 1. 배경

Issue #181의 Phase 1~4는 append-only PCM journal, 단일·System Audio·combined·input-switch 정상 finalization과 startup recovery를 구현했다. 현재 녹음 중 checkpoint가 실패하면 `AppState.reportRecordingJournalCheckpointFailure`가 “unexpected quit recovery를 사용할 수 없다”고 알린 뒤 물리 녹음을 계속한다. 이 동작에는 두 문제가 있다.

1. PCM append가 먼저 실패해도 오류는 다음 7초 checkpoint까지 사용자에게 전달되지 않을 수 있다.
2. journal이 더 이상 안전하게 저장되지 않는 상태에서 녹음을 계속하면 사용자는 뒤의 오디오도 보존된다고 오해할 수 있다.

이번 작업은 저장 공간 부족, 저장 권한 문제, 예상하지 못한 file write/sync/manifest persistence 실패를 녹음의 terminal storage failure로 처리한다. Quill은 새 오디오 수집을 즉시 멈추고 마지막으로 durably committed된 오디오를 공유 finalizer와 history 흐름으로 복구한다.

## 2. 목표

- PCM append, `fullSync`, manifest checkpoint persistence 실패를 가능한 한 빠르게 감지한다.
- 실제 storage failure가 발생하면 녹음을 한 번만 안전하게 종료한다.
- 마지막 정상 manifest boundary까지의 오디오를 보존한다.
- 즉시 finalization을 시도하고 성공하면 자동 전사 없이 Note Browser recovery item을 저장한다.
- finalization 또는 history 저장도 실패하면 inflight journal과 마지막 유효 manifest를 보존한다.
- 저장 실패 원인과 오디오 복구 mode를 독립적으로 지속 저장하고 영어·한국어로 안내한다.
- 기존 Playback, Retry Transcription, Delete 및 startup recovery를 재사용한다.
- 기존 upstream compatibility boundary를 유지한다.

## 3. 범위 제외

- 녹음 전 남은 디스크 공간 예측 또는 선제 차단
- 앱 실행 중 주기적 finalization 재시도
- 별도 recovery center 또는 storage management UI
- retention, storage cap, 자동 삭제 — Issue #193
- watchdog 시간 및 buffer-starvation 정책 변경
- Core Data 손상 복구
- recorder capture graph 또는 transcription provider 흐름 재작성
- 새로운 permission 또는 entitlement

## 4. Upstream compatibility boundary

이 작업은 Issue #181에서 처음부터 사용한 additive storage/recovery layer 원칙을 유지한다.

- `AudioRecorder`와 `SystemAudioRecorder`의 capture 구조와 public lifecycle API를 재작성하지 않는다.
- audio callback은 계속 복사된 normalized PCM을 narrow sink에 enqueue할 뿐, manifest·Core Data·sync 작업을 수행하지 않는다.
- `AppState`는 terminal failure orchestration과 기존 finalizer/history handoff만 담당한다.
- file error 분류, durable interruption metadata, status parsing은 작은 독립 타입에 둔다.
- `stopAndTranscribe()`를 범용 stop coordinator로 리팩터링하지 않는다.
- Note Browser에 새 화면이나 control을 추가하지 않는다.
- Core Data property를 추가하지 않는다.
- Standard API, Realtime, Native Whisper, Legacy mlx-whisper, Apple Live의 backend 선택과 provider routing을 변경하지 않는다.

충돌 가능성이 높은 `AppState.swift`, `PipelineHistoryItem.swift`, `NoteBrowserView.swift`는 작은 연결 함수 또는 computed property만 수정한다. 새 저장 실패 로직의 중심은 Quill 전용 journal/recovery 파일에 둔다.

## 5. 오류 모델

### 5.1 Durable interruption reason

오디오 복구 mode와 녹음 중단 원인은 서로 다른 정보다.

```swift
enum RecordingInterruptionReason: String, Codable, Equatable {
    case storageFull = "storage-full"
    case permissionDenied = "permission-denied"
    case journalIOFailure = "journal-io-failure"
}
```

- `RecoveredRecordingMode`는 실제 WAV에 남은 오디오 형태를 나타낸다.
- `RecordingInterruptionReason`은 왜 녹음이 강제 종료됐는지 나타낸다.

예:

```text
mode = partial
interruptionReason = storage-full
```

### 5.2 실제 storage failure 분류

`NSError`의 domain/code와 `NSUnderlyingErrorKey` chain을 순회한다.

- `NSPOSIXErrorDomain`
  - `ENOSPC`, `EDQUOT` → `.storageFull`
  - `EACCES`, `EPERM`, `EROFS` → `.permissionDenied`
- Cocoa file error
  - volume full → `.storageFull`
  - write no permission 또는 read-only volume → `.permissionDenied`
- 그 밖의 append/write/fullSync/manifest temporary-write/atomic-replace/directory-sync 실패 → `.journalIOFailure`

### 5.3 프로그래밍 계약 오류

다음은 storage failure로 표시하지 않는다.

- odd-byte PCM chunk
- conflicting frame offset
- checkpoint regression
- malformed manifest 또는 ID relation
- invalid lifecycle state
- unsafe filename

이들은 기존 invariant failure 경로로 보존하고 로그에 남긴다. “모든 journal 저장 오류에서 즉시 종료”는 실제 file persistence 실패에만 적용한다.

## 6. Writer와 controller failure signal

### 6.1 Writer

`RecordingPCMJournalWriter`는 기존 serial queue와 sticky failure를 유지하면서 optional terminal failure callback을 받는다.

- `FileHandle.write` 실패를 잡는 즉시 callback을 한 번 예약한다.
- checkpoint의 `fullSync` 또는 close failure도 같은 callback을 사용한다.
- callback은 writer queue에서 AppState를 직접 호출하지 않는다.
- callback에 전달하는 값은 raw localized string이 아니라 분류 가능한 structured failure다.
- failure 이후 추가 enqueue는 기존처럼 무시한다.

Writer가 manifest를 수정하거나 recorder를 중단하지는 않는다.

### 6.2 Segmented controller

`SegmentedRecordingJournalController`는 여러 writer와 timer에서 온 failure를 recording-scoped terminal event 하나로 합친다.

- callback은 recording ID, source kind/segment sequence가 포함된 diagnostic context와 분류된 interruption reason을 전달한다.
- 같은 recording에서 최초 persistence failure만 AppState에 전달한다.
- terminal failure를 기록하면 checkpoint timer를 취소한다.
- controller는 이후 일반 checkpoint와 segment switch를 거부한다.
- AppState의 종료 요청만 failure-preserving drain 경로를 실행할 수 있다.

### 6.3 Failure-preserving close

정상 `stopAndClose()`는 모든 active writer의 최신 snapshot을 durable manifest에 기록해야 성공한다. Storage failure 뒤에는 이 계약을 그대로 사용할 수 없다. 따라서 controller에 별도 terminal close operation을 둔다.

개념적 결과:

```swift
struct RecordingJournalFailureCloseResult {
    let recordingID: UUID
    let interruptionReason: RecordingInterruptionReason
    let closeErrors: [RecordingJournalSourceCloseError]
}
```

동작:

1. 모든 active writer에 best-effort `drainAndCloseSnapshot()`을 시도한다.
2. 한 source 실패 후에도 다른 source를 계속 닫는다.
3. 정상 source snapshot은 manifest checkpoint를 한 번 시도한다.
4. 실패 source의 committed boundary는 전진시키지 않는다.
5. reason과 `.recoverable` 전환을 한 atomic manifest generation에 기록한다.
6. manifest write도 실패하면 이전 valid generation을 보존하고 오류를 반환한다.
7. controller state는 terminal/recoverable로 바뀌며 정상 stop/switch 재진입을 허용하지 않는다.

Disk가 manifest write를 허용하지 않으면 interruption reason을 durable하게 남긴다고 보장할 수 없다. 이때도 이전 manifest와 committed audio는 삭제하지 않으며 다음 launch에서 generic interrupted recording으로 복구할 수 있다.

## 7. AppState terminal stop orchestration

`reportRecordingJournalCheckpointFailure`의 “경고 후 계속” 동작은 recording-scoped one-shot terminal stop으로 바뀐다. PCM append 즉시 callback도 같은 진입점을 사용한다.

```text
1. recording ID/token으로 중복 callback 차단
2. journal sinks 즉시 detach
3. input-switch token 무효화
4. 즉시 actionable overlay 표시
5. physical recorder stop
6. child recorder temporary WAV를 best-effort 삭제해 공간 확보
7. controller failure-preserving close
8. manifest recoverable/reason 기록 시도
9. shared SegmentedRecordingArtifactFinalizer로 즉시 finalization
10. success → RecordingRecoveryHistory persist
11. failure → inflight 보존과 재실행 안내
```

### 7.1 기존 recording session 정리

Terminal stop은 `stopAndTranscribe()`를 호출하지 않는다.

- shortcut session과 recording trigger를 reset한다.
- `isRecording`을 false로 전환한다.
- audio level subscription과 initialization timer를 취소한다.
- realtime service와 Apple Live session을 종료하되 raw transcript finalization/provider fallback을 실행하지 않는다.
- context task를 정리한다.
- live note가 있으면 같은 stable recording ID recovery item으로 교체한다. 먼저 삭제해 ID를 잃거나 duplicate row를 만들지 않는다.
- physical recorder stop completion 전 controller/finalizer를 시작하지 않는다.

### 7.2 정상 사용자 stop과 경쟁

- 사용자가 먼저 정상 stop을 시작했다면 late storage callback은 무시한다.
- storage failure가 먼저 terminal token을 차지하면 이후 shortcut release/stop 요청은 중복 physical stop과 transcription을 시작하지 않는다.
- input switch 진행 중 failure가 발생하면 generation token을 무효화하고 새 input start completion을 무시한다.

## 8. 즉시 finalization과 보존

### 8.1 Finalization 성공

- `SegmentedRecordingArtifactFinalizer`는 manifest의 마지막 committed boundary만 사용한다.
- physical source file의 uncommitted tail은 기존 source finalizer가 잘라낸다.
- usable segment/source를 기존 순서와 alignment 규칙으로 assemble한다.
- promotion에 recovery mode, issues, interruption reason을 기록한다.
- 자동 transcription 또는 provider upload를 시작하지 않는다.
- `RecordingRecoveryHistory`로 stable-ID placeholder를 durable하게 저장한다.
- `.historyStored → .finalized` 후 inflight 디렉터리를 제거한다.

### 8.2 Finalization 또는 history 저장 실패

- 기존 permanent WAV를 덮어쓰지 않는다.
- inflight journal과 마지막 valid manifest를 삭제하지 않는다.
- `.assembled.wav.tmp`와 child temporary WAV만 best-effort 삭제한다.
- 앱 실행 중 timer/polling 재시도를 하지 않는다.
- 사용자에게 공간 또는 접근 문제를 해결한 뒤 Quill을 다시 실행하라고 안내한다.
- 다음 startup recovery가 한 번 다시 시도한다.
- startup recovery가 다시 실패하면 기존 executor 계약대로 inflight를 보존한다.

## 9. Durable metadata

### 9.1 Manifest와 promotion

기존 schema version 1을 유지하고 optional field를 추가한다.

```swift
RecordingJournalManifest.interruptionReason:
    RecordingInterruptionReason?

RecordingPromotion.interruptionReason:
    RecordingInterruptionReason?
```

- 기존 manifest는 nil로 decode된다.
- storage failure close에서 manifest reason 기록을 시도한다.
- finalizer는 manifest reason을 promotion으로 복사한다.
- 이미 promoted된 artifact는 source를 다시 읽지 않고 stored promotion reason을 사용한다.
- credential exclusion은 유지한다.

### 9.2 History status

Core Data schema를 바꾸지 않고 `postProcessingStatus`에 recovery mode와 interruption reason을 안정적으로 encode한다.

예:

```text
recording-recovered:storage-full
recording-recovered:storage-full:partial
recording-recovered:permission-denied
recording-recovered:journal-io-failure:system-audio-only
```

Placeholder도 같은 context를 유지하는 `transcription-interrupted:...` 형태를 사용한다. 문자열 조립과 parsing은 UI에 흩어놓지 않고 다음 순수 타입 한 곳에서 담당한다.

```swift
struct RecoveredRecordingContext: Equatable {
    let mode: RecoveredRecordingMode
    let interruptionReason: RecordingInterruptionReason?
}
```

`PipelineHistoryItem`은 다음을 여기서 파생한다.

- `recoveredRecordingContext`
- `recoveredRecordingMode`
- `recordingInterruptionReason`
- `isRecoveredRecording`

기존 status는 모두 `.complete + nil reason` 또는 기존 mode로 호환된다. Retry Transcription 성공 후 기존 완료 status로 교체되므로 interruption reason UI도 사라진다.

## 10. 사용자 안내와 Note Browser

### 10.1 즉시 overlay

English:

- storage full: `Recording stopped because storage is full. Free up space, then review the recovered audio.`
- permission denied/read-only: `Recording stopped because audio could not be saved. Check storage access, then review the recovered audio.`
- other journal I/O: `Recording stopped because of an audio save error. Audio saved before the error is being recovered.`
- immediate recovery also failed: `Free up space or restore storage access, then relaunch Quill to recover the audio.`

Korean:

- storage full: `저장 공간이 부족해 녹음을 중단했습니다. 공간을 확보한 뒤 복구된 오디오를 확인해 주세요.`
- permission denied/read-only: `오디오를 저장할 수 없어 녹음을 중단했습니다. 저장소 접근 권한을 확인한 뒤 복구된 오디오를 확인해 주세요.`
- other journal I/O: `오디오 저장 오류로 녹음을 중단했습니다. 오류 전에 저장된 오디오를 복구하고 있습니다.`
- immediate recovery also failed: `공간을 확보하거나 저장소 접근 문제를 해결한 뒤 Quill을 다시 실행해 오디오를 복구해 주세요.`

Raw filesystem error는 overlay 본문에 그대로 노출하지 않고 debug log/error detail에만 남긴다.

### 10.2 Recovery item title

중단 원인이 있으면 mode title보다 원인 title을 우선한다.

| Reason | English | Korean |
| --- | --- | --- |
| storageFull | Recording stopped: storage full | 저장 공간 부족으로 녹음 중단됨 |
| permissionDenied | Recording stopped: storage unavailable | 저장소 접근 문제로 녹음 중단됨 |
| journalIOFailure | Recording stopped: save error | 오디오 저장 오류로 녹음 중단됨 |

### 10.3 Recovery description

상세 화면과 row preview는 두 문장을 조합한다.

1. 원인 문장
2. mode별 복구 결과 문장

예:

```text
저장 공간이 부족해 Quill이 녹음을 중단했습니다.
일부가 누락되었을 수 있습니다. 복구된 오디오는 재생하거나 전사할 수 있습니다.
```

기존 `.complete`, `.partial`, `.microphoneOnly`, `.systemAudioOnly`의 source-specific 의미를 유지한다. Playback, Retry Transcription, Delete control은 변경하지 않는다.

## 11. TDD 검증 전략

### 11.1 오류 분류

- POSIX `ENOSPC`, `EDQUOT` → `.storageFull`
- `EACCES`, `EPERM`, `EROFS`와 대응 Cocoa errors → `.permissionDenied`
- generic write/sync/replace error → `.journalIOFailure`
- nested underlying error 분류
- odd-byte/conflicting offset/checkpoint regression은 storage reason으로 분류되지 않음

### 11.2 Writer/controller

- injected PCM append `ENOSPC`가 다음 checkpoint 전 terminal callback 발생
- callback은 한 writer에서 한 번만 발생
- `fullSync` 실패도 terminal callback 발생
- 여러 source 동시 failure도 recording-scoped callback 한 번
- failure source committed boundary는 전진하지 않음
- 정상 companion source는 best-effort close와 checkpoint 시도
- terminal close 후 checkpoint/switch 거부
- reason+recoverable manifest write 실패 시 이전 manifest bytes/generation 유지

### 11.3 Manifest/finalizer/history

- schema-v1 legacy manifest nil reason decode
- manifest/promotion reason round-trip
- promoted 재진입에서 stored reason 재사용
- 조합:
  - storageFull + complete
  - storageFull + partial
  - permissionDenied + microphoneOnly
  - journalIOFailure + systemAudioOnly
- 조합별 recording-ID WAV 하나, history row 하나, exact status
- repeated launch idempotency
- Retry 성공 후 recovered status/reason 제거
- promotion/history failure에서 inflight 보존

### 11.4 AppState contract/integration

- storage failure path는 `stopAndTranscribe`, `TranscriptionService`, provider/upload를 호출하지 않음
- physical recorder stop 한 번
- sinks 즉시 detach
- input-switch token 무효화
- realtime/Apple Live 취소
- live note와 recovery history가 같은 stable ID로 수렴
- finalization 성공 시 recovery history handoff
- 실패 시 actionable overlay와 inflight 보존

### 11.5 UI/localization

- overlay 4종 영어·한국어
- reason title 3종 영어·한국어
- reason + mode description 조합
- legacy unexpected-shutdown recovery copy 회귀 없음
- Playback, Retry, Delete 재사용 source contract

### 11.6 Full verification

- `make check-test-wiring`
- `make test`
- Quill Dev build with explicit `CODESIGN_IDENTITY=Quill`
- `xattr -cr build/`
- `codesign --verify --deep --strict`
- `git diff --check`

실제 시스템 디스크를 가득 채우지 않는다. Production user data나 `/Applications/Quill.app`을 건드리지 않는다. 자동 테스트는 injected POSIX/Cocoa errors와 temporary directories를 사용한다. 안전한 isolated volume을 준비할 수 있을 때만 Quill Dev smoke test를 추가한다.

## 12. 완료 기준

- PCM append storage failure가 checkpoint cadence를 기다리지 않고 terminal stop을 시작한다.
- 모든 실제 journal persistence failure에서 녹음이 한 번만 종료된다.
- 마지막 durable committed boundary 이전 오디오는 삭제되지 않는다.
- 실패 source 때문에 정상 companion source close가 생략되지 않는다.
- 즉시 finalization 성공 시 자동 전사 없이 stable recovery item이 생성된다.
- 즉시 finalization/history 실패 시 inflight와 마지막 valid manifest가 보존된다.
- storage reason과 recovery mode가 promotion/history/relaunch를 거쳐 유지된다.
- 원인별 영어·한국어 overlay와 Note Browser copy가 정확하다.
- 기존 shutdown recovery, normal stop, input switching, backend routing이 회귀하지 않는다.
- 기존 upstream compatibility boundary를 유지하며 recorder, transcription, Core Data 구조를 재작성하지 않는다.
