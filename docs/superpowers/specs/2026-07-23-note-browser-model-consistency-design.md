# Note Browser 모델 상태 일관성 후속 설계

## 목표

Note Browser와 Models Settings가 전사 켜짐 여부, 오디오 소스 호환성, Provider 준비 상태, 미설치 모델의 임시 선택을 일관되게 표현하도록 정리한다. 기존 상태 구조를 재사용하고 새로운 영구 저장 스키마는 추가하지 않는다.

## 1. 오디오만 노트의 목록 표시

기존 목록 행의 `시간 → 제목 → 내용` 3줄 구조와 고정 높이는 유지한다.

- `오디오만` 배지를 제목 아래 별도 줄에서 제거하고 시간 바로 오른쪽에 같은 기준선으로 배치한다.
- 배지는 시간 텍스트에 어울리는 작은 캡슐 크기를 사용한다.
- 오디오만 노트의 파란 상태 점은 정상 완료 노트와 같은 녹색으로 변경한다.
- `Not transcribed` 내용은 유지하여 색상이나 배지에만 의미를 의존하지 않는다.

예상 배치:

```text
시간  [오디오만]                              ●
제목
내용
```

## 2. Note Browser 전사 모델 드롭다운

전사 켜짐 여부와 기억된 모델을 하나의 드롭다운에서 제어한다.

- 첫 항목으로 `끔`을 제공한다.
- `끔`을 선택하면 `transcriptionEnabled`를 `false`로 바꾸고 마지막 모델 선택은 보존한다.
- 다른 모델을 선택하면 해당 backend를 적용하고 `transcriptionEnabled`를 `true`로 바꾼다.
- Settings에서 전사를 끄면 Note Browser도 `끔`으로 표시한다.
- Settings에서 전사를 다시 켤 때 마지막으로 기억한 모델이 ready면 복원하고, ready가 아니면 `끔`을 유지한다.
- 녹음이나 전사가 진행 중일 때는 현재처럼 드롭다운을 비활성화한다.
- Settings에서는 설정과 다운로드를 위해 Cloud/API 및 미설치 Local 모델의 selectability를 유지한다.
- Note Browser에서는 실행 readiness를 기준으로 API key가 설정된 Cloud 모델과 설치된 호환 Local 모델만 선택할 수 있다. `TranscriptionChoiceDisplay.isAvailable`(오디오 소스 capability)이 아니라 `isNoteBrowserTranscriptionChoiceReady`(capability + Provider/설치 readiness)로 항목을 비활성화하며, `setNoteBrowserTranscriptionSelection`도 unready choice 요청을 무시한다.

## 7. Settings 임시 draft와 외부 active 상태 분리

Settings 안에서 On/Off를 켜거나 아직 준비되지 않은 모델(미설치 Local, key 없는 Cloud)을 임시로 선택하는 것은 `ModelsSettingsView`의 로컬 draft 상태(`transcriptionEnabledDraft`, `transcriptionChoiceDraft`, `postProcessingEnabledDraft`, `postProcessingChoiceDraft`, `contextEnabledDraft`, `contextChoiceDraft`)에만 반영한다.

- Settings 화면 안에서는 ready 모델이 하나도 없어도 토글을 임시로 켜고 임의의 모델을 선택할 수 있다.
- 이 임시 상태는 그 자체로 Note Browser나 실제 녹음/처리 설정에 반영되지 않는다.
- `ModelsSettingsView`가 사라질 때(`onDisappear`, 곧 다른 탭 이동과 Settings 종료 모두 포함) `AppState.commitModelSettingsDrafts(...)`를 호출해 draft를 한 번에 커밋한다.
  - draft가 켜져 있고 draft 모델(또는 이전 active 모델)이 ready면 그 모델로 켠다.
  - ready 모델이 하나도 없으면 실제 설정은 꺼짐을 유지한다(Transcription은 `끔`, Post-processing/Context는 disable).
  - Note Browser에 표시되는 전사 선택은 커밋 이전에는 항상 이전 ready active 모델(또는 `끔`)을 그대로 유지한다.
- 진행 중인 Local AI 다운로드와 remembered choice는 커밋 시에도 그대로 보존한다.

## 8. 꺼진 섹션의 균일한 표시

세 섹션(Transcription, Post-processing, Context) 모두 같은 규칙으로 꺼진 상태를 표시한다.

