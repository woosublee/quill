# Issue #180 설계: Upstream-compatible Cloud Chunking + Quill Durable Resume

## 1. 배경

Issue #181을 통해 Quill은 장시간 녹음의 영구 WAV를 안전하게 보존하고, 중단된 녹음을 Note Browser에서 재생·재시도·삭제할 수 있다. 그러나 cloud file transcription은 여전히 완성된 오디오 파일 전체를 메모리에 읽어 하나의 multipart 요청으로 전송한다.

이 구조에서는 긴 녹음이 다음 이유로 전체 실패할 수 있다.

- provider의 요청당 파일 크기 제한
- 고정된 짧은 request timeout
- 일시적인 연결 중단 또는 HTTP 5xx
- 일부 전사가 완료됐더라도 재시작 시 처음부터 다시 요청해야 하는 구조

현재 Quill은 실패한 영구 오디오와 history item을 보존하고 사용자가 Local backend를 선택해 Retry할 수 있다. 하지만 이것은 사용자가 선택한 cloud 전사를 성공시키는 기능이 아니며, cloud에서 Local로 자동 전환하는 것도 제품 정책에 맞지 않는다.

이 설계는 다음 두 층으로 문제를 해결한다.

1. **Phase A:** upstream에도 제안할 수 있는 provider-neutral cloud chunking/retry core
2. **Phase B:** Quill의 history, Note Browser, Local Retry와 연결되는 durable resume adapter

두 단계는 별도 PR로 구현한다. Phase B는 Phase A 위에만 의존하며, Phase A에는 AppState, Core Data, SwiftUI 또는 Quill 전용 Local backend 개념을 넣지 않는다.

## 2. 목표

- 작은 파일의 기존 single-request cloud path와 public API를 유지한다.
- 큰 canonical Quill WAV를 deterministic chunk로 나눠 동일 cloud provider/model에 순차 전송한다.
- 전체 permanent WAV를 upload body 생성을 위해 메모리에 읽지 않는다.
- retryable failure에서는 현재 chunk만 bounded retry한다.
- 성공한 raw chunk transcript를 순서대로 결합한 뒤 기존 post-processing을 한 번만 실행한다.
- 완료한 chunk transcript를 안전하게 checkpoint하여 compatible job을 재실행 후 자동 재개한다.
- cloud partial transcript와 Local transcript를 절대 혼합하지 않는다.
- 영구 WAV를 playback, cloud Retry, Local Retry의 유일한 source of truth로 유지한다.
- upstream 공통 흐름과 Quill 전용 durable/UI 통합을 분리한다.

## 3. 확정된 제품 정책

### 3.1 Backend 선택

- 사용자가 cloud backend를 선택하면 가능한 한 동일 provider/model로 완료한다.
- cloud failure를 이유로 Local backend로 몰래 전환하지 않는다.
- 선택한 backend가 사용할 수 없으면 명시적인 실패 상태와 Retry 선택지를 제공한다.
- 사용자가 Local Retry를 선택하면 permanent WAV 전체를 처음부터 전사한다.

### 3.2 Source of truth

- recording ID 기반 permanent WAV가 유일한 오디오 source of truth다.
- cloud upload chunk WAV는 permanent WAV의 frame range에서 재생성 가능한 임시 산출물이다.
- chunk WAV 경로나 파일은 sidecar에 저장하지 않는다.
- cloud partial text와 Local partial text를 결합하지 않는다.

### 3.3 재실행 정책

앱 재실행 시 종료 전에 사용자가 이미 시작했던 **compatible interrupted cloud chunk job만 자동 재개**한다.

자동 재개 조건:

- sidecar phase가 `transcribing` 또는 process interruption으로 남은 `interrupted`
- history row와 permanent WAV가 존재
- source size/hash/canonical layout이 일치
- provider URL identity, model, language, response format이 일치
- chunk algorithm version, encoded ceiling, plan ID가 일치
- 현재 runtime에서 API key를 사용할 수 있음

다음 상태는 자동 요청하지 않고 explicit Retry를 기다린다.

