# Model-first Settings redesign

- **Status:** Native Whisper dropdown management follow-up and window-close regression fixes implemented; automated verification complete
- **Date:** 2026-07-17
- **Issue:** [#64 — Clarify transcription and AI processing provider settings](https://github.com/woosublee/quill/issues/64)
- **Related:** [#145 — Local-first AI pipeline](https://github.com/woosublee/quill/issues/145), [#176 — General-consumer launch readiness](https://github.com/woosublee/quill/issues/176)
- **Supersedes:** [`2026-06-19-model-selection-ux-design.md`](./2026-06-19-model-selection-ux-design.md)

## Goal

현재 `Models` Settings가 제공하는 기능, 옵션, 저장값, fallback, 모델 관리 동작을 **하나도 삭제하거나 의미를 바꾸지 않고**, 사용자가 다음 세 가지를 먼저 이해할 수 있는 model-first 화면으로 재구성한다.

1. 어떤 기능이 켜져 있는가?
2. 각 기능은 어떤 모델을 사용하는가?
3. 선택한 모델을 사용하기 위해 무엇이 필요한가?

변경의 목표는 기능 축소나 기본값 변경이 아니라 **정보 구조, 표현, readiness 안내의 개선**이다.

## Current implementation boundary: UI-only

This implementation pass changes only the information architecture and presentation of the existing `Models` Settings screen.

It reuses the current `AppState` properties, provider routing, model catalogs, persistence keys, fallback behavior, and Native/Legacy model lifecycle without modification. No Local AI Server, new backend type, endpoint routing, migration, or model capability filtering is implemented in this pass.

Implemented in the first UI pass: Cloud Provider placement, unified existing Transcription choice presentation, Post-processing/Context positive toggles, feature disclosures, and Auto Paste placement in Shortcuts > Clipboard. The approved follow-up separates Cloud Provider, Transcription, Post-processing, and Context into four peer `SettingsCard`s and adds UI-only readiness constraints for the currently Cloud-only Post-processing and Context controls. Runtime routing, persistence, defaults, fallbacks, and model lifecycle remain unchanged. No product functionality is added.

The corrected layout keeps the main native menu Picker as the only active Transcription backend/method selector. Its API section presents all predefined Standard API transcription models from `ModelConfiguration.transcriptionModels`, plus a persisted nonempty custom model ID when needed; each entry keeps the existing AppState availability display and setter route. API transcription entries remain visible but disabled when neither the common Cloud key nor the existing Transcription override key is configured. Local and installed Legacy choices remain independently selectable.

Details contains a clearly labeled direct Custom Standard API Model ID field for extending that main list without repeating the predefined model dropdown, Realtime option/model configuration, and the existing Legacy lifecycle management. Native Whisper management moves out of the separate Local Options block and appears directly below the main dropdown when the user chooses an uninstalled Native model or selects the installed Native model. The dropdown continues to display the actual active model until the Native install completes. Legacy management remains in its existing disclosure and retains its opt-in toggle, rows, binary path, and lifecycle. Post-processing and Context retain native accessible switches without visible On/Off text. When the common Cloud API key is absent, each switch keeps its persisted visual value but is disabled, and its Cloud model selector is disabled with an inline explanation. The separate `Required · Always On` badge is not rendered. Paste Automatically is the first option in Shortcuts > Clipboard, ahead of the existing clipboard settings.

The Local AI Server and cross-backend routing sections below are retained only as future product exploration and are not acceptance criteria for the current UI implementation.

## Non-negotiable preservation rule

이 설계와 이후 구현은 다음 원칙을 반드시 지킨다.

- 현재 제공 중인 모든 옵션은 새 UI에서도 접근할 수 있어야 한다.
- 기존 저장값은 손실 없이 유지한다.
- 업그레이드 직후 사용자의 활성 기능, 선택 모델, prompt, language, provider, 모델 설치 상태가 바뀌면 안 된다.
- 현재 runtime의 fallback과 안전 동작을 유지한다.
- 기존 custom model ID 입력 기능을 유지한다.
- 현재 `ModelConfiguration`에 노출된 predefined model을 임의로 제거하거나 필터링하지 않는다.
- Native Whisper와 Legacy mlx-whisper의 다운로드·진행률·취소·재시도·설치 확인·삭제·오류 표시를 모두 유지한다.
- Local transcription을 선택했다는 이유로 Post-processing, Context, Edit Mode, Output Language를 사용할 수 없게 만들지 않는다.
- Future Local AI Server 지원은 기존 Cloud 동작에 추가되는 선택지이며 Cloud 경로를 대체하지 않는다.

기존 옵션을 다른 위치로 옮길 수는 있지만, 숨겨서 찾을 수 없게 하거나 다른 옵션에 암묵적으로 합치지 않는다. 구현 PR에는 이 문서의 1:1 보존표를 기준으로 누락 검증을 포함한다.

## Scope

### In scope

- 기존 전역 Settings sidebar와 단일 `Models` 화면 유지
- 공통 Cloud Provider 설정의 명확한 배치
- Transcription, Post-processing, Context의 기능별 model-first 선택
- Cloud Provider, Transcription, Post-processing, Context를 peer card로 분리
- Post-processing과 Context의 명시적인 on/off toggle
- 현재 Cloud-only 기능의 API Key readiness를 control과 inline 안내로 표현
- 기능별 상세 설정을 disclosure에 재배치
- Realtime과 Legacy mlx-whisper를 조건부 Transcription 선택지로 표현
- Native Whisper 및 Legacy 모델 관리 UI 유지
- 기존 Cloud provider와 transcription-only override의 역할 구분
- 현재 옵션과 새 위치의 1:1 보존 검증

### Out of scope

- 기존 모델이나 옵션 삭제
- 기본 모델, 기본 language, 기본 prompt, 기본 toggle 값 변경
- Native Whisper 또는 Legacy mlx-whisper 교체
- Embedded `llama-server` 및 bundled local LLM 다운로드 — #119 범위
- Realtime protocol 또는 transcription pipeline 변경
- Context screenshot 기능 축소
- Edit Mode invocation style 또는 modifier를 `Models`로 이동
- Voice Macro, Clipboard, audio input 동작 변경
- 새로운 Settings 하위 sidebar, inspector, pipeline dashboard, 별도 detail screen 추가
- `AppState` 전체 분해 — #192 범위
- 외부 Local AI Server 연결, backend 선택, endpoint routing
- Post-processing/Context/Realtime/Legacy용 새 persistence key 또는 migration
- primary/fallback의 cross-backend 실행

## Current-state problems

현재 화면은 `Transcription`, `Language`, `Custom Vocabulary`, `System Prompt`, `Instruction Guard`, `Context Prompt` 카드로 나뉘지만, provider와 model은 API transcription의 `Advanced Provider Settings` 안에 모여 있다 (`Sources/SettingsView.swift:1555-1575`, `Sources/SettingsView.swift:1707-1762`).

그 결과 다음 관계가 UI에서 잘못 전달된다.

- 공통 `API Key`와 `API Base URL`은 Post-processing, Edit Mode, Context에도 사용되지만 API transcription 설정처럼 보인다.
- Local transcription을 선택하면 provider model 설정이 보이지 않아 Local transcription과 Cloud Post-processing/Edit Mode를 함께 쓸 수 없다고 오해하기 쉽다.
- `Output Language`가 Local transcription일 때 비활성화된다 (`Sources/SettingsView.swift:1783-1805`). 실제 runtime에서는 transcription backend와 독립적으로 Post-processing 및 Edit Mode에 전달된다 (`Sources/AppState.swift:2998-3009`, `Sources/AppState.swift:5221-5276`).
- `Disable Post-Processing`, `Disable Auto Paste`, `Disable Context Capture`가 Transcription의 `Shared Behaviors` 아래 섞여 있어 서로 독립적인 단계임을 알기 어렵다 (`Sources/SettingsView.swift:1808-1846`).
- Realtime은 별도 toggle이지만 실제로는 Standard API, Native Whisper, Apple Live, Legacy mlx-whisper와 서로 배타적인 Transcription choice다 (`Sources/AppState.swift:827-855`, `Sources/AppState.swift:1151-1263`).
- Legacy mlx-whisper는 활성화, 설치, 선택, binary path가 한 영역에 섞여 있다.

## Design decision

### Keep one Models screen

왼쪽 전역 navigation은 바꾸지 않는다. `Models` 내부에도 하위 navigation을 추가하지 않는다.

화면은 위에서 아래로 네 개의 같은 수준인 `SettingsCard`를 갖는다.

1. **Cloud Provider** — Cloud model이 공통으로 사용하는 연결 정보
2. **Transcription** — 현재 transcription method/model과 해당 readiness
3. **Post-processing** — 활성 상태, Cloud model, 세부 동작
4. **Context** — 활성 상태, Cloud model, 세부 동작

세 기능을 다시 `AI Models`라는 하나의 큰 카드 안에 넣지 않는다. 기능별 title, model picker, readiness 안내, `Details`가 한 카드 안에서 완결되도록 한다. `Auto Paste`는 model 설정이 아니라 clipboard delivery behavior이므로 Models에 별도 카드를 두지 않고 기존 `Shortcuts > Clipboard`의 첫 옵션으로 배치한다.

### Choose the model first

기능별 기본 행에서 model dropdown을 먼저 보여준다. 현재 Cloud, Local, Legacy transcription method는 별도 전역 mode가 아니라 기존 선택 결과를 설명하는 속성으로 표현한다.

- Transcription: 기존 `TranscriptionBackendChoice`를 그대로 사용
- Post-processing / fallback / Context: 기존 저장된 model ID를 그대로 표시하고 선택
- 현재 UI pass는 backend 선택값이나 backend badge를 추가하지 않는다.

### Progressive disclosure

기본 화면은 다음만 보여준다.

- Cloud Provider key configuration 상태
- 각 기능의 persisted on/off 상태
- 각 기능의 선택 model
- 선택된 Cloud/Local method가 현재 준비됐는지 여부
- 비활성 control 바로 아래의 readiness 이유

기존 고급 옵션은 기능 행 바로 아래의 `Details` disclosure에서 제공한다. 별도 detail screen으로 이동하지 않으므로 model을 바꾸기 위해 화면을 왕복하지 않는다.

## Information architecture

```text
Models
├─ Cloud Provider
│  ├─ API Key + Save / Clear + validation status
│  └─ Advanced Provider Settings
│     ├─ Cloud Base URL
│     └─ Future Local AI Server (not implemented in this UI pass)
│        ├─ Base URL
│        ├─ Optional API Key
│        ├─ Check Connection
│        └─ discovered model status
│
├─ Transcription
│  ├─ Model / method dropdown
│  │  ├─ API choices remain visible; disabled without resolved transcription key
│  │  └─ Local/installed Legacy choices remain independently available
│  ├─ inline readiness reason for the current unavailable API choice
│  ├─ contextual Native Whisper management
│  │  ├─ download / progress / cancel / retry
│  │  ├─ Installed / delete confirmation / delete / error
│  │  └─ active model remains unchanged until install completes
│  └─ Details
│     ├─ Spoken Language
│     ├─ Custom Standard API Model configuration
│     ├─ Realtime option and API model configuration
│     ├─ Transcription provider override URL / key
│     └─ Legacy mlx-whisper availability
│        ├─ binary path
│        └─ per-model management
│
├─ Post-processing                    persisted On / Off
│  ├─ disabled switch without common Cloud API key
│  ├─ Primary Cloud model dropdown
│  ├─ inline API Key readiness reason
│  └─ Details
│     ├─ Output Language
│     ├─ Preserve Exact Wording
│     ├─ Fallback Cloud Model
│     ├─ Custom Vocabulary
│     ├─ System Prompt
│     │  ├─ default/custom state and editor
│     │  ├─ newer-default notice and actions
│     │  └─ test/result/full prompt
│     ├─ Instruction Guard
│     └─ Edit Mode dependency note
│
└─ Context                            persisted On / Off
   ├─ disabled switch without common Cloud API key
   ├─ Cloud Model dropdown
   ├─ inline API Key readiness reason
   └─ Details
      ├─ Context Prompt
      │  ├─ default/custom state and editor
      │  ├─ newer-default notice and actions
      │  └─ test/result/full prompt
      └─ Screenshot Resolution

Shortcuts
└─ Clipboard
   ├─ Paste Automatically              On / Off
   └─ Existing clipboard settings
```

## Cloud Provider

### Common Cloud connection

상단 `Cloud Provider` 영역은 현재의 `apiKey`와 `apiBaseURL`을 그대로 사용한다 (`Sources/AppState.swift:437-449`). 저장 key를 바꾸지 않는다.

기본 상태:

- API Key secure field
- `Save` 또는 `Clear`
- `Validating…`, success, error 상태
- 현재와 같은 `/models` 기반 validation (`Sources/TranscriptionService.swift:64-80`)

Advanced disclosure:

- `Cloud Base URL`
- `Reset to Default`
- default: `https://api.groq.com/openai/v1`

Cloud Provider는 다음 기능에 사용된다.

- Standard API transcription — transcription override가 비어 있을 때
- Realtime transcription — transcription override가 비어 있을 때
- Cloud Post-processing
- Cloud Post-processing fallback
- Edit Mode의 Cloud transform
- Cloud Context inference
- System Prompt test 및 Context Prompt test의 Cloud choice

### Current UI readiness semantics

이번 UI-only pass에서 Cloud readiness는 **현재 저장된 common API Key의 존재 여부**로 판단한다. 입력 중인 draft나 Settings 진입 시의 새 network validation 결과를 별도 저장하지 않는다.

- persisted key 없음: 빈 secure field 자체로 미설정 상태가 명확하므로 별도의 `not configured` status를 반복하지 않음
- validation 진행 중: `Validating…`
- Save validation 성공: key를 저장하고 `API Key configured`
- validation 실패: 현재 validation error를 표시하고 기존 persisted key를 변경하지 않음
- Settings 재진입: persisted key가 있으면 `API Key configured`
- Clear: persisted key와 configured status를 제거해 빈 secure field 상태로 돌아감

`API Key configured`는 Save validation을 통과한 key가 저장되어 있음을 뜻한다. Settings 진입마다 연결을 재확인하지 않으므로 `Connected`, `Valid`, `Available`처럼 지속적인 network health를 보장하는 표현을 사용하지 않는다.

현재 Cloud-only인 Post-processing과 Context에서는 common key가 비어 있으면 switch와 Cloud model selector를 비활성화한다. persisted switch/model 값은 변경하거나 숨기지 않는다. 비활성 control 바로 아래에 icon과 text를 함께 사용한 inline readiness 이유를 표시한다. `Details` 전체는 비활성화하지 않는다.

### Future work — Local AI Server (not implemented in this UI pass)

\#64가 #145 Phase 2를 충족하도록 Post-processing과 Context에서 외부 OpenAI-compatible Local AI Server를 선택할 수 있게 한다.

새 설정:

- Local AI Server Base URL
- Optional Local AI Server API Key
- `Check Connection`
- connection status
- `/models`에서 발견한 model 목록

기본 URL은 구현 시 Ollama/LM Studio의 OpenAI-compatible endpoint와 호환되는 값을 정하되, 빈 값과 custom URL을 모두 허용한다. API key가 비어 있으면 `Authorization` header를 보내지 않는다.

Local backend readiness는 **유효한 Base URL과 연결 확인 결과**로 판단한다. 현재 `AppContextService`의 `apiKey.isEmpty` gate는 Cloud에만 적용되는 가정이므로 backend-aware readiness로 바꾼다. Local key가 비어 있어도 연결된 Local AI Server에서는 Context LLM inference를 수행해야 한다. Local Server request는 key가 있을 때만 Bearer header를 추가한다. Cloud request의 key gate와 header 구성은 기존 동작을 유지한다.

연결 확인 실패가 기존 Cloud configuration을 변경하거나 비활성화해서는 안 된다.

## Shared model dropdown behavior

모든 model picker는 dropdown 형태를 사용한다.

Post-processing, fallback, Context dropdown은 다음 group을 지원한다.

- **Cloud** — 현재 `ModelConfiguration.llmModels` 전체
- **Custom…** — 사용자가 arbitrary model ID를 직접 입력

다음 보존 규칙을 지킨다.

- 현재 predefined model 목록을 임의로 필터링하거나 삭제하지 않는다 (`Sources/ModelConfiguration.swift:10-32`).
- 현재 저장된 custom model이 catalog에 없어도 `Custom…`으로 그대로 보인다.
- `Reset to Default`는 현재 Cloud model default를 유지한다.
- model display name을 꾸며 보여주더라도 API에 보내는 persisted `modelID`와 기존 Cloud 경로는 바꾸지 않는다.

Future Local AI Server model discovery, backend choice storage, and cross-backend dropdown groups are deferred to the Future work sections below.

## Transcription

### Required feature

Transcription은 끌 수 없지만 별도 `Required · Always On` 문구를 표시하지 않는다. 기능 제목과 유일한 model picker만으로 필수 기능임을 명확하게 유지한다.

기존 `useLocalTranscription`, `realtimeStreamingEnabled`, `useLegacyMlxWhisper`, `localTranscriptionModel`, `transcriptionModel`을 대체하지 않고 현재 `TranscriptionBackendChoice` adapter를 그대로 source of truth로 사용한다 (`Sources/AppState.swift:827-855`).

### Unified method/model dropdown

dropdown group:

1. **On This Mac**
   - Apple Live · Apple Speech
   - Native Whisper · 현재 recommended native model
2. **Cloud API**
   - Standard API · 현재 `transcriptionModel`
   - Realtime API · 현재 `realtimeStreamingModel` 또는 `Provider default`
3. **Legacy mlx-whisper**
   - 설치된 Legacy model 각각

선택은 현재 `setNoteBrowserTranscriptionChoice(_:)` 경로를 사용해 서로 배타적인 기존 booleans를 설정한다 (`Sources/AppState.swift:1151-1263`). 별도의 parallel transcription path를 만들지 않는다.

### Readiness and unavailable choices

현재 availability 조건을 그대로 사용한다 (`Sources/AppState.swift:863-935`).

- Standard API: resolved transcription API key 필요
- Realtime API: key 필요, `System Default + System Audio`에서는 사용 불가
- Native Whisper: native model 설치 필요
- Apple Live: `System Default + System Audio`에서는 사용 불가
- Legacy: 해당 model 설치 필요

resolved transcription key는 현재와 같이 Transcription override key를 우선하고, override가 비어 있으면 common Cloud key를 사용한다 (`Sources/AppState.swift:2181-2184`). API key가 없을 때도 dropdown 자체와 API model entries를 숨기지 않는다. Standard/Realtime API entries만 기존 unavailable reason과 함께 비활성화하고, Local 및 설치된 Legacy entries는 계속 선택 가능하다.

현재 persisted choice가 unavailable API choice라면 Transcription 카드 안에 다음 의미의 inline 안내를 표시한다.

> Cloud transcription requires an API key. Add one in Cloud Provider or use the transcription override in Details.

이 안내는 선택값을 자동 변경하거나 fallback을 새로 실행하지 않는다.

Native Whisper처럼 설치로 해결 가능한 unavailable choice는 dropdown에 보이되 `Download required` 상태를 함께 표시한다. 사용자가 선택하면 runtime choice를 즉시 unavailable 상태로 바꾸지 않고, view-local pending Native model ID를 설정해 dropdown 바로 아래에 관리 영역을 연다. Dropdown button은 실제 active choice label을 계속 표시한다.

- Native 항목 클릭만으로 다운로드를 자동 시작하지 않음
- Download 클릭 → existing AppState Native installer 시작
- 다운로드 중 다른 Transcription choice 선택 → active choice와 pending management selection 변경, 다운로드는 계속 진행
- 다운로드 중 다른 Settings tab 이동 → 다운로드는 AppState에서 계속 진행
- Models로 돌아와 다운로드 중인 Native 항목 클릭 → 현재 progress와 Cancel action 복원
- 다운로드 성공 + 같은 Native management flow를 계속 보고 있음 → 기존 `setNoteBrowserTranscriptionChoice`로 선택 확정
- 다운로드 성공 + 다른 모델 또는 Settings tab으로 이동함 → 설치만 완료하고 active choice 유지
- 명시적 Cancel / failure → current active choice 유지
- Settings window 닫기 → 기존처럼 다운로드 취소 및 partial file cleanup
- audio input incompatibility → 이유를 표시하고 current active choice 유지

이 pending state는 view-local이며 저장하지 않는다. runtime fallback 규칙을 바꾸지 않는다. Cloud key가 없는 API choice는 pending management 대상으로 취급하지 않고 menu item 자체를 비활성화한다.

### Spoken Language

현재 `transcriptionLanguage` 전체 option과 `Auto Detect`를 Transcription details로 이동한다. speech recognition hint라는 의미와 persisted code를 그대로 유지한다 (`Sources/SettingsView.swift:1765-1779`).

### Realtime API availability

Realtime은 현재 `realtimeStreamingEnabled`와 `TranscriptionBackendChoice`가 결정하는 기존 Transcription choice로 표현한다.

- 현재 Realtime 선택과 model field를 유지한다.
- 빈 model은 `Provider default`라는 현재 의미를 유지한다.
- 기존 availability 조건과 fallback 경로를 그대로 표시한다.

현재 UI pass는 Realtime menu visibility preference, 새 key, migration을 추가하지 않는다. 이러한 availability preference 설계는 Future work다.

### Transcription provider override

현재 `transcriptionAPIURL`과 `transcriptionAPIKey`를 details에 유지한다.

- 둘 다 optional
- 빈 URL → Cloud Base URL 사용
- 빈 key → common Cloud API Key 사용
- `Clear` 동작 유지
- Standard와 Realtime transcription에만 적용
- Post-processing, Edit Mode, Context에는 적용하지 않음

현재 resolution rule을 그대로 사용한다 (`Sources/AppState.swift:2176-2184`).

### Native Whisper dropdown management

현재 `NativeWhisperModelCatalog.all`의 모든 model을 main Transcription dropdown의 Local section에 표시한다. 현재 catalog에는 recommended Native model 한 개가 있지만, 향후 Native model 추가 시 동일한 pending-management 흐름을 사용한다.

Installed Native model은 정상 selectable choice다. 미설치·partial·corrupt Native model도 dropdown에 보이지만 클릭 시 active choice를 변경하지 않고 contextual management 영역을 연다.

Dropdown 바로 아래의 management 영역은 현재 `NativeWhisperModelRowView`가 제공하는 모든 lifecycle 상태를 유지한다.

- model description 및 approximate size
- Download
- byte/progress display
- indeterminate/determinate progress
- hover/focus cancel
- canceled 상태와 다시 Download
- Installed
- delete confirmation
- Delete Model
- error message
- Settings가 닫힐 때 download cancel 및 partial file cleanup

별도 Transcription Details의 `Local Options` Native block은 제거한다. Native lifecycle UI는 dropdown 아래의 contextual management 영역에만 존재한다. 관리 영역은 radio/selection control을 표시하지 않는다.

#### Pending Native selection

`pendingNativeModelID`는 `ModelsSettingsView`의 view-local state다.

- 미설치 Native menu item 클릭 → pending ID 설정, active choice 유지
- installed Native menu item 클릭 → pending ID 설정 및 existing setter로 active choice 즉시 변경
- 다른 available choice 선택 → pending ID 제거
- Native 다운로드 중 다른 Settings tab으로 이동 → view-local pending ID는 사라지지만 AppState download는 계속됨
- Models tab 복귀 후 다운로드 중 Native item 클릭 → management 영역 다시 열림

다운로드 시작 시 pending Native model ID를 별도로 기억한다. completion에서 자동 선택하려면 다음 조건을 모두 만족해야 한다.

1. install result가 성공
2. management 영역이 같은 Native model을 계속 가리킴
3. 사용자가 그 사이 다른 Transcription choice를 선택하지 않음
4. Models tab이 여전히 active

하나라도 충족하지 않으면 install만 완료하고 current active choice를 유지한다.

Native model을 삭제했을 때 현재 선택이 unavailable해지면 기존 normalization/fallback을 실행한다. active가 아닌 Native model 삭제는 active choice를 변경하지 않는다.

### Legacy mlx-whisper

Legacy mlx-whisper는 이번 Native-only 통합 범위에서 변경하지 않는다. 기존 `showLegacyMlxWhisperOptions`, `useLegacyMlxWhisper`, 설치 상태와 `TranscriptionBackendChoice`를 그대로 표현한다. 이 상태의 의미를 재해석하거나 새 visibility preference를 추가하지 않는다.

`Manage Legacy models` disclosure는 기존 `showLegacyMlxWhisperOptions` binding을 사용한다.

- `localWhisperPath`
- Apple Speech를 제외한 현재 `TranscriptionModel.all` 전체
- 각 model의 Download / progress / Cancel / canceled retry / Installed / Delete / error 상태

설치된 Legacy 모델은 현재 availability와 선택 규칙에 따라 unified Transcription dropdown에 표현한다.

- download 완료 → 현재 목록과 선택 가능 상태를 갱신
- model 삭제 → dropdown에서 즉시 제거
- 현재 구현과 동일하게 어느 Legacy cache를 삭제하든 `onDeleted` callback으로 Native Whisper 선택을 시도함
- Native Whisper가 unavailable하면 기존 normalization/fallback order 사용
- management disclosure를 닫아도 현재 choice, 설치 cache, management preference를 변경하지 않음
- delete confirmation과 cache safety check 유지

Legacy를 실제로 선택하는 행위는 unified Transcription dropdown에서 수행한다. 현재 Legacy model catalog에서 Medium/Small을 포함한 어떤 model도 삭제하지 않는다.

새 Legacy menu visibility preference, key, migration은 Future work다.

### Audio import preservation

Realtime choice로 audio file을 import할 때 Standard API를 사용하는 현재 동작, Apple Live choice에서 available Local Whisper를 고르는 현재 동작을 유지한다 (`Sources/AppState.swift:1087-1128`).

## Post-processing

### Positive toggle, same state

행의 switch는 사용자 친화적인 positive label `Post-processing`을 사용하지만 저장값은 기존 `disablePostProcessing`의 inverse binding이다.

```swift
Binding(
    get: { !appState.disablePostProcessing },
    set: { appState.disablePostProcessing = !$0 }
)
```

별도 migration이나 중복 enable key를 만들지 않는다.

- Off → 일반 dictation은 raw transcript 사용
- Voice Macro는 현재처럼 Post-processing을 우회
- Edit Mode는 현재처럼 Post-processing toggle과 독립적으로 model service를 사용

이 순서를 유지한다 (`Sources/AppState.swift:5221-5247`).

현재 Post-processing model path는 common Cloud Provider만 사용한다. persisted common key가 없을 때는 다음 UI 규칙을 적용한다.

- switch를 비활성화하되 inverse binding이 나타내는 persisted On/Off 모양은 유지
- primary model dropdown 비활성화
- Details의 fallback model dropdown 비활성화
- Details 전체, Output Language, Preserve Exact Wording, Custom Vocabulary, prompt editor, Instruction Guard는 숨기거나 일괄 비활성화하지 않음
- System Prompt test의 기존 key-based 비활성화 유지
- API key 삭제 때문에 `disablePostProcessing`, primary/fallback model 또는 다른 option을 변경하지 않음

persisted toggle이 Off이면 다음 의미의 안내를 표시한다.

> Add an API key in Cloud Provider to enable Post-processing.

persisted toggle이 On이면 다음 의미의 안내를 표시한다.

> Post-processing is on, but cloud processing is unavailable until an API key is configured.

유효한 key가 다시 저장되면 기존 persisted On 상태대로 switch가 다시 조작 가능해진다. 향후 Local backend가 추가되면 선택된 backend의 readiness로 switch와 해당 model group을 판단하되, 이번 pass에서는 backend state나 routing을 추가하지 않는다.

### Primary and fallback model choices

Primary와 fallback은 기존 model string storage를 그대로 사용한다.

- `postProcessingModel`
- `postProcessingFallbackModel`

각 dropdown은 기존 Cloud model ID와 custom model ID를 보존한다. 기존 retry 조건, cooldown behavior, Cloud endpoint/key resolution은 바꾸지 않는다 (`Sources/PostProcessingService.swift:297-515`).

backend storage key, Local Server choice, cross-backend primary/fallback routing은 Future work다.

### Edit Mode dependency

Post-processing details에 다음 안내를 둔다.

> Edit Mode uses this primary model, fallback model, Output Language, and Custom Vocabulary. Invocation Style and Extra Modifier remain in Shortcuts.

중요한 UI 규칙:

- Post-processing이 Off이고 Edit Mode도 Off이면 model/details를 흐리게 표시하되 저장값은 유지한다.
- Post-processing이 Off여도 Edit Mode가 On이면 model, fallback, Output Language, Custom Vocabulary를 활성 상태로 유지한다.
- `customSystemPrompt`는 normal Post-processing에만 적용되고 Edit Mode의 command prompt를 대체하지 않는다.
- `Instruction Guard`는 현재처럼 normal Post-processing 결과에 적용하며 Edit Mode 의미로 확장하지 않는다 (`Sources/PostProcessingService.swift:647-652`).

### Output Language

`Output Language`는 Post-processing details의 **유일한 위치**다.

현재 option과 persisted value를 모두 유지한다.

- Same as spoken language (`""`)
- English
- Korean
- Japanese
- Chinese
- Spanish
- French
- German
- Portuguese

동작:

- normal Post-processing의 output language
- Preserve Exact Wording + language 지정 시 literal translation target
- Edit Mode command transform의 output language
- transcription backend와 독립

Local transcription이라는 이유로 비활성화하지 않는다. Post-processing과 Edit Mode가 모두 Off일 때만 현재 선택을 보존한 채 비활성 상태와 설명을 표시한다.

### Preserve Exact Wording

현재 의미를 그대로 유지한다.

- Off → normal system prompt cleanup
- On + Output Language 없음 → API call 없이 trimmed raw transcript
- On + Output Language 있음 → cleanup 없이 literal translation
- translation 실패 → raw transcript fallback

Post-processing이 Off이면 비활성화하되 저장값을 삭제하지 않는다 (`Sources/AppState.swift:5245-5266`).

### Custom Vocabulary

현재 editor, trim, comma/newline/semicolon 안내를 유지한다.

- normal Post-processing에 사용
- Edit Mode command transform에 사용
- custom system prompt와 독립

### System Prompt

현재의 모든 상태와 action을 한 disclosure 안에 유지한다.

- default/custom 상태
- custom editor
- `Using default` / `Using custom prompt`
- last-modified date
- newer default available notice
- `View Default` / `Hide`
- `Switch to Default`
- `Reset to Default`
- sample input
- `Test System Prompt`
- running/error/result
- `Full prompt sent` disclosure

테스트 readiness는 현재 Cloud Provider key와 기존 Post-processing model 경로 기준으로 판단한다. Local Server readiness는 Future work다.

### Instruction Guard

`Prevent dictated prompts from being executed` toggle과 현재 default-on 저장값을 유지한다. suspected instruction execution 시 retry/fallback/raw transcript로 돌아가는 현재 동작을 바꾸지 않는다.

## Context

### Positive toggle, same state

행의 switch는 `Context`를 사용하되 기존 `disableContextCapture`의 inverse binding이다.

```swift
Binding(
    get: { !appState.disableContextCapture },
    set: { appState.disableContextCapture = !$0 }
)
```

별도 enable key를 만들지 않는다.

Off이면 일반 dictation의 app metadata, screenshot capture, Context LLM inference를 현재처럼 건너뛰며 일반 Context Capture를 위한 Screen Recording permission이 필요하지 않다 (`Sources/AppState.swift:6294-6304`). Edit Mode의 selected-text snapshot과 Edit Mode가 별도로 요구하는 permission 경로는 이 toggle과 독립적으로 유지한다 (`Sources/AppState.swift:4387-4412`).

현재 Context model path는 common Cloud Provider를 사용한다. persisted common key가 없을 때는 다음 UI 규칙을 적용한다.

- switch를 비활성화하되 inverse binding이 나타내는 persisted On/Off 모양은 유지
- Context model dropdown 비활성화
- Context Prompt, Screenshot Resolution 및 Details 전체를 숨기거나 일괄 비활성화하지 않음
- Context Prompt test의 기존 key-based 비활성화 유지
- API key 삭제 때문에 `disableContextCapture`, `contextModel`, prompt 또는 screenshot resolution을 변경하지 않음

persisted toggle이 Off이면 다음 의미의 안내를 표시한다.

> Add an API key in Cloud Provider to enable Context.

persisted toggle이 On이면 다음 의미의 안내를 표시한다.

> Context is on, but AI context analysis is unavailable until an API key is configured.

`Context` 전체가 동작하지 않는다고 표현하지 않는다. runtime은 key가 없을 때도 현재의 app/window metadata와 non-LLM fallback context를 만들 수 있기 때문이다 (`Sources/AppContextService.swift:124-154`). 이번 UI pass는 그 fallback을 변경하지 않는다. 향후 Local backend가 추가되면 선택된 backend readiness로 switch와 model group을 판단한다.

### Model choice

- `contextModel` string을 그대로 유지한다.
- 기존 Cloud model ID와 custom model ID를 그대로 표시하고 선택한다.
- 기존 Cloud endpoint, screenshot-first/text-only retry, non-LLM fallback 순서를 유지한다 (`Sources/AppContextService.swift:117-204`).

`contextBackend` key, Local Server model, backend-aware readiness, capability 표시 변경은 Future work다.

### Context Prompt

현재의 모든 상태와 action을 유지한다.

- default/custom 상태
- custom editor
- last-modified date
- newer default available notice
- View/Hide Default
- Switch/Reset to Default
- Test Context Prompt
- frontmost app metadata와 screenshot capture
- running/error/result
- Full prompt sent

테스트 readiness는 현재 Cloud Provider key와 기존 Context model 경로에 따라 판단한다. backend-aware readiness는 Future work다.

### Screenshot Resolution

현재 option을 그대로 유지한다.

- 1024 px
- 768 px
- 640 px
- 512 px
- default/custom 상태
- Reset to Default

## Shortcuts > Clipboard delivery

현재 `Disable Auto Paste`를 삭제하지 않는다. model 설정과 독립적인 결과 전달 동작이므로 Models에서 제거하고 `Shortcuts > Clipboard`의 첫 옵션으로 이동한다.

positive UI label:

- `Paste Automatically`

저장값은 기존 `disableAutoPaste` inverse binding을 사용한다. Off이면 현재처럼 clipboard에만 복사하고 사용자가 직접 paste한다.

기존 Clipboard의 restore/history, `press enter` voice command는 Auto Paste 아래에 그대로 유지하며 동작을 변경하지 않는다.

## Future work — Runtime routing (not implemented in this UI pass)

### Future work — Endpoint resolution (not implemented in this UI pass)

```swift
struct LLMEndpointConfiguration: Equatable, Codable {
    var baseURL: String
    var apiKey: String
}

struct ResolvedLLMChoice: Equatable {
    var modelID: String
    var endpoint: LLMEndpointConfiguration
}

func endpoint(for backend: LLMBackend) -> LLMEndpointConfiguration {
    switch backend {
    case .cloud:
        return .init(baseURL: apiBaseURL, apiKey: apiKey)
    case .localServer:
        return .init(baseURL: localAIBaseURL, apiKey: localAIAPIKey)
    }
}
```

- Transcription routing은 기존 별도 경로 유지
- Post-processing primary/fallback은 각각 `ResolvedLLMChoice`로 resolve하고 각 choice endpoint를 사용
- Edit Mode는 Post-processing primary/fallback choice 공유
- Context는 Context choice endpoint 사용
- `LLMAPITransport`는 그대로 재사용
- Local Server key가 비어 있으면 Authorization header를 생략
- Cloud request는 현재 key gate와 Authorization header 구성을 유지
- Context는 `apiKey.isEmpty`가 아니라 selected backend readiness로 LLM inference 여부를 판단
- model-specific `ModelConfiguration.config(for:)`와 think-tag cleanup은 그대로 적용

### Future work — Cross-backend fallback and cooldown (not implemented in this UI pass)

현재 `LLMCooldownManager.effectivePrimary(baseURL:primary:fallback:)`는 두 model이 하나의 endpoint를 공유한다고 가정한다. primary/fallback이 서로 다른 backend를 선택할 수 있으므로 choice-aware API를 추가한다.

```swift
func effectiveChoice(
    primary: ResolvedLLMChoice,
    fallback: ResolvedLLMChoice?
) -> ResolvedLLMChoice?
```

각 cooldown identity는 현재와 동일하게 `normalized baseURL + normalized modelID`다. primary가 cooldown이면 fallback 자신의 endpoint identity를 검사한다. 실제 retry request도 선택된 fallback endpoint/key로 보낸다. 기존 same-endpoint Cloud/Cloud 동작과 persisted cooldown key 형식은 유지한다.

### Snapshot consistency across every invocation path

녹음 시작 또는 작업 시작 시 model choice와 resolved endpoint를 함께 snapshot하여 작업 도중 Settings 변경이 진행 중인 요청을 바꾸지 않게 한다.

반드시 포함할 경로:

- normal recording completion의 `PostProcessingService` construction
- Edit Mode transform
- audio import의 `AudioImportTaskConfiguration`
- history retry의 `RetrySnapshot` 및 service construction
- System Prompt test
- Context capture 및 Context Prompt test

`AudioImportTaskConfiguration`과 retry/recording snapshot에는 primary와 fallback의 backend/endpoint 정보가 모두 들어가야 한다. audio import나 history retry가 현재 global Cloud URL/key를 다시 읽어 Local choice를 잃어서는 안 된다.

`contextBackend`, `localAIBaseURL`, `localAIAPIKey`, `contextModel`, Cloud endpoint 값이 바뀌면 cached `contextService`를 재생성한다. endpoint 전환 직후 시작한 다음 Context capture는 새 configuration을 사용한다.

### Failure behavior preservation

- Standard/Realtime transcription availability 및 fallback order 유지
- Realtime 실패 시 file-based Standard API fallback 유지
- Post-processing 실패 시 raw transcript fallback 유지
- Preserve Exact Wording translation 실패 시 raw transcript fallback 유지
- Edit Mode 실패 시 selected text fallback 유지
- Context vision 실패 시 text-only retry, 이후 non-LLM fallback 유지
- rate-limit cooldown은 `baseURL + model` 단위의 현재 의미 유지

## Future work — Persistence and migration additions (not implemented in this UI pass)

### Existing properties and physical storage retained

기존 property와 실제 storage account/key를 rename하거나 삭제하지 않는다.

| AppState property | Existing physical storage |
|---|---|
| `apiKey` | `AppSettingsStorage`: `groq_api_key` |
| `apiBaseURL` | `AppSettingsStorage`: `api_base_url` |
| `transcriptionAPIURL` | `AppSettingsStorage`: `transcription_api_url` |
| `transcriptionAPIKey` | `AppSettingsStorage`: `transcription_api_key` |
| `transcriptionModel` | `UserDefaults`: `transcription_model` |
| `postProcessingModel` | `UserDefaults`: `post_processing_model` |
| `postProcessingFallbackModel` | `UserDefaults`: `post_processing_fallback_model` |
| `contextModel` | `UserDefaults`: `context_model` |
| Realtime / Local / Legacy / enablement / language / prompt / screenshot properties | 현재 `AppState`의 기존 `UserDefaults` keys 그대로 |

Cloud 및 Local credential은 동일한 `AppSettingsStorage` 정책을 사용한다. 이 저장소는 Application Support의 owner-only `.settings` 파일을 사용하므로, 새 Local credential도 임의로 `UserDefaults`에 넣지 않는다 (`Sources/KeychainStorage.swift:3-63`).

### New additive storage

`UserDefaults`:

- `show_realtime_transcription_option`
- `show_legacy_transcription_option`
- `post_processing_backend`
- `post_processing_fallback_backend`
- `context_backend`

`AppSettingsStorage`:

- `local_ai_base_url`
- `local_ai_api_key`

### Migration rules

1. backend key 없음 → Cloud
2. `show_realtime_transcription_option` key 없음 → true; 현재 Realtime 선택도 그대로 유지
3. `show_legacy_transcription_option` key 없음 → true; 현재 설치된 Legacy choice와 선택 가능성 유지
4. `showLegacyMlxWhisperOptions`와 `useLegacyMlxWhisper`는 기존 값을 그대로 유지하며 새 의미를 부여하지 않음
5. 이번 migration은 기존 `migrateModelStorageKeys()`와 `loadStoredContextModel()`이 수행하는 현재 정규화 외에 model string을 추가로 rewrite하지 않음
6. prompt, language, 기존 toggle, URL, key 값은 이번 migration 중 다시 쓰지 않음
7. migration은 idempotent하며 기존 migration guard pattern을 따른다

## Current-to-new 1:1 preservation map

| Current option / behavior | New location | Preservation rule |
|---|---|---|
| API Key secure input | Cloud Provider | same stored key, validation, clear behavior |
| API Base URL | Cloud Provider → Advanced | same default, custom value, reset |
| Post-Processing Model | Post-processing card | same model ID and existing Cloud path; selector disabled without common Cloud key |
| Post-Processing Fallback Model | Post-processing → Details | same model ID, existing Cloud path, and fallback conditions; selector disabled without common Cloud key |
| Context Model | Context card | same model ID and existing Cloud path; selector disabled without common Cloud key |
| Transcription Local/API mode | Transcription dropdown | same `TranscriptionBackendChoice` adapter |
| API Transcription Model | Transcription dropdown / Details | same predefined and Custom model IDs |
| Transcription Language | Transcription → Details | same options and persisted code |
| Transcription API URL | Transcription → Details → Provider Override | same optional fallback behavior |
| Transcription API Key | Transcription → Details → Provider Override | same optional fallback behavior |
| Realtime on/off | Transcription dropdown | existing `realtimeStreamingEnabled` and selected Realtime behavior preserved; no new availability key |
| Realtime model | Transcription → Details | empty remains Provider default |
| Apple Speech | Transcription dropdown | built-in, no download/delete |
| Native Whisper selection | Transcription dropdown | installed model selects immediately; unavailable model opens view-local pending management without changing active choice |
| Native download | Transcription dropdown → contextual management | preserved; selecting item alone does not start download |
| Native progress / cancel | Transcription dropdown → contextual management | preserved, keyboard accessibility included; survives model/tab navigation |
| Native canceled retry | Transcription dropdown → contextual management | preserved |
| Native installed state | Transcription dropdown / contextual management | preserved; completion auto-selects only while the same pending flow remains active |
| Native delete confirmation/delete/error | Transcription dropdown → contextual management | preserved |
| Settings-close native cancellation/partial cleanup | lifecycle | preserved |
| Show legacy mlx-whisper management | Transcription → Details | same key and management-visibility meaning; does not hide installed choices |
| Legacy model catalog | Transcription → Details | all existing models retained |
| Legacy binary path | Transcription → Details | same default/custom path |
| Legacy download/progress/cancel/retry | Transcription → Details | preserved per model |
| Legacy installed/delete/error | Transcription → Details | preserved per model |
| Installed Legacy dropdown entries | Transcription dropdown | existing availability and installed state preserved; the management toggle does not hide installed choices and no new visibility key is added |
| Delete selected Legacy fallback | Transcription routing | Native first, existing fallback order thereafter |
| Output Language | Post-processing → Details | one location; not tied to transcription backend |
| Disable Post-Processing | Post-processing card toggle | inverse binding and persisted visual value retained; disabled without common Cloud key |
| Preserve Exact Wording | Post-processing → Details | same raw/literal translation behavior |
| Disable Auto Paste | Shortcuts → Clipboard | inverse binding, same clipboard-only behavior |
| Disable Context Capture | Context card toggle | inverse binding and persisted visual value retained; disabled without common Cloud key; same fallback/permission behavior |
| Custom Vocabulary | Post-processing → Details | same editor and Post/Edit usage |
| Custom System Prompt editor | Post-processing → Details | same default/custom storage |
| System Prompt newer-default notice/actions | Post-processing → Details | preserved |
| Test System Prompt/result/full prompt | Post-processing → Details | preserved; existing Cloud readiness |
| Instruction Guard | Post-processing → Details | same default and post-processing-only behavior |
| Custom Context Prompt editor | Context → Details | same default/custom storage |
| Context Prompt newer-default notice/actions | Context → Details | preserved |
| Screenshot Resolution | Context → Details | same options/default/reset |
| Test Context Prompt/result/full prompt | Context → Details | preserved; existing Cloud readiness |
| Edit Mode provider/model dependency | Post-processing inline note | behavior unchanged; invocation controls remain in Shortcuts |
| Custom model string | every LLM/Cloud transcription dropdown | `Custom…` retained; never discard unknown IDs |

## Interaction and accessibility

- disclosure는 `DisclosureGroup` 또는 동일한 keyboard-accessible control 사용
- toggle, picker, download cancel, delete action에 accessibility label 제공
- 상태를 color만으로 표현하지 않고 icon + text 병행
- destructive model deletion은 현재와 같은 confirmation 유지
- download 중 Settings를 닫을 때의 취소 안내 유지
- focus 중인 custom field 값은 외부 state update로 덮어쓰지 않음
- validation, download, test 실행 중 즉시 status feedback 제공
- disabled Cloud control은 바로 아래에서 icon + text로 이유를 설명
- persisted On 상태가 readiness 부족으로 disabled여도 switch의 On 모양을 유지
- Reduce Motion 환경에서는 disclosure/layout 전환에 큰 slide motion을 사용하지 않음
- 모든 새 user-facing string은 기존 en/ko localization 체계를 따른다

## Implementation boundaries

현재 UI pass는 existing `AppState`와 runtime behavior를 재사용하며, 다음 영역으로만 구현 diff를 제한한다.

- `Sources/SettingsView.swift`
  - `ModelsSettingsView`를 Cloud Provider, Transcription, Post-processing, Context peer cards로 재배치
  - view-local common Cloud key readiness 계산
  - 기존 provider, feature section, disclosure, prompt/model view 재사용
  - switch 및 Cloud model selector에 readiness 기반 `.disabled(...)`와 inline reason 적용
- 기존 localization resources
  - 새 UI 문구의 en/ko localization
- UI tests
  - 모델 화면의 정보 구조, disclosure, 기존 state 표시, model management lifecycle 보존
- documentation
  - 이 보존표와 UI-only 경계의 유지

`Sources/AppState.swift`, services, cooldown manager, audio import/recording/retry configuration, persistence keys, migration, endpoint routing, backend-aware runtime readiness, and cross-backend fallback are not changed in this pass. They are Future work. Settings 진입 시 key를 재검증하는 network request도 추가하지 않는다.

## Verification matrix

### Upgrade preservation

기존 설정 fixture를 만든 뒤 새 버전을 시작해 모든 값이 같은지 검증한다.

- Cloud URL/key + transcription override
- Local/Cloud/Realtime/Apple/Native/Legacy active choice
- custom model IDs
- all toggles
- prompt values and last-modified dates
- language values
- installed model selection

### Current UI preservation combinations

최소 다음 기존 UI와 lifecycle 보존 조합을 검증한다.

1. Local Native transcription + Cloud Post-processing + Cloud Context
2. Apple Live + Post-processing Off + Context Off
3. Standard Cloud transcription override + common Cloud Post-processing
4. Realtime + Cloud Post-processing + Context
5. Legacy installed model + Cloud Post-processing
6. Post-processing Off + Edit Mode On
7. Preserve Exact Wording with no Output Language
8. Preserve Exact Wording with translation language
9. Context screenshot failure → 기존 text-only retry와 non-LLM fallback 설명이 유지됨
10. no common key + no transcription override → API transcription entries disabled, Local/installed Legacy entries remain selectable
11. no common key + transcription override key → API transcription entries remain selectable
12. Post-processing persisted Off + no common key → Off switch remains visible but disabled; enable-key explanation shown
13. Post-processing persisted On + key deleted → On switch remains visible but disabled; unavailable explanation shown; persisted state unchanged
14. Context persisted Off + no common key → Off switch remains visible but disabled; enable-key explanation shown
15. Context persisted On + key deleted → On switch remains visible but disabled; AI-analysis unavailable explanation shown; non-LLM fallback unchanged
16. common key validation failure while an older persisted key exists → older readiness and stored key remain unchanged

### Future work verification (not implemented in this UI pass)

- Standard Cloud transcription + Local Server Post-processing + Cloud Context
- Local Context endpoint failure → non-LLM fallback
- primary/fallback on different backends, 각 endpoint의 cooldown identity와 request 확인
- Local Server Post-processing으로 audio import
- Local Server Post-processing으로 history retry
- recording 중 Settings backend 변경 시 시작 시점 snapshot 유지
- keyless Local Server Context inference 및 Authorization header 생략
- Context backend/Local URL/key 변경 후 다음 capture가 새 service 사용

### Model management

- unavailable Native dropdown item click → active model unchanged → contextual Download UI shown
- Native Download → progress → 다른 model 선택 → download continues → completion installs without auto-selection
- Native Download → progress → 다른 Settings tab 이동 → download continues → returning and reselecting item restores progress UI
- Native Download → progress → same pending flow remains active → completion selects Native
- Native Cancel → retry → Installed → Delete
- Settings close during Native download cleans partial file
- each Legacy model Download → progress → Cancel → retry → Installed → dropdown entry
- deleting unselected Legacy removes dropdown entry and preserves current implementation's Native selection callback
- deleting selected Legacy applies fallback
- hiding Legacy management does not hide installed dropdown choices or change current selection
- unavailable Realtime/Apple choices with `System Default + System Audio`

### UI preservation audit

구현 PR에서 이 문서의 1:1 표 각 행을 다음 중 하나로 표시한다.

- `present and verified`
- `moved and verified`
- `not applicable` — 근거 필수

누락 행이 하나라도 있으면 구현 완료로 간주하지 않는다.

## Acceptance criteria

- Models 화면은 Cloud Provider, Transcription, Post-processing, Context의 네 peer card로 구성되며 `AI Models` 통합 카드를 사용하지 않는다.
- Transcription은 항상 켜져 있고 하나의 dropdown에서 현재 지원되는 method/model을 선택한다.
- API key가 없어도 Transcription dropdown은 유지되며 API entries만 비활성화되고 Local/installed Legacy entries는 계속 선택 가능하다.
- Post-processing과 Context는 common Cloud key가 구성됐을 때 직접 켜고 끌 수 있다.
- common Cloud key가 없으면 Post-processing/Context switch와 Cloud model selector가 비활성화되고 control 바로 아래에 이유가 표시된다.
- key 삭제 전 persisted On인 switch는 On 모양을 유지한 채 비활성화되며 저장값을 자동으로 Off로 바꾸지 않는다.
- 모든 model choice는 dropdown이며 custom model ID를 계속 지원한다.
- 모든 현재 옵션과 모델 관리 action이 새 UI에 존재한다.
- Local transcription은 기존 Cloud Post-processing, Context, Edit Mode 설정을 막지 않는다.
- Output Language는 단 한 곳에 있고 transcription backend 때문에 비활성화되지 않는다.
- Realtime과 Legacy는 기존 `realtimeStreamingEnabled`, `showLegacyMlxWhisperOptions`, 설치 상태, availability 규칙을 보존한 채 Transcription dropdown에 나타난다.
- Legacy dropdown에는 설치된 model만 나타난다.
- 모든 Native catalog model이 Transcription dropdown에 나타나며, unavailable Native 선택은 active model을 바꾸지 않고 dropdown 아래 contextual lifecycle UI를 연다.
- Native 다운로드는 다른 model 또는 Settings tab으로 이동해도 계속되며, Settings window를 닫을 때만 기존처럼 취소된다.
- Native/Legacy 다운로드, 취소, 설치, 삭제, fallback이 유지되며, Legacy 관리 구조는 이번 Native-only 통합에서 변경하지 않는다.
- 기존 설정으로 업그레이드했을 때 사용자의 active behavior가 바뀌지 않는다.
- 기존 Cloud 사용자는 추가 설정 없이 이전과 동일하게 동작한다.
- Cloud Provider status는 persisted key presence와 현재 Save validation 상태만 표현하며 Settings 진입 시 상시 재검증하지 않는다.
- Context의 keyless app/window metadata 및 non-LLM fallback runtime은 그대로 유지한다.
- 구현 diff는 Settings UI, localization, tests, documentation으로 제한된다.
- 기존 runtime 및 persistence 파일은 변경되지 않는다.
