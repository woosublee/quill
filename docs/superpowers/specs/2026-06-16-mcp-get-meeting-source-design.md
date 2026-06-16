# MCP `get_meeting_source` + `/mn` deterministic 전환 설계

- 날짜: 2026-06-16
- 브랜치: `feat/mcp-get-meeting-source`
- 관련 코드: `Sources/MCPServer.swift`, `Sources/PipelineHistoryItem.swift`, `Sources/CalendarIntegrationModels.swift`, `/mn` 스킬(`~/Library/Mobile Documents/.../claude/.agents/skills/mn/SKILL.md`)

## 배경 / 문제

`/mn` 스킬로 Quill 전사문 기반 회의록을 만들 때 느리고 결과가 불안정하다. 원인은 Claude의 능력 부족이 아니라 **MCP가 회의록 생성에 필요한 구조화된 원천 데이터를 충분히 주지 않고, 그 공백을 `/mn`이 SQLite 직접 조회 + 추론으로 메우는** 구조다.

현재 상태:

- Swift 모델 `PipelineHistoryItem`은 이미 필요한 필드를 모두 갖고 있다: `customTitle`, `calendarMatch`(title/start/end/attendees, attendee별 email·displayName·responseStatus·isSelf·isOptional), `recordingStartedAt`/`recordingEndedAt`, `audioFileName`, `transcriptFileName`, `contextSummary`. 앱은 `AppState.audioStorageDirectory()`로 오디오 절대경로도 안다.
- 그러나 MCP `get_transcript`는 **텍스트 blob**로 일부만 노출한다: `id, timestamp, transcript, raw_transcript, context`. title/calendar/attendees/audio/recordingStartedAt가 전부 빠져 있다.
- 그래서 `/mn`은 `PipelineHistory.sqlite`를 직접 2회 조회하고, Apple epoch 변환 산수(`+978307200`)를 하고, `ZCALENDARMATCHJSON`을 수동 파싱하고, 오디오는 파일 mtime 기반으로 추론한다.

## 목표

MCP가 구조화된 원천 데이터를 deterministic하게 제공하고, `/mn`은 요약·Action Items·민감도 정제·People/Obsidian 컨벤션 매칭 같은 판단 영역만 담당하도록 역할을 분리한다.

비목표(이번 범위 아님):

- `PipelineHistoryItem` 모델 스키마 변경 (모든 필드가 이미 존재)
- 기존 `get_transcript`의 출력 형식 변경 (사람이 읽는 텍스트로 유지)
- People 매칭/회의록 포맷 등 Obsidian 측 로직 변경

## 설계 결정 (확정)

1. **새 도구 `get_meeting_source` 추가, JSON 반환.** `get_transcript`는 사람이 읽는 텍스트로 그대로 둔다. 하위호환 안전.
2. **참석자는 구조화 원본 + `is_resource` 플래그까지만 앱이 가공.** People 폴더 매칭과 최종 필터는 `/mn`이 담당.
3. **`/mn`의 SQLite 직접 조회는 완전 제거하지 않고 fallback으로 격하.** 주 경로는 MCP, SQLite는 구버전 Quill·필드 누락 대비.

## 컴포넌트 1 — MCP 도구 `get_meeting_source(id)`

### 인터페이스

- 입력: `{ "id": "<UUID>" }` (필수, `list_transcripts`에서 얻은 id)
- 출력: MCP content는 텍스트 타입이므로 **JSON 문자열** 1개를 text content로 반환
- id 미존재/유효하지 않으면 `isError: true` 텍스트 반환 (기존 `get_transcript`와 동일 패턴)

### JSON 스키마

```json
{
  "id": "UUID",
  "title": {
    "custom": "사용자가 Quill에서 지정한 제목 | null",
    "calendar": "캘린더 매칭 title | null",
    "resolved": "custom → calendar 순으로 결정된 값 | null"
  },
  "timestamps": {
    "recording_started_at": "2026-05-15T14:00:00+09:00 | null",
    "recording_ended_at": "ISO8601(+offset) | null",
    "transcript_created_at": "ISO8601(+offset)"
  },
  "calendar": {
    "title": "...",
    "start": "ISO8601(+offset)",
    "end": "ISO8601(+offset)",
    "attendees": [
      {
        "display_name": "... | null",
        "email": "... | null",
        "response_status": "accepted | declined | tentative | needsAction | null",
        "is_self": false,
        "is_optional": false,
        "is_resource": true
      }
    ]
  },
  "audio": {
    "filename": "uuid.wav",
    "path": "/Users/.../Library/Application Support/Quill/audio/uuid.wav",
    "exists": true
  },
  "transcript": "post-processed transcript",
  "raw_transcript": "raw transcript",
  "context": "context summary"
}
```

규칙:

- **시각은 앱이 ISO8601(timezone offset 포함)로 변환해서 준다.** `/mn`에서 Apple epoch 변환(`+978307200`) 완전 제거.
- **`audio.path`는 앱이 `audioStorageDirectory()`로 해결한 절대경로.** `exists`는 `FileManager`로 실제 파일 존재 여부 검증.
- **`is_resource`는 앱이 계산.** 판정 규칙: attendee email에 `resource.calendar.google.com` 포함 시 `true`. (displayName 기반 회의실 휴리스틱은 모호하므로 앱에 넣지 않고 `/mn`이 보조 판단으로 유지.)
- 매칭/데이터 없는 상위 객체는 `null`: `calendar` 미매칭 시 `"calendar": null`, 오디오 없음 시 `"audio": null`. 개별 스칼라 누락은 해당 키 `null`.
- `title.resolved`는 `custom`(비어있지 않으면) → `calendar` 순. 둘 다 없으면 `null` (전사문 추론은 `/mn` 몫).

### 구현 노트 (`Sources/MCPServer.swift`)

- `toolDefinitions()`에 `get_meeting_source` 항목 추가 (input schema: `id` required string).
- `callTool`에 `case "get_meeting_source"` 추가:
  - `args["id"]` → `UUID` 파싱, 실패 시 `isError`.
  - `appState.pipelineHistory.first(where: { $0.id == uuid })`로 항목 조회, 없으면 `isError`.
  - `ISO8601DateFormatter`(`formatOptions = [.withInternetDateTime]`, `timeZone = .current`)로 Date 직렬화.
  - `audioFileName`이 있으면 `AppState.audioStorageDirectory().appendingPathComponent(name)`로 절대경로 + `FileManager.default.fileExists`로 `exists`.
  - `calendarMatch`의 attendee를 순회하며 `is_resource = email?.contains("resource.calendar.google.com") ?? false`.
  - `[String: Any]` 딕셔너리 구성 후 `JSONSerialization.data` → 문자열 → `textContent(jsonString)`.
- 모델 변경 없음.

## 컴포넌트 2 — `/mn` 스킬 변경

대상 파일: `~/Library/Mobile Documents/com~apple~CloudDocs/claude/.agents/skills/mn/SKILL.md` (iCloud 동기화 본; `.claude/skills/mn`은 심링크/사본).

변경 지점:

- **st/mk 4단계(Quill 메타데이터 조회):** SQLite 1차 조회 블록 → `mcp__quill__get_meeting_source(id)` 호출로 교체.
  - 제목: `title.resolved` → (null이면) 전사문/context 추론. 정규화 규칙은 유지.
  - 회의일시: `calendar.start` → `timestamps.recording_started_at` → `timestamps.transcript_created_at`. **epoch 변환 산수 삭제** (이미 ISO8601).
  - 참석자: `calendar.attendees`에서 `is_resource == true || response_status == "declined" || is_self == true` 제외 → 남은 참석자를 `$VAULT/People/`와 email/displayName 매칭(유지). displayName 회의실 휴리스틱은 보조로 유지.
- **st/mk 5단계(오디오 복사):** SQLite 조회 + mtime fallback → `audio.path`를 그대로 `cp`.
  - `audio`가 `null`이거나 `audio.exists == false`면 오디오 없이 진행.
- **SQLite 블록 + mtime fallback:** 삭제하지 않고 "MCP `get_meeting_source`가 없거나 필드를 비워 주는 구버전 Quill 대비 fallback"으로 명시 격하. 주 경로는 항상 MCP.
- "처리 전 필수 사항"/"실행 흐름" 섹션의 SQLite 우선 표현을 MCP 우선으로 갱신.

## 역할 분리 결과

- **MCP/앱 (deterministic):** 제목 후보, 시각(ISO8601), 오디오 절대경로+존재검증, 구조화 attendees + is_resource.
- **Claude/`/mn` (판단):** 요약, Action Items, 민감도 정제, People/Obsidian 컨벤션 매칭, 전사문 기반 제목 추론(메타데이터 없을 때).

## 데이터 플로우

```
list_transcripts → id
  → get_meeting_source(id)  ── JSON ──▶  /mn
       (title/timestamps/calendar/audio/transcript)
  → /mn: 참석자 People 매칭 + 요약/Action Items 생성
  → Obsidian 회의록 파일 작성 (+ audio.path cp)
```

## 오류 처리 / 엣지 케이스

- id 미존재 → MCP `isError`; `/mn`은 안내 후 종료.
- `calendar == null` → 제목·시각·참석자는 transcript/recording 기반으로 진행.
- `audio == null` 또는 `exists == false` → 오디오 첨부 생략.
- MCP에 `get_meeting_source`가 없는 구버전(tools/list에 미존재) → `/mn`이 기존 SQLite fallback 경로 사용.
- 전사 둘 다 빈 값 → 기존과 동일하게 "전사 내용 없음" 안내.

## 테스트

- `Tests/`에 MCP 서버 테스트가 있으면 동일 패턴으로 `get_meeting_source`의 JSON 직렬화 케이스 추가(calendar 있음/없음, audio 있음/없음, id 미존재).
- 빌드 후 실제 transcript id로 `get_meeting_source` 호출해 JSON 구조·ISO8601·절대경로·is_resource 확인.
- `/mn st`(또는 `mk`) end-to-end로 epoch 산수/SQLite 없이 회의록이 동일 품질로 생성되는지 검증.

## 마이그레이션 / 호환성

- 기존 `get_transcript`·`list_transcripts` 등 다른 도구는 변경 없음.
- `/mn`의 SQLite fallback 유지로 구버전 Quill에서도 동작.
- 모델·DB 스키마 변경 없음.