- authentication, permission, invalid request, quota exhaustion 같은 terminal failure
- missing API key
- provider/model/language 변경
- source 또는 plan 불일치
- corrupt/incompatible sidecar

Relaunch resume 완료는 Note Browser item만 갱신한다. clipboard copy, focused app paste, Enter command는 자동 수행하지 않는다.

## 4. 범위 제외

- Local transcription chunking
- Realtime WebSocket protocol 또는 live PCM chunking 변경
- oversized noncanonical external import의 cloud canonicalization
- recorder capture graph 또는 public lifecycle API 변경
- recording journal state machine, segment assembly, recovery semantics 변경
- cloud에서 Local로 silent fallback
- 서로 다른 backend의 transcript 혼합
- 병렬 cloud chunk upload
- Core Data schema migration
- #193 retention/storage cap
- #214 stalled-capture watchdog
- #183 전체 오류 UX 재설계

## 5. 전체 구조

```text
Permanent recording WAV
        │
        ▼
TranscriptionService.transcribe(fileURL:)   기존 public contract
        │
        ├─ Local backend ─────────────────── 기존 경로 유지
        │
        └─ Cloud backend
             ├─ encoded request ≤ ceiling
             │    └─ 기존 single multipart request 1회
             │
             └─ encoded request > ceiling인 canonical WAV
                  └─ CloudTranscriptionCore
                       ├─ source identity + deterministic plan
                       ├─ current frame range만 temp WAV materialize
                       ├─ 동일 provider request 함수 호출
                       ├─ current chunk만 bounded retry
                       ├─ raw transcript checkpoint
                       └─ ordered raw transcript assembly
                                      │
                                      ▼
                         command parsing + post-processing 1회
```

Phase A는 `TranscriptionService` 안의 cloud branch에서만 사용된다. Local branch와 Realtime streaming은 변경하지 않는다. Realtime이 기존처럼 file-service fallback을 호출하면 그 fallback이 같은 cloud size policy를 적용받는다.

## 6. Phase A: upstream-compatible cloud core

### 6.1 Shared canonical WAV foundation

새 파일 `Sources/CanonicalPCM16WAV.swift`는 #217에서 확인한 WAV header/layout 중복을 줄이는 최소 공통 기반이다.

책임:

- canonical RIFF/WAVE header 생성
- strict 16,000 Hz, mono, signed little-endian PCM16 검증
- data payload offset, data byte count, frame count 제공
- bounded frame-range copy에 필요한 byte/frame 변환
- 작성된 standalone chunk WAV 검증

포함하지 않는 책임:

- arbitrary/noncanonical RIFF 변환
- multi-source mixing
- recording journal lifecycle
- cloud retry 또는 provider 설정

`RecordingCanonicalWAV`와 `AudioMixdownService`는 기존 public/internal behavior를 유지한다. Phase A에서는 중복된 canonical header/layout primitive만 shared foundation을 사용하도록 최소 조정한다. Recording finalization, recovery state, mixdown ordering은 바꾸지 않는다.

### 6.2 Chunk source identity와 plan

새 파일 `Sources/CloudTranscriptionChunking.swift`는 오디오 identity, deterministic plan, temp chunk materialization을 담당한다.

주요 타입:

```swift
struct CloudTranscriptionSourceIdentity: Codable, Equatable, Sendable {
    let audioFileName: String
    let physicalByteCount: UInt64
    let sha256: String
    let dataByteCount: UInt64
    let frameCount: UInt64
}

struct CloudTranscriptionChunk: Codable, Equatable, Sendable {
    let index: Int
    let startFrame: UInt64
    let endFrame: UInt64
    let estimatedEncodedByteCount: UInt64
}

struct CloudTranscriptionChunkPlan: Codable, Equatable, Sendable {
    let algorithmVersion: Int
    let encodedUploadCeilingBytes: UInt64
    let sourceFrameCount: UInt64
    let chunks: [CloudTranscriptionChunk]
    let planID: String
}
```

`CloudTranscriptionChunkPlanner`는 다음 순서로 plan을 만든다.

