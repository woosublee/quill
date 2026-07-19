# Issue #181 Phase 4 설계: 입력 전환 Segment 영속화·복구

**작성일:** 2026-07-19  
**상태:** 사용자 설계 승인 완료, 구현 계획 작성 전  
**대상 브랜치:** `issue-181-input-switch-recovery`

## 1. 목적

녹음 중 오디오 입력을 바꿀 때 생성되는 모든 구간을 하나의 durable recording으로 관리한다. 정상 종료와 앱 재시작 복구는 같은 ordered segment model과 bounded-memory finalizer를 사용하며, 최종적으로 recording ID 기반 WAV 한 개와 history 한 건으로 수렴한다.

현재 구현은 입력 전환 전에 끝난 WAV URL을 `AppState.recordingSegmentURLs` 메모리에만 보관하고 해당 durable journal을 삭제한다. 프로세스가 종료되면 구간의 소유 recording과 순서를 잃으므로 이전 구간을 복구할 수 없거나 임시 파일이 남을 수 있다. Phase 4는 이 memory-only ordering source를 durable manifest로 대체한다.

## 2. 사용자 동작 결정

- 여러 구간 중 일부만 손상되면 사용 가능한 구간을 원래 순서대로 복구한다.
- 손상 구간의 길이만큼 무음이나 표시음을 넣지 않는다. 살아 있는 앞뒤 구간을 바로 연결한다.
- 일부 손상 결과는 자동 전사하지 않는다. Playback으로 확인한 뒤 사용자가 `Retry Transcription`을 선택한다.
- 화면에는 기술적인 누락 목록 대신 `일부 오디오 복구됨`과 `녹음 일부가 누락될 수 있습니다`를 표시한다.
- 이전 입력을 멈춘 뒤 새 입력 시작에 실패하면 전환 전까지 온전하게 기록된 오디오는 정상 결과로 저장한다. 장치 전환 실패 자체만으로 부분 복구로 분류하지 않는다.

## 3. 범위

### 포함

- stable recording ID 아래 ordered segment와 source를 durable manifest에 append
- microphone, System Audio, `System Default + System Audio` segment의 혼합
- 정상 종료와 startup recovery가 공유하는 segmented finalizer
- fixed-size streaming mix와 concatenation
- 일부 segment/source 손상 시 partial recovery
- promotion, history 저장, finalization crash window의 idempotent 수렴
- 성공한 recording의 inflight directory 전체 정리
- 영어·한국어 partial recovery 안내 문구
- 기존 Playback, Retry Transcription, Delete control 재사용

### 제외

- 오래된 manual recovery 자동 삭제, retention, 전체 storage cap, storage management UI — Issue #193
- partial 결과의 자동 전사
- 손상 구간 길이만큼 무음 또는 표시음 삽입
- 누락 segment/source의 기술적인 상세 UI
- 손상된 source의 자동 삭제
- transcription backend 또는 model selection 변경
- Core Data schema migration
- 여러 recording을 하나로 합치는 기능
- Issue #208의 기존 Core Data 및 AVFoundation 경고 수정

## 4. 핵심 구조

### 4.1 하나의 recording manifest

모든 구간은 하나의 recording ID와 pipeline snapshot을 공유한다.

```text
audio/inflight/<recording-id>/
├── manifest.json
├── segment-0000-microphone.wav.part
├── segment-0001-microphone.wav.part
├── segment-0001-system-audio.wav.part
├── segment-0002-system-audio.wav.part
└── .assembled.wav.tmp
```

예시 관계:

```text
recording
├── recording ID
├── startedAt / monotonic anchor
├── pipeline snapshot
└── segments
    ├── sequence 0 → microphone source
    ├── sequence 1 → microphone + System Audio sources
    └── sequence 2 → System Audio source
```

`RecordingJournalSegment.sequence`가 최종 오디오 순서의 유일한 기준이다. AppState의 URL 배열, recorder completion 순서, 파일명 열거 순서는 ordering source로 사용하지 않는다.

### 4.2 명시적인 segmented mode

`RecordingAudioSourceMode`에 새 case를 추가한다.

```swift
enum RecordingAudioSourceMode: String, Codable, Equatable {
    case microphone
    case systemAudio
    case combined
    case segmented
}
```

