# Legacy mlx-whisper 모델 선택권 노출 분리 설계

## 배경

현재 Settings의 `Advanced Legacy mlx-whisper` 영역에서 `Use legacy mlx-whisper` 토글은 두 가지 의미를 동시에 갖는다.

1. legacy mlx-whisper 모델 선택지를 Settings에 노출할지 결정한다.
2. 실제 전사 실행 시 `legacy mlx_whisper` 경로를 사용할지 결정한다.

이 때문에 사용자가 “레거시 모델을 선택할 수 있게 해두고 싶다”는 의미로 토글을 켜면, 앱은 즉시 legacy 엔진을 사용하는 상태가 된다. 반대로 Native Whisper나 Apple Speech 같은 다른 모델을 선택하면 `useLegacyMlxWhisper`가 꺼지면서 legacy 모델 선택권도 함께 사라진다.

사용자가 원하는 동작은 토글이 실제 엔진 강제 사용이 아니라, legacy 모델 선택권을 계속 노출하는 조건으로 동작하는 것이다.

## 목표

- `Use legacy mlx-whisper` 토글의 UI 문구는 유지한다.
- 토글은 legacy 모델 선택권 노출 여부를 제어한다.
- 실제 legacy 엔진 사용 여부는 사용자가 legacy 모델 행을 선택했을 때만 켜진다.
- 다른 로컬 모델을 선택해도 legacy 모델 선택권 노출 상태는 유지된다.
- 기존에 legacy mlx-whisper를 사용하던 사용자는 업데이트 후에도 legacy 선택 영역을 계속 볼 수 있어야 한다.

## 비목표

- legacy mlx-whisper 실행 방식 자체를 바꾸지 않는다.
- Native Whisper 설치/다운로드 흐름을 바꾸지 않는다.
- 모델 목록 디자인을 대폭 재구성하지 않는다.
- `Use legacy mlx-whisper` 표시 문구를 이번 변경에서 바꾸지 않는다.

## 설계

### 상태 분리

`AppState`에 새 설정 상태를 추가한다.

- 기존 `useLegacyMlxWhisper`
  - 의미: 실제 전사 시 legacy mlx-whisper 엔진을 사용할지 여부
  - 기존 전사 실행 경로와 호환성을 위해 의미를 유지한다.

- 새 `showLegacyMlxWhisperOptions`
  - 의미: Settings에서 legacy mlx-whisper 모델 선택권과 경로 입력 UI를 활성화할지 여부
  - 별도 `UserDefaults` key에 저장한다.

초기화 규칙은 다음과 같다.

1. 저장된 `showLegacyMlxWhisperOptions` 값이 있으면 그 값을 사용한다.
2. 저장된 값이 없고 기존 `useLegacyMlxWhisper`가 true이면 true로 시작한다.
3. 그 외에는 false로 시작한다.

이 규칙으로 기존 legacy 사용자는 선택 영역을 잃지 않고, 새 사용자나 legacy를 쓰지 않던 사용자의 기본 동작은 바뀌지 않는다.

### Settings UI 동작

`SettingsView.localTranscriptionSettings`의 `Advanced Legacy mlx-whisper` 영역을 다음처럼 조정한다.

- `Use legacy mlx-whisper` 토글은 `appState.showLegacyMlxWhisperOptions`에 바인딩한다.
- legacy 모델 행의 `disabled`와 `opacity` 조건도 `showLegacyMlxWhisperOptions`를 따른다.
- legacy 모델 행의 선택 상태는 계속 `appState.useLegacyMlxWhisper && appState.localTranscriptionModel.id == model.id`로 판단한다.

모델 선택 시 상태 변경 규칙은 다음과 같다.

- Apple Speech 선택
  - `localTranscriptionModel = apple-speech`
  - `useLegacyMlxWhisper = false`
  - `showLegacyMlxWhisperOptions`는 변경하지 않는다.

- Native Whisper 선택
  - `useLocalTranscription = true`
  - `localTranscriptionModel = mlx-community/whisper-large-v3-turbo`
  - `useLegacyMlxWhisper = false`
  - `showLegacyMlxWhisperOptions`는 변경하지 않는다.

- legacy 모델 선택
  - `useLocalTranscription = true`
  - `useLegacyMlxWhisper = true`
  - `showLegacyMlxWhisperOptions = true`
  - `localTranscriptionModel = 선택한 legacy 모델`

- legacy 모델 삭제 처리
  - `localTranscriptionModel`은 Native Whisper 추천 모델로 되돌린다.
  - 삭제만으로 `showLegacyMlxWhisperOptions`를 끄지 않는다.
  - 필요한 경우 실제 legacy 선택은 해제되도록 `useLegacyMlxWhisper = false`를 함께 보정한다.

### 전사 실행 경로

`TranscriptionService`의 실행 분기는 변경하지 않는다.

- `localTranscriptionModel.isAppleSpeech`이면 Apple Speech를 사용한다.
- 그렇지 않고 `useLegacyMlxWhisper`가 true이면 legacy `mlx_whisper`를 사용한다.
- 그렇지 않으면 Native Whisper를 사용한다.

즉, `showLegacyMlxWhisperOptions`가 true여도 사용자가 legacy 모델을 선택하지 않았다면 legacy 엔진은 실행되지 않는다.

### 테스트

회귀를 막기 위해 상태 분리 중심 테스트를 추가하거나 기존 `AppStateTranscriptionConfigurationTests`에 보강한다.

검증할 동작은 다음과 같다.

1. Native Whisper 선택은 `useLegacyMlxWhisper`를 false로 만들지만 `showLegacyMlxWhisperOptions`는 유지한다.
2. Apple Speech 선택도 `showLegacyMlxWhisperOptions`를 유지한다.
3. legacy 모델 선택은 `useLegacyMlxWhisper`와 `showLegacyMlxWhisperOptions`를 모두 true로 만든다.
4. 저장된 표시 설정이 없을 때 기존 `use_legacy_mlx_whisper = true`이면 `showLegacyMlxWhisperOptions`가 true로 초기화된다.
5. 전사 실행 경로는 계속 `useLegacyMlxWhisper`에만 의존하고, `showLegacyMlxWhisperOptions`만으로 legacy 엔진을 실행하지 않는다.

## 예상 파일 변경

- `Sources/AppState.swift`
  - `showLegacyMlxWhisperOptions` 저장 key 추가
  - `@Published var showLegacyMlxWhisperOptions` 추가
  - 초기화에서 기존 `useLegacyMlxWhisper` 기반 fallback 적용

- `Sources/SettingsView.swift`
  - `Use legacy mlx-whisper` 토글 바인딩 변경
  - legacy 모델 행의 활성화 조건 변경
  - Apple Speech, Native Whisper, legacy 모델 선택 핸들러의 상태 갱신 규칙 정리

- `Tests/AppStateTranscriptionConfigurationTests.swift`
  - 상태 분리 회귀 테스트 추가

## 성공 기준

- 사용자가 `Use legacy mlx-whisper`를 체크한 뒤 Native Whisper를 선택해도 legacy 모델 선택권이 계속 노출된다.
- 단순히 토글을 체크했다는 이유만으로 legacy 엔진이 실제 전사에 사용되지 않는다.
- legacy 모델 행을 선택했을 때만 `useLegacyMlxWhisper`가 true가 된다.
- 기존 legacy 사용자는 업데이트 후에도 legacy 설정 UI를 볼 수 있다.
- 관련 테스트가 통과한다.