1. shared canonical WAV validator로 source layout 확인
2. 파일을 streaming read하여 SHA-256 계산
3. 실제 multipart field와 boundary overhead를 포함한 encoded ceiling 계산
4. ceiling을 넘지 않는 nominal frame end 계산
5. nominal end 이전 bounded 구간에서 silence-adjacent boundary 탐색
6. ordered descriptor와 plan ID 생성
7. exact contiguous coverage 검증

Plan invariant:

- 첫 chunk의 `startFrame == 0`
- `chunks[i].endFrame == chunks[i + 1].startFrame`
- 마지막 `endFrame == source.frameCount`
- 모든 chunk가 non-empty
- 전체 chunk frame 합계가 source frame count와 동일
- 모든 estimated encoded request가 ceiling 이하

### 6.3 Boundary algorithm v1

- descriptor는 half-open range `[startFrame, endFrame)`을 사용한다.
- nominal end는 encoded ceiling 이하인 최대 frame이다.
- 마지막 chunk가 아니면 nominal end 이전 최대 3초만 검색한다.
- 20 ms RMS window를 사용한다.
- 200 ms 이상 quiet한 run 중 nominal end에 가장 가까운 run midpoint를 선택한다.
- 적합한 quiet run이 없으면 nominal end를 그대로 사용한다.
- nominal end 뒤는 검색하지 않는다.
- overlap과 transcript text deduplication은 사용하지 않는다.
- threshold 또는 검색 규칙이 바뀌면 algorithm version을 올린다.

### 6.4 Bounded materialization

`CloudTranscriptionChunkMaterializer`는 한 attempt에서 한 chunk만 만든다.

1. source payload offset과 `startFrame`으로 seek
2. fixed-size buffer로 필요한 PCM bytes만 복사
3. shared canonical header를 앞에 기록
4. 출력 파일의 header/data/frame count 검증
5. request 완료, failure 또는 cancellation 뒤 attempt directory 삭제

Full permanent WAV를 `Data(contentsOf:)`로 읽지 않는다. Chunk는 encoded ceiling보다 작으므로 기존 request 함수가 chunk file과 multipart body를 `Data`로 구성하는 것은 bounded memory 사용으로 허용한다.

### 6.5 Cloud coordinator

새 파일 `Sources/CloudTranscriptionCore.swift`는 provider-neutral orchestration만 담당한다.

```swift
struct CloudTranscriptionConfiguration: Equatable, Sendable {
    let model: String
    let language: String
    let responseFormat: String
    let encodedUploadCeilingBytes: UInt64
    let minimumAttemptTimeoutSeconds: TimeInterval
    let maximumAttemptTimeoutSeconds: TimeInterval
    let maximumAttempts: Int
}

struct CloudTranscriptionJobIdentity: Codable, Equatable, Sendable {
    let providerID: String
    let model: String
    let language: String
    let responseFormat: String
    let source: CloudTranscriptionSourceIdentity
    let planID: String
}

struct CloudTranscriptionCheckpoint: Codable, Equatable, Sendable {
    let identity: CloudTranscriptionJobIdentity
    let completedRawTranscripts: [String]
}
```

Checkpoint는 index 0부터 시작하는 contiguous prefix만 허용한다. Core는 첫 incomplete chunk부터 순차 실행하고, 성공 raw text의 durable checkpoint가 완료된 뒤에만 다음 chunk를 요청한다.

Core가 받는 provider operation은 한 chunk file을 한 번 전사하는 async closure다. Endpoint, Authorization, multipart field, provider JSON parsing은 계속 `TranscriptionService`가 담당한다.

### 6.6 Structured cloud failure

현재 non-2xx response를 즉시 사용자용 문자열로 바꾸면 retry layer가 status와 safe provider code를 판단할 수 없다. Phase A는 transport 판단에 필요한 제한된 정보만 보존한다.

```swift
struct CloudTranscriptionHTTPFailure: Error, Equatable, Sendable {
    let statusCode: Int
    let retryAfterSeconds: TimeInterval?
    let providerCode: String?
    let providerType: String?
    let sanitizedMessage: String?
}
```

저장·표시 금지:

- Authorization header
- API/OAuth key
- raw provider response body
- multipart body
- absolute/temp path

최종 terminal failure에서만 기존 friendly error mapping을 적용한다.

### 6.7 Timeout과 retry

Small fast path는 기존 timeout 의미를 유지한다. Large chunk attempt만 size-aware timeout을 사용한다.

```text
calculated = 20s + encodedBytes / 131,072 bytes/sec
attemptTimeout = max(configured minimum, min(calculated, 300s))
```

Large job 전체 timeout은 두지 않는다. 각 chunk 최대 attempt는 3회다.

- initial attempt
- 1초 + injected jitter 뒤 retry
- 3초 + injected jitter 뒤 retry

`Retry-After`가 60초 이하면 backoff보다 우선한다. sleep과 jitter는 주입하여 테스트가 실제 대기하지 않게 한다.

Retryable:

- URL timeout
- connection lost
- offline
- cannot connect/find host
- DNS lookup failure
- HTTP 408
- HTTP 5xx
- quota exhaustion이 아닌 temporary HTTP 429

Terminal:

- cancellation
- HTTP 400, 401, 403, 404, 413, 415, 422
- certificate/configuration failure
- source validation 또는 materialization failure
- explicit `insufficient_quota`
- invalid 2xx response
- retry budget exhaustion

HTTP 413을 받았다고 실행 중 plan을 더 잘게 변경하지 않는다. 현재 configuration/limit mismatch로 종료하고 explicit Retry를 기다린다.

### 6.8 `TranscriptionService` 통합

기존 public contract는 유지한다.

```swift
func transcribe(fileURL: URL) async throws -> String
```

변경 범위:

1. 기존 cloud upload를 one-request private 함수로 추출
2. multipart encoded size가 ceiling 이하이면 기존 path 호출
3. 큰 canonical WAV만 planner/core로 전달
4. 큰 noncanonical external file은 현재 preflight 정책 유지
5. non-2xx를 structured failure로 변환한 뒤 retry 여부 결정
6. 전체 chunk raw text가 완성된 뒤 기존 normalization 반환

AppState의 command parsing과 post-processing은 전체 raw transcript에 한 번만 실행된다.

## 7. Phase B: Quill durable resume adapter

### 7.1 Durable job store

새 파일 `Sources/CloudTranscriptionJobStore.swift`는 history ID별 atomic JSON sidecar를 관리한다.

```text
Application Support/<AppName>/cloud-transcription/jobs/<historyID>.json
Temporary/<bundle-or-app-name>/cloud-transcription/<attempt-ID>/chunk.wav
```

Dev/production storage는 app display name 또는 bundle identity로 분리한다.

Durability sequence:

1. sibling temporary JSON write
2. file sync
3. permission `0600` 적용
4. atomic replace
5. parent directory sync

Sidecar write 실패 시 job을 중단한다. permanent WAV와 마지막 valid sidecar는 보존하고 다음 chunk를 요청하지 않는다.

### 7.2 Sidecar schema v1

```text
schemaVersion
historyID
createdAt
updatedAt
phase: prepared | transcribing | interrupted | failed | assembled
jobIdentity:
  providerID
  model
  language
  responseFormat
source:
  audioFileName
  physicalByteCount
  sha256
  dataByteCount
  frameCount
  canonicalFormat
plan:
  algorithmVersion
  encodedUploadCeilingBytes
  planID
  orderedChunkDescriptors
completedChunks:
  [{ index, normalizedRawText }]
firstIncompleteChunkIndex
lastFailure:
  category
  optionalHTTPStatus
  optionalRetryAfterSeconds
completionPolicy:
  postProcessingEnabled
  preserveExactWording
  outputLanguage
  pressEnterCommandEnabled
```

Sidecar 저장 금지:

- API key, OAuth token, post-processing key
- Authorization header
- raw provider response body
- absolute 또는 temporary path
- chunk WAV
- partial post-processed transcript

History에 이미 있는 selection, context, vocabulary, system prompt, calendar metadata는 sidecar에 복제하지 않는다.

Sidecar invariant:

- filename UUID와 `historyID` 일치
- `audioFileName`은 basename이며 path traversal 금지
- source가 Quill audio root 아래에 존재
- source size/hash/layout 일치
- plan이 exact contiguous coverage 만족
- completed chunks가 0부터 시작하는 unique contiguous prefix
- `firstIncompleteChunkIndex == completedChunks.count`
- `assembled`이면 completed count와 total chunk count가 동일
- 현재 runtime session token을 가진 writer만 sidecar 변경 가능

### 7.3 Stable execution snapshot

각 transcription 실행은 시작 시 immutable snapshot을 만든다.

Cloud snapshot:

- normalized transcription base URL
- provider ID hash
- API key는 memory에만 보유
- model
- language
- response format
- chunk algorithm version/ceiling

Local snapshot:

- selected Local backend/model/path

Completion snapshot:

- post-processing enabled
- preserve exact wording
- output language
- command/press-enter intent

실행 도중 Settings 변경이 현재 job identity나 request를 부분적으로 바꾸지 않는다.

### 7.4 Initial recording/import lifecycle

1. permanent audio 저장
2. stable history placeholder 저장
3. history ID를 cloud execution context에 전달
4. large cloud plan 준비 전 sidecar 생성
5. chunk 성공마다 raw transcript prefix checkpoint
6. partial cloud text는 history의 최종 transcript에 기록하지 않음
7. 전체 raw transcript assembly
8. 기존 command parsing/post-processing 한 번 실행
9. 최종 history update 성공
10. sidecar와 temp artifacts 삭제

Post-processing이 기존 정책에 따라 raw transcript를 fallback 결과로 사용하더라도 history 저장이 성공하면 cloud job은 완료로 정리한다.

### 7.5 Startup reconciliation과 auto-resume

순서:

1. stale cloud temp root 정리
2. 기존 recording journal startup recovery 실행
3. ordinary history load/trim
4. sidecar와 history/permanent audio reconcile
5. compatible progress map 복원
6. resumable `cloud-transcribing` item을 generic incomplete normalization에서 제외
7. AppState initialization 완료 뒤 별도 Task로 auto-resume

Recording journal recovery 함수에는 network/provider 요청을 넣지 않는다.

Auto-resume completion은 history item만 갱신하고 paste/Enter를 수행하지 않는다.

### 7.6 Retry 정책

- **같은 cloud identity:** completed prefix를 재사용하고 first incomplete chunk부터 재개
- **다른 cloud identity:** 기존 runtime session token을 무효화하고 chunk 0부터 새 job 시작
- **Local 선택:** permanent WAV 전체를 기존 Local service로 전사하고 cloud partial text를 무시
- **선택 backend unavailable:** 다른 backend로 대체하지 않고 명시적 오류

Local 성공과 history update가 완료되면 stale cloud sidecar를 삭제한다. Local 실패 시 permanent WAV와 cloud sidecar는 보존하되 transcript를 혼합하지 않는다.

### 7.7 Delete, clear, trim 경쟁

Core Data attribute는 추가하지 않는다. `DeletedPipelineHistoryAssets`가 existing entity/history ID를 cleanup coordinator에 전달하도록 확장한다.

공통 순서:

1. history ID의 active cloud Task cancel
2. job-store runtime session token invalidate
3. progress/retrying state 제거
4. Core Data row 삭제
5. permanent audio/transcript 삭제
6. sidecar/temp artifacts 삭제

Task cancellation만으로는 늦은 callback이 sidecar를 다시 만들 수 있으므로 session token 검증을 모든 write에 적용한다.

### 7.8 Note Browser progress

Core Data의 stable machine status는 `cloud-transcribing`을 사용한다. Dynamic progress는 status string에 누적하지 않는다.

- in-memory: `cloudTranscriptionProgressByHistoryID`
- relaunch restoration: sidecar의 completed count와 total count
- display: `Transcribing 3 of 7…` / `7개 중 3개 전사 중…`

Terminal UI에는 raw HTTP body, credential, absolute path를 표시하지 않는다.

## 8. 오류 및 보존 규칙