새 AppState 녹음은 첫 입력 종류나 실제 전환 여부와 관계없이 `.segmented` manifest를 사용한다. 이 표시 덕분에 segment가 하나뿐인 상태에서 앱이 종료돼도 scanner가 shared segmented finalizer를 선택할 수 있다.

기존 `.microphone`, `.systemAudio`, `.combined` manifest는 기존 scanner/controller/finalizer 경로로 계속 지원한다. Optional field와 enum case 추가만으로 기존 schema-v1 JSON을 계속 decode할 수 있으므로 schema version은 `1`을 유지한다.

### 4.3 Manifest 불변조건

`.segmented` manifest는 다음을 만족해야 한다.

- `segments`와 `sources`는 비어 있지 않다.
- segment ID, source ID, source filename, sequence는 각각 recording 안에서 유일하다.
- sequence는 `0..<segments.count`의 연속된 값이다.
- 각 segment에는 source가 한 개 또는 두 개 있다.
- 한 segment에는 microphone과 System Audio source가 각각 최대 한 개 있다.
- 모든 source는 정확히 한 segment에 속한다.
- `segment.sourceIDs`와 각 source의 `segmentID` 관계가 양방향으로 일치한다.
- segment가 참조하지 않는 source 또는 존재하지 않는 source를 참조하는 segment를 허용하지 않는다.
- source file은 recording directory 안의 안전한 상대 파일명만 사용한다.
- pipeline snapshot, startedAt, monotonic anchor는 segment append 중 변경되지 않는다.
- promotion 이후 segment/source append를 허용하지 않는다.

`RecordingJournalManifest.segments`는 append를 위해 `var`로 바뀌지만 store의 atomic mutation API 외부에서 수정하지 않는다.

## 5. Store API와 atomic append

### 5.1 요청과 결과

Store에는 segmented recording 생성과 후속 segment append를 위한 전용 API를 추가한다. 각 source 요청은 ID와 kind만 받고, 파일명은 store가 sequence와 kind에서 결정한다.

개념적 형태:

```swift
struct RecordingJournalSegmentSourceRequest: Equatable {
    let id: UUID
    let kind: RecordingJournalSourceKind
}

struct SegmentedRecordingJournalCreateRequest: Equatable {
    let recordingID: UUID
    let segmentID: UUID
    let startedAt: Date
    let monotonicAnchorNanoseconds: UInt64
    let sources: [RecordingJournalSegmentSourceRequest]
    let pipeline: RecordingPipelineSnapshot
}

func createSegmented(
    _ request: SegmentedRecordingJournalCreateRequest
) throws -> RecordingJournalSegmentSession

func appendSegment(
    recordingID: UUID,
    segmentID: UUID,
    sequence: Int,
    sources: [RecordingJournalSegmentSourceRequest]
) throws -> RecordingJournalSegmentSession
```

`RecordingJournalSegmentSession`은 segment ID, sequence, recording directory, manifest URL, source별 `RecordingJournalSession`을 반환한다.

### 5.2 Durable 갱신 순서

새 segment 준비는 다음 순서로 실행한다.

```text
source file을 O_EXCL로 생성하고 reserved WAV header 기록
→ 각 source file fullSync
→ recording directory sync
→ generation이 증가한 manifest를 temp file에 기록하고 fullSync
→ manifest.json으로 atomic rename
→ recording directory sync
→ 새 sink를 recorder에 연결
```

Manifest append가 성공하기 전에는 recorder에 새 sink를 제공하지 않으므로 manifest가 모르는 source에 사용자 audio frame이 기록되지 않는다.

### 5.3 Crash와 재시도

- source 생성 전 crash: manifest와 directory에 변화가 없다.
- source 생성 후 manifest rename 전 crash: 비어 있는 unreferenced source file이 같은 inflight directory에 남을 수 있다. Scanner와 finalizer는 manifest가 참조하는 source만 사용한다. recording 성공 시 directory 전체 삭제로 함께 정리된다.
- manifest rename 후 응답 전 crash: 다음 실행은 manifest에 기록된 segment를 복구한다.
- 같은 recording ID, segment ID, sequence, source ID/kind 요청을 다시 받으면 exact match를 재사용한다.
- manifest에 없지만 예상 파일명이 이미 존재하면 reserved header만 있는 빈 파일일 때만 재사용한다. payload가 있거나 형식이 다르면 충돌로 처리하고 recording을 보존한다.
- 다른 ID, sequence, source shape의 append 재시도는 `conflictingExistingRecording` 계열 오류로 거부한다.