- 섹션이 꺼져 있으면 모델 picker, 관리 행, `Details` 세부 설정을 모두 `.disabled` + 흐림 처리한다.
- 섹션이 꺼져 있는 동안에는 Provider(API key) 경고를 표시하지 않는다. 예: "후처리를 활성화하려면 클라우드 공급자에서 API Key를 추가하세요." 문구는 섹션이 켜져 있고 Cloud를 사용 중이며 key가 없을 때만 보여준다.
- 섹션이 켜져 있고 Cloud를 사용 중인데 key가 없을 때만 "기능은 켜져 있지만 key가 없어 사용할 수 없다"는 경고를 표시한다.

## 9. Settings draft와 실제 상태의 즉시 동기화

Draft는 "선택 표시"만 담당하고, 다음 두 경우는 Models 탭 이탈을 기다리지 않고 즉시 실제 상태에 반영한다.

- 토글을 끄면 즉시 `transcriptionEnabled = false` / `disablePostProcessing = true` / `disableContextCapture = true`를 적용한다.
- 토글을 켜거나 모델을 선택할 때 결과 choice가 ready면 즉시 실제 active choice와 활성화 플래그를 적용한다. ready가 아니면 draft만 갱신하고 실제 상태는 바꾸지 않는다.

또한 Settings가 열려 있는 동안 외부에서(Note Browser 선택, 다른 경로의 readiness 변화 등) 실제 상태가 바뀌면 `onChange`로 draft를 즉시 재동기화해 Settings 화면이 항상 최신 실제 상태를 보여주도록 한다.

## 10. 오디오 입력 변경 시 readiness 기반 자동 전사 정규화

`Apple Live`처럼 혼합 오디오 소스에서 사용할 수 없게 된 선택을 자동으로 다른 모델로 넘기는 기존 정규화는 capability(선택 가능 여부)만 확인했다. 그 결과 API key가 없는 API Standard로 자동 전환되어 실제로는 쓸 수 없는 모델이 활성 선택처럼 보이는 문제가 있었다.

- 오디오 입력 변경, Provider 설정 변경 등으로 트리거되는 자동 정규화는 이제 fallback 후보 중 readiness(capability + Provider/설치 준비 상태)를 만족하는 모델만 적용한다.
- ready한 fallback이 없으면 모델을 바꾸지 않고 `transcriptionEnabled`를 꺼서 Note Browser가 `끔`으로 보이게 한다.
- remembered backend(예: Apple Live)는 그대로 보존되어 나중에 다시 사용 가능한 소스로 돌아오면 복원할 수 있다.

## 3. 오디오 소스별 모델 호환성

Settings와 Note Browser는 동일한 오디오 소스 capability 판단을 사용한다.

### `System Default + System Audio`

녹음 종료 후 파일 전사가 가능한 모델은 선택할 수 있다.

- API Standard
- 설치된 Native Whisper
- 설치된 Legacy mlx-whisper

실시간 혼합을 지원하지 않는 모델은 목록에 표시하되 비활성화한다.

- API Realtime
- Apple Live

두 화면에서 동일하게 `현재 오디오 소스에서는 사용할 수 없음` 이유를 표시한다. Settings의 `Show Realtime transcription option`이 꺼져 있으면 API Realtime은 기존처럼 숨기고, 켜져 있을 때만 비활성화 상태로 표시한다. Apple Live는 항상 표시하되 혼합 소스에서 비활성화한다.

미설치 Local Whisper는 Settings에서 다운로드 준비를 위해 선택할 수 있지만 Note Browser에서는 설치 전까지 선택할 수 없다. 이는 오디오 호환성이 아니라 설치 readiness 차이로 취급한다.

순수 `System Audio` 단일 소스에는 이 혼합 소스 제한을 적용하지 않는다.

### 소스 변경 시 선택 정규화

Realtime 또는 Apple Live가 선택된 상태에서 `System Default + System Audio`로 변경하면:

1. 설치된 호환 Local Whisper가 있으면 해당 모델로 자동 전환한다.
2. 없으면 API Standard로 전환한다.
3. Settings와 Note Browser가 즉시 같은 선택을 표시한다.

## 4. Provider 설정 액션

Models Settings 내부의 `제공자 설정 열기` 버튼은 제거한다. 현재 구현은 이미 열린 Models 탭을 다시 활성화할 뿐이어서 화면 내에서는 실질적인 동작이 없다.