- retryable failure는 현재 chunk만 재시도한다.
- terminal failure 뒤 later chunk를 요청하지 않는다.
- completed durable transcript prefix와 permanent WAV를 보존한다.
- sidecar persistence 실패는 provider 요청을 계속하지 않는다.
- cancellation은 temp chunk를 지우고 permanent WAV를 유지한다.
- incompatible/corrupt sidecar는 자동 삭제해 숨기지 않고 explicit Retry가 가능한 상태로 보존한다.
- final history update 전에는 partial transcript를 completed result처럼 노출하지 않는다.

## 9. Upstream compatibility boundary

### Phase A에 포함

- shared canonical PCM16 WAV primitive
- deterministic cloud chunk planning/materialization
- structured HTTP failure
- timeout/retry policy
- ordered raw transcript assembly
- optional checkpoint/progress protocol
- 기존 `TranscriptionService.transcribe(fileURL:)` 유지

### Phase B에만 포함

- history ID와 Core Data row 연결
- atomic JSON sidecar
- relaunch auto-resume
- Note Browser progress
- Quill Local Retry policy
- delete/clear/trim lifecycle

Phase A를 upstream equivalent implementation으로 교체하더라도 Phase B가 provider-neutral checkpoint/progress boundary를 통해 계속 동작하도록 한다.

## 10. 테스트 전략

### Phase A

- canonical WAV header/layout roundtrip와 기존 recording/mixdown regression
- exact ceiling과 multipart overhead
- deterministic silence/fallback boundary
- exact frame coverage
- first/middle/last chunk materialization
- streaming SHA-256
- retry sequence, Retry-After, cancellation, quota/auth terminal
- checkpoint-before-next ordering
- small file single-request regression
- Local branch와 Realtime fallback contract

### Phase B

- atomic sidecar roundtrip와 `0600`
- credential/raw body/path exclusion
- same identity resume, different identity restart
- Local whole-source Retry와 no mixed transcript
- compatible-only startup auto-resume
- terminal failure no-loop
- no paste/Enter after relaunch
- delete/clear/trim stale callback rejection
- progress restoration와 영어·한국어 localization
- repeated relaunch 후 one history row/one permanent WAV

## 11. 전달 전략

### PR A: `issue-180-cloud-chunking-core`

- `CanonicalPCM16WAV`
- chunk planner/materializer/source identity
- cloud retry/core
- minimal `TranscriptionService` integration
- focused tests와 Makefile wiring

AppState, Core Data, Note Browser는 수정하지 않는다. Recording/mixdown 수정은 canonical primitive 재사용에 한정한다.

### PR B: `issue-180-cloud-durable-resume`

PR A merge 뒤 updated `origin/main`에서 시작한다.

- `CloudTranscriptionJobStore`
- immutable execution snapshot 연결
- AppState startup/retry/cleanup orchestration
- PipelineHistory status 해석
- Note Browser progress/localization
- lifecycle tests

두 PR은 각각 fresh full test/build 검증 후 별도로 전달한다.

## 12. 완료 기준

- 짧은 파일은 기존 single-request path를 한 번만 사용한다.
- 60분 canonical Quill WAV가 provider request limit보다 작게 나뉘어 동일 cloud backend에서 완료된다.
- permanent WAV 전체가 upload body 생성을 위해 메모리에 적재되지 않는다.
- chunk request가 configured encoded ceiling을 넘지 않는다.
- audio frame 누락·중복 없이 ordered transcript가 만들어진다.
- retryable failure는 affected chunk만 재전송한다.
- quota/auth terminal failure는 later request를 중단하고 source/checkpoint를 보존한다.
- compatible relaunch는 first incomplete chunk부터 자동 재개한다.
- terminal/incompatible job은 relaunch마다 자동 요청하지 않는다.
- Local Retry는 original permanent WAV 전체를 사용하고 cloud partial text와 혼합하지 않는다.
- 반복 relaunch/Retry 후 history item과 permanent WAV가 각각 하나만 남는다.
- 성공, failure, cancellation, relaunch 뒤 temp upload WAV가 누적되지 않는다.
- post-processing은 complete raw transcript에 한 번만 실행된다.