## 6. Controller 책임

새 `SegmentedRecordingJournalController`가 녹음 전체를 소유한다.

### 6.1 소유 상태

- stable recording ID
- recording store
- 현재 segment ID와 sequence
- 현재 source별 writer와 timestamp-aware normalized sink
- 7초 checkpoint timer
- lifecycle state: recording, stopping, recoverable, promoted, discarded

### 6.2 첫 segment

```text
recording ID와 pipeline snapshot 생성
→ createSegmented로 segment 0 준비
→ source별 writer/sink 생성
→ sink를 recorder에 연결
→ recorder 시작
→ checkpoint timer 시작
```

첫 source frame offset은 기존 `RecordingFrameOffset`을 사용해 recording 전체 monotonic anchor 기준으로 저장한다.

### 6.3 입력 전환

```text
중복 전환 요청 차단
→ 현재 recorder stop 요청
→ 기존 sink를 drain 완료 시점까지 유지
→ 현재 writer들을 drainAndCloseSnapshot
→ source checkpoints를 manifest에 기록
→ appendSegment로 다음 sequence 준비
→ 새 sink를 recorder에 연결
→ 새 입력 recorder 시작
```

현재 segment를 닫는 동안 recording manifest state는 `.recording`을 유지한다. `.stopping`은 사용자가 recording 전체를 끝낼 때만 사용한다.

기존 `recordingSegmentURLs`와 `didSwitchInputDuringRecording`은 durable ordering에 사용하지 않고 제거한다. Recorder가 자체 생성하는 temporary WAV URL은 journal finalization의 입력이 아니며, recorder cleanup을 위한 transport artifact로만 취급한다.

### 6.4 새 입력 시작 실패

- 다음 segment에서 어떤 source도 frame을 commit하지 않았다면 내용 없는 준비 segment로 취급한다.
- 전환 전까지 기록된 segment를 finalization한다.
- 기존 segment에 integrity issue가 없으면 정상 recording으로 처리하고 기존 transcription/post-processing 흐름을 계속한다.
- 빈 준비 segment 자체는 partial recovery issue를 만들지 않는다.

### 6.5 전체 stop, preserve, discard

- 정상 stop: 현재 recorder와 writer를 drain한 뒤 manifest를 `.stopping`으로 전환하고 shared finalizer를 실행한다.
- 앱 termination 또는 recorder lifecycle 실패: 가능한 writer를 drain/checkpoint하고 `.recoverable`로 전환한다.
- 사용자 cancel: discard marker와 tombstone rename을 사용해 recording directory 전체를 삭제한다.
- segment 단위 discard는 제공하지 않는다. recording이 소유권과 정리의 최소 단위다.

## 7. Shared segmented finalizer

### 7.1 구성요소

1. `RecordingArtifactFinalizer.finalizeSource`
   - 기존 committed boundary repair를 재사용한다.
   - physical trailing bytes를 제거하고 canonical WAV header를 기록한다.

2. `StreamingPCM16SegmentRenderer`
   - `AudioMixdownService`의 기존 4,096-frame reader, alignment, RMS/gain, clamping 규칙을 공통 구현으로 추출한다.
   - 한 source는 그대로 stream하고, 두 source는 segment 내부 상대 offset을 유지해 mix한다.
   - segment 전체 `Data(contentsOf:)`를 사용하지 않는다.

3. `CanonicalWAVAssemblyWriter`
   - placeholder header를 쓰고 PCM chunk를 순차 append한다.
   - 누적 byte/frame count와 RIFF UInt32 한계를 검사한다.
   - 끝에서 header를 patch하고 file을 fullSync한다.

4. `SegmentedRecordingArtifactFinalizer`
   - manifest validation, segment 분류, ordered rendering, promotion metadata 생성을 조정한다.
   - staging file을 `audio/inflight/<recording-id>/.assembled.wav.tmp`에 둔다.

### 7.2 Segment 처리

Segment는 sequence 오름차순으로 처리한다.