- Transcription, Post-processing, Context의 Provider 경고 문구는 유지한다.
- System Prompt와 Context Prompt 테스트의 Provider 오류도 안내 내용은 유지하되 Models Settings 내부 이동 버튼은 표시하지 않는다.
- Note Browser의 명시적인 recovery action, 오디오 가져오기, 녹음 시작 전 경고 등 Settings 외부에서는 기존 `Open Provider Settings` 액션을 유지한다.
- 오디오 노트의 재전사 버튼은 ready 모델이 없을 때 Settings를 자동으로 열지 않고 기존 Note Browser 토스트로 설정 필요성을 안내한다.

## 5. 다운로드 전 임시 모델 선택 초기화

미설치 모델을 선택했지만 다운로드를 시작하지 않은 상태는 Settings 화면 세션에만 유효한 임시 선택으로 취급한다.

- Transcription의 현재 동작을 정본으로 삼아 세 기능에 같은 lifecycle을 적용한다.
- Models 탭에 머무는 동안에는 다운로드 전 임시 선택과 다운로드 행을 유지한다.
- 다른 Settings 탭으로 이동하면 Models view가 사라질 때 다운로드 전 임시 선택을 폐기한다.
- Settings 창을 닫아도 다운로드 전 임시 선택을 폐기한다.
- Models 탭으로 돌아오거나 Settings를 다시 열면 다운로드 행을 복원하지 않고 변경 전 실제 활성 모델을 표시한다.
- `기본값`은 공장 초기 모델이 아니라 임시 선택 전 실제 활성 모델을 뜻한다.
- 다운로드를 이미 시작한 경우에는 이 규칙을 적용하지 않는다. 다운로드 task와 진행 상태는 현재처럼 계속 유지한다.
- 완료, 취소, 실패 후 상태 정리는 기존 lifecycle을 유지한다.

## 6. Models 탭 이탈 시 readiness 정합화

Models 탭을 벗어나거나 Settings 창을 닫을 때 세 기능을 같은 규칙으로 정리한다.

- 현재 active 모델이 ready면 그대로 유지한다.
- 현재 모델이 ready가 아니고 다른 ready 모델이 있으면 해당 모델로 fallback한다.
- ready 모델이 하나도 없으면 Transcription, Post-processing 또는 Context의 해당 기능을 끈다.
- remembered backend와 진행 중인 다운로드는 유지한다.
- Post-processing과 Context가 꺼져 있으면 Transcription과 동일하게 모델 선택, 관리 행, 세부 설정을 비활성화하고 흐리게 표시한다.

## 상태 경계

- `transcriptionEnabled`: 전사 켜짐 또는 꺼짐
- remembered backend: 전사가 꺼져 있을 때도 유지되는 마지막 모델
- capability: 현재 오디오 소스에서 모델을 사용할 수 있는지 여부
- readiness: Local 모델 설치와 Cloud API key가 실행 준비됐는지 여부
- pending selection: 다운로드를 시작하기 전 Settings 화면의 일시적인 선택
- download state: 실제로 시작된 다운로드 task와 진행률

각 상태를 서로 대신 사용하지 않고 UI가 필요한 상태를 조합해 표시한다.

## 검증 범위

빠른 반영을 위해 변경 지점 중심의 코드 검증만 수행한다.

1. 오디오만 목록 행의 배지 위치 계약과 녹색 상태 테스트
2. `끔` 선택 및 모델 선택에 따른 `transcriptionEnabled` 변경 테스트
3. 전사를 껐다 켰을 때 remembered backend 유지 테스트
4. 혼합 오디오 소스에서 공통 모델 capability와 자동 fallback 테스트
5. Models Settings 내부 Provider 액션 제거 계약 테스트
6. Post-processing과 Context의 다운로드 전 임시 선택이 Models 탭 이탈과 Settings 종료 시 초기화되는 테스트
7. 다운로드를 시작한 상태는 탭 이동과 Settings 종료 후에도 유지되는 회귀 테스트
8. Models 탭 이탈 시 ready fallback 또는 feature off 정합화 테스트
9. 꺼진 Post-processing과 Context 설정 영역의 비활성화 계약 테스트
10. ready 전사 모델이 없는 재전사 버튼의 toast 계약 테스트
11. 관련 테스트 실행, 앱 컴파일, `git diff --check`

`Quill Dev` 실행, 수동 UI 확인, GUI 자동화와 반복적인 전체 테스트는 수행하지 않는다.

## 비범위

- 새로운 모델 선택 persistence schema
- 오디오 소스별 별도 remembered model 저장
- 독립 Cloud Provider Settings 탭 또는 스크롤 anchor
- 다운로드 lifecycle 재설계
- 순수 `System Audio`의 기존 Live transcription 정책 변경
- Post-processing의 `Same as spoken language` prompt 처리 변경