- source 한 개가 usable: 해당 source를 leading silence 없이 stream한다.
- microphone와 System Audio가 모두 usable: 두 source의 `firstCommittedFrameOffset`에서 segment 내 earliest offset을 빼고 기존 gain/alignment 규칙으로 mix한다.
- 두 source 중 하나만 usable: 살아 있는 source를 leading silence 없이 stream하고 partial issue를 기록한다.
- single-source segment가 0 committed frame: 내용 없는 segment로 제외한다.
- two-source segment가 모두 0 committed frame: 내용 없는 준비 segment로 제외한다.
- two-source segment에서 한 source만 0 committed frame이고 다른 source에 audio가 있으면 partial issue를 기록한다.
- committed frame이 있는 source의 file이 missing, header보다 짧음, committed payload보다 물리 파일이 짧음이면 해당 source 또는 segment를 제외하고 partial issue를 기록한다.
- 사용할 source가 없는 segment는 건너뛰고 partial issue를 기록한다.

Segment 사이는 pause 길이를 재구성하지 않고 바로 이어 붙인다. 따라서 손상 구간과 입력 전환 준비 시간은 최종 WAV에서 제거된다. Segment 내부에서 두 source가 실제로 시작한 상대 차이만 보존한다.

### 7.3 오류 분류

자동 partial recovery로 건너뛰는 오류는 source integrity를 명확히 판정할 수 있는 경우로 제한한다.

- source file missing
- source file shorter than reserved header
- committed payload unavailable
- expected source에 committed audio가 없음

다음은 전체 finalization을 실패시키고 inflight source를 보존한다.

- manifest 구조 또는 ID 관계 불일치
- unsafe filename
- checkpoint regression
- read/write/fullSync/rename 같은 예상하지 못한 I/O 오류
- output RIFF 크기 한계 초과
- invalid existing permanent WAV
- existing permanent WAV와 promotion metadata 충돌

사용 가능한 audio frame이 recording 전체에 하나도 없으면 permanent WAV나 history를 만들지 않고 manual recovery 대상으로 남긴다.

### 7.4 Bounded memory

모든 scan, mix, copy, concatenate는 최대 4,096 frame chunk를 사용한다. 메모리 사용량은 recording 길이 또는 segment 수에 비례하지 않는다. Segment별 intermediate WAV는 만들지 않고 최종 staging writer에 바로 append한다.

현재 `AudioMixdownService.concatenate`의 `pcmDataChunk(from:)`와 `Data(contentsOf:)` 경로는 제거하거나 새 streaming writer를 사용하도록 바꾼다.

## 8. Promotion과 crash window

```text
manifest source validation
→ .assembled.wav.tmp를 처음부터 재작성
→ header patch
→ staging file fullSync
→ recording directory sync
→ recording ID WAV로 renamex_np(..., RENAME_EXCL)
→ audio directory sync
→ manifest를 .promoted로 atomic transition
```

- staging file은 Quill이 생성한 내부 artifact이므로 재시도 시 삭제하고 처음부터 다시 쓴다.
- source journal은 promotion 성공과 history 저장 완료 전까지 삭제하거나 변경하지 않는다. `finalizeSource`의 committed boundary repair만 허용한다.
- permanent rename 후 manifest transition 전 crash가 나면 다음 실행이 permanent WAV를 검증한다.
- physical filename, byte count, frame count가 manifest source에서 계산한 예상 결과와 맞으면 같은 permanent WAV를 재사용한다.
- invalid 또는 metadata가 다른 permanent WAV는 덮어쓰지 않는다.
- repeated launch는 같은 recording ID WAV inode와 history ID로 수렴한다.

## 9. Partial recovery metadata와 history

### 9.1 Durable metadata

`RecoveredRecordingMode`에 `.partial`을 추가한다.

```swift
enum RecoveredRecordingMode: String, Codable, Equatable, CaseIterable {
    case complete
    case microphoneOnly = "microphone-only"
    case systemAudioOnly = "system-audio-only"
    case partial
}
```

`RecordingPromotion`에는 optional issue 목록을 추가한다. 기존 manifest에는 값이 없으므로 빈 목록으로 해석한다.

개념적 형태:

```swift
struct RecordingRecoveryIssue: Codable, Equatable {
    let segmentSequence: Int
    let sourceKind: RecordingJournalSourceKind?
    let reason: RecordingRecoveryIssueReason
}

enum RecordingRecoveryIssueReason: String, Codable, Equatable {
    case noCommittedAudio
    case sourceMissing
    case sourceTooShort
    case committedPayloadUnavailable
}
```

- complete segmented 결과: `recoveryMode == .complete`, issue 없음
- partial segmented 결과: `recoveryMode == .partial`, issue 한 개 이상
- 기존 single/combined manifest와 promotion의 optional mode 호환은 유지한다.
- WAV 자체에는 recovery mode가 없으므로 이미 promoted된 artifact는 manifest에 저장된 mode/issues를 사용한다.

### 9.2 정상 종료 handoff

- complete: 기존 transcription pipeline에 recording ID WAV를 전달한다.
- partial: `RecordingRecoveryHistory`의 stable-ID placeholder 저장 흐름을 재사용하고 자동 transcription을 시작하지 않는다.
- partial placeholder는 startup recovery 결과와 동일하게 `.historyStored → .finalized → inflight directory removal`로 수렴한다.

### 9.3 Startup recovery handoff

기존 startup barrier를 유지한다.

```text
recoverRecordingJournalsBeforeHistoryLoad
→ history load
→ orphan sweep
```

상태별 동작:

| 상태 | 동작 |
| --- | --- |
| `.recording` | durable checkpoint까지만 사용하고 `.recoverable`로 전환 |
| `.stopping`, `.recoverable` | segmented finalization 실행 |
| `.promoted` | stable recording ID history 저장 |
| `.historyStored` | `.finalized` 전환 |
| `.finalized` | inflight directory 정리 |

Startup recovery는 transcription, post-processing, provider request, upload를 자동으로 시작하지 않는다.

## 10. Note Browser 표시

Partial recovery는 기존 control을 그대로 사용한다.

- Playback
- Retry Transcription
- Delete

새 localization key:

```text
Some audio recovered
Some parts of this recording may be missing. The recovered audio is available for playback or transcription.
```

한국어:

```text
일부 오디오 복구됨
이 녹음의 일부가 누락되었을 수 있습니다. 복구된 오디오는 재생하거나 전사할 수 있습니다.
```

내부 `RecordingRecoveryIssue` 목록은 UI에 직접 노출하지 않는다. 기존 complete, microphone-only, System Audio-only 문구는 유지한다.

## 11. 정리 정책

- complete 정상 결과: 기존 transcription/history lifecycle이 완료되면 inflight directory 전체 삭제
- partial 결과: recovery placeholder가 durable하게 저장되고 `.finalized`로 전환된 뒤 inflight directory 전체 삭제
- promoted/historyStored/finalized crash window: 다음 launch가 lifecycle을 이어서 완료하고 directory 삭제
- 사용 가능한 audio 없음: manifest와 모든 source file 보존
- 예상하지 못한 I/O 또는 manifest 오류: manifest와 모든 source file 보존
- invalid permanent artifact conflict: permanent file과 inflight source를 모두 보존
- 사용자 cancel: discard marker와 tombstone을 사용해 inflight directory 전체 삭제
- unreferenced empty source와 stale staging은 성공 시 directory 전체 삭제에 포함

Orphan sweep는 계속 `audio/inflight`를 건드리지 않는다. Inflight 사용자 audio의 expiry와 storage cap은 Issue #193에서 별도로 설계한다.

## 12. 보안과 개인정보

- Manifest에는 API key, OAuth token, credential, 인증 header를 저장하지 않는다.
- Provider URL처럼 credential을 포함할 수 있는 문자열도 저장하지 않는다.
- Pipeline snapshot은 기존 allowlist field만 유지한다.
- 모든 source와 staging 경로는 recording directory 아래의 검증된 상대 파일명에서만 만든다.
- Recording directory와 source file 권한은 기존 `0700` / `0600`을 유지한다.
- Manifest write, source creation, promotion은 symlink나 외부 경로를 따라가지 않는 기존 안전 경계를 유지한다.

## 13. 자동화 테스트

### 13.1 Manifest와 store

- 기존 schema-v1 single/combined manifest decode
- `.segmented` ordered segment/source validation
- 중복 또는 비연속 sequence 거부
- 중복 source ID/filename 거부
- 잘못된 segment-source 상호 참조 거부
- source file 생성 후 manifest rename 전 crash fixture
- manifest rename 후 응답 전 재시도 idempotency
- conflicting append 거부와 기존 source 보존
- credential-field exclusion 유지

### 13.2 Controller

- microphone → combined → System Audio가 같은 recording ID를 사용
- sequence가 `0, 1, 2`로 증가
- 이전 writer drain/checkpoint가 다음 recorder 시작보다 먼저 완료
- 입력 전환에서 이전 journal을 discard하지 않음
- checkpoint가 모든 active source를 기록
- 새 input 시작 실패 시 빈 준비 segment를 제외하고 이전 segment finalization
- preserve가 current segment를 drain하고 `.recoverable`로 전환
- cancel이 recording directory 전체를 제거

### 13.3 Streaming finalizer

- single-source segment 순서 유지
- combined segment 내부 source offset과 gain 규칙 유지
- mixed source shape를 순서대로 한 WAV에 append
- segment 사이 무음 미삽입
- 최대 4,096-frame chunk 처리
- 긴 fixture에서도 source 전체 `Data(contentsOf:)` 미사용
- RIFF 크기 overflow에서 source 보존

### 13.4 Partial recovery

- combined segment의 한 source만 missing/empty/truncated
- 중간 segment 전체 손상
- 여러 손상 뒤에도 살아 있는 segment 순서 유지
- all-zero 준비 segment는 issue 없이 제외
- committed audio가 있는 single-source segment 손상은 issue로 기록
- known integrity failure만 건너뜀
- 예상하지 못한 I/O 오류는 전체 실패
- usable audio가 없으면 manual recovery
- issue 목록의 segment sequence/source kind/reason round-trip

### 13.5 Lifecycle 통합

- assembly 중 crash
- permanent rename 후 manifest transition 전 crash
- `.promoted`, `.historyStored`, `.finalized` 각 crash window
- repeated launch 후 permanent WAV 한 개와 history 한 건
- complete normal stop은 기존 transcription 흐름 계속
- partial normal stop과 startup recovery는 자동 전사를 시작하지 않음
- 성공 후 inflight directory 없음
- manual/failed recovery 후 inflight source 유지
- Delete가 history row와 permanent WAV를 제거

### 13.6 AppState와 UI source contract

- `recordingSegmentURLs`, `didSwitchInputDuringRecording`, 이전 journal discard 경로 제거
- AppState가 새 segmented controller/finalizer를 사용
- startup recovery가 history load와 orphan sweep보다 먼저 실행
- startup recovery body에 transcription/provider/upload 호출 없음
- partial title/description 영어·한국어 확인
- 기존 Playback, Retry Transcription, Delete control 유지

## 14. 수동 검증

`build/Quill Dev.app`과 Bundle ID `com.woosublee.quill.dev`만 사용한다. `/Applications/Quill.app`은 건드리지 않는다.

1. microphone → combined → System Audio로 여러 번 전환 후 정상 stop
2. 결과 WAV에서 segment 순서 확인
3. combined segment에서 microphone과 System Audio의 상대 정렬 확인
4. complete 결과가 기존 transcription 흐름으로 이어지는지 확인
5. 입력 전환 후 checkpoint를 지난 시점에 정확한 Quill Dev PID에 `SIGKILL`
6. 재실행 후 recovered history 한 건과 WAV 한 개 확인
7. 다시 실행해도 중복 history/file이 생기지 않는지 확인
8. Playback, Retry Transcription, Delete 확인
9. 성공한 recording의 Quill Dev Application Support `audio/inflight/<recording-id>`가 제거됐는지 확인

사용자 audio를 고의로 손상시키는 수동 검증은 하지 않는다. Partial 손상 시나리오는 temporary test fixture로 검증한다.

## 15. 완료 기준

- 입력 전환 전후의 모든 durably committed audio가 하나의 manifest에 ordered segment로 기록된다.
- recording 전체에서 stable recording ID와 pipeline snapshot을 유지한다.
- 정상 stop과 startup recovery가 같은 segmented finalizer를 사용한다.
- 최종 assembly는 bounded-memory streaming으로 동작한다.
- 손상된 segment/source만 제외하고 나머지를 순서대로 partial recovery할 수 있다.
- partial 결과는 자동 전사되지 않고 사용자 확인 후 Retry Transcription을 제공한다.
- 전환 실패 전까지 온전한 audio는 정상 결과로 처리한다.
- 반복 launch와 모든 lifecycle crash window가 WAV 한 개/history 한 건으로 수렴한다.
- 성공한 recording은 inflight directory 전체가 제거된다.
- manual/failed recovery의 사용자 source는 자동 삭제되지 않는다.
- 기존 single/combined schema-v1 manifest 복구가 회귀하지 않는다.
- 전체 tests, Quill Dev build, codesign 검증, 실제 input-switch `SIGKILL` 검증을 통과한다.
