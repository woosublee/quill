# 전사 방식 정규화 재진입 크래시 수정 설계

## 배경

Quill v0.1.20부터 전사 backend 선택을 구체적인 `TranscriptionBackendChoice`로 정규화하는 흐름이 도입됐다. 다음 저장 상태를 가진 프로덕션 Quill v0.1.22는 시작할 때 반복적으로 `SIGSEGV`로 종료된다.

- `selected_microphone_id = __system_default_and_system_audio__`
- `local_transcription_model = apple-speech`
- `use_legacy_mlx_whisper = false`
- Native Whisper 모델 설치 완료

`System Default + System Audio`에서는 Apple Live를 사용할 수 없으므로 정규화는 Native Whisper를 fallback으로 고른다. Native Whisper를 적용하는 도중 `useLegacyMlxWhisper = false`가 실행되고, 값이 이미 `false`여도 `didSet`이 동기식 정규화를 다시 호출한다. 아직 `localTranscriptionModel`은 `apple-speech`라 같은 fallback을 다시 선택하며 무한 재진입한다. 스택이 누적된 뒤 `TranscriptionModel.isInstalled`의 URL 처리 중 `EXC_BAD_ACCESS`가 발생하지만, URL 처리는 원인이 아니라 재귀의 마지막 관찰 지점이다.

## 목표

1. 전사 선택 정규화와 선택 적용이 서로를 재귀 호출하지 않게 한다.
2. 하나의 전사 선택을 여러 저장 속성으로 반영하는 동안 중간 상태가 다시 정규화되지 않게 한다.
3. 실제로 값이 변경되는 속성만 갱신해 불필요한 `didSet`, 저장, publish를 줄인다.
4. API key, 오디오 입력, 모델 설치 상태처럼 외부 가용성 조건이 바뀔 때의 기존 fallback 동작은 유지한다.
5. 프로덕션 크래시 조건을 자동화된 회귀 테스트와 실제 GUI 실행으로 검증한다.

## 비목표

- 전사 관련 Bool과 모델 속성을 새로운 단일 상태 타입으로 전면 교체하지 않는다.
- `AppState` 전체를 리팩터링하지 않는다.
- fallback 우선순위나 사용자에게 보이는 전사 선택 UI를 변경하지 않는다.
- Native Whisper 또는 legacy mlx-whisper의 설치·실행 방식을 변경하지 않는다.
- Gatekeeper, notarization, quarantine 문제는 이번 수정 범위에 포함하지 않는다.

## 접근 대안

### 대안 A: 동일 값 대입만 건너뛰기

`useLegacyMlxWhisper`가 이미 목표 값이면 대입하지 않는다. 현재 크래시는 막을 수 있지만 다른 속성의 `didSet`이 정규화를 호출하게 되면 같은 문제가 재발할 수 있고, 여러 속성을 적용하는 중간 상태가 외부에 노출되는 구조가 남는다.

### 대안 B: 정규화 재진입 플래그만 추가하기

정규화 중이면 중첩 정규화를 무시한다. 직접적인 재귀는 막지만 상태 적용 코드가 동일 값까지 계속 대입하고, 정규화와 상태 적용의 책임이 여전히 결합된다.

### 선택안: 원자적 선택 적용 경계 + 재진입 차단 + 변경 시에만 대입

전사 선택 적용을 하나의 작은 트랜잭션으로 취급한다. 적용 시작부터 모든 관련 속성 반영이 끝날 때까지 정규화를 재시작하지 않고, 각 속성은 현재 값과 목표 값이 다를 때만 변경한다. 이 방식은 현재 크래시뿐 아니라 Native Whisper, legacy mlx-whisper, Apple Live 사이의 같은 유형의 재진입을 방지하면서 변경 범위를 `AppState`의 전사 선택 흐름으로 제한한다.

## 상세 설계

### 1. 전사 선택 적용 상태

`AppState`에 전사 선택 적용 중임을 나타내는 private Bool을 추가한다.

```swift
private var isApplyingNoteBrowserTranscriptionChoice = false
```

이 값은 `@Published`가 아니며 영속화하지 않는다. 오직 내부 상태 전환의 재진입을 차단하는 데 사용한다.

### 2. 외부 정규화 요청과 내부 적용 분리

`scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration()`과 선택 입력용 정규화 요청은 외부 조건 변경에 대한 진입점으로 유지한다.

두 진입점은 다음 조건에서는 정규화를 실행하지 않는다.

- 전사 선택을 적용 중인 경우
- provider 설정 정규화에서 기존처럼 녹음 또는 전사 중인 경우

따라서 API key, 선택 오디오 입력, Native Whisper 설치 상태가 외부에서 바뀌면 정규화가 동작하지만, 정규화가 스스로 만든 속성 변경은 다시 정규화를 시작하지 않는다.

### 3. 목표 상태 계산 후 원자적으로 적용

`applyNoteBrowserTranscriptionChoice(_:)`는 먼저 선택에 따른 목표 속성 값을 결정한 뒤 적용 경계를 연다.

적용 원칙:

1. `isApplyingNoteBrowserTranscriptionChoice`가 이미 true라면 중첩 적용을 시작하지 않는다.
2. true로 설정한 뒤 `defer`에서 반드시 false로 되돌린다.
3. 각 속성은 현재 값과 목표 값이 다를 때만 대입한다.
4. backend를 식별하는 모델과 legacy flag가 중간 상태에서 오해되지 않도록 일관된 순서로 변경한다.
5. 기존 fallback 우선순위와 최종 속성 값은 유지한다.

Native Whisper 적용의 목표 상태는 다음과 같다.

- `useLocalTranscription = true`
- `realtimeStreamingEnabled = false`
- `localTranscriptionModel = nativeLocalWhisperSelectionModel`
- `useLegacyMlxWhisper = false`

모델을 먼저 Native Whisper 선택 모델로 맞춘 뒤 legacy flag를 끄면, 방어 경계 밖에서 관찰되더라도 `apple-speech + legacy false`라는 이전 중간 상태를 오래 유지하지 않는다. 다만 정확성은 적용 순서에만 의존하지 않고 재진입 경계로 보장한다.

Legacy mlx-whisper 적용의 목표 상태는 다음과 같다.

- `useLocalTranscription = true`
- `realtimeStreamingEnabled = false`
- `localTranscriptionModel = 선택한 legacy model`
- `useLegacyMlxWhisper = true`
- `showLegacyMlxWhisperOptions = true`

Apple Live와 API 선택도 같은 변경 시 대입 원칙을 사용한다.

### 4. `useLegacyMlxWhisper.didSet`

영속화 동작은 유지한다. 정규화 요청은 다음 두 조건을 모두 만족할 때만 수행한다.

- `oldValue != useLegacyMlxWhisper`
- 전사 선택을 적용 중이 아님

동일 값 대입으로 인한 불필요한 정규화를 제거하지만, 이것만을 크래시 방지의 유일한 장치로 삼지는 않는다. 적용 경계가 구조적 안전장치다.

### 5. Settings도 공통 전환 경로 사용

Settings에서 Apple Live, Native Whisper, legacy mlx-whisper를 선택하거나 legacy 모델 삭제 후 fallback할 때 여러 속성을 직접 순서대로 변경하지 않는다. 모든 선택은 `setNoteBrowserTranscriptionChoice(_:)`를 호출해 동일한 원자적 적용 경계를 사용한다. 이를 통해 첫 번째 속성의 `didSet`이 나머지 상태가 반영되기 전에 정규화를 시작하는 문제를 방지한다.

### 6. Native Whisper 설치 상태 테스트 주입

회귀 테스트가 실제 1.6GB 모델 파일에 의존하지 않도록 `AppState`에서 Native Whisper 설치 상태를 읽는 작은 주입 지점을 둔다. 기본 구현은 기존과 동일하게 `NativeWhisperModelStore().installStatus(for: .recommended)`를 호출한다. 테스트는 이를 `.ready`를 반환하는 함수로 잠시 교체하고, `defer`에서 원래 구현을 복원한다.

이 주입 지점은 테스트 가능성을 위한 것이며 프로덕션 동작을 변경하지 않는다.

## 상태 흐름

```text
외부 조건 변경
  ├─ API key 변경
  ├─ 오디오 입력 변경
  └─ 모델 설치 상태 변경
        ↓
현재 선택의 가용성 검사
        ↓
필요한 경우 fallback 선택 결정
        ↓
전사 선택 적용 경계 시작
        ↓
변경된 속성만 일관된 순서로 적용
        ↓
didSet은 저장하되 중첩 정규화 생략
        ↓
적용 경계 종료
        ↓
최종 currentNoteBrowserTranscriptionChoice가 목표 선택과 일치
```

fallback이 없으면 기존처럼 현재 선택을 보존한다. 녹음 또는 전사 중 provider 설정이 바뀌면 기존처럼 즉시 정규화하지 않는다.

## 테스트 설계

### 신규 핵심 회귀 테스트

프로덕션 크래시 조건을 그대로 구성한다.

- `selected_microphone_id = __system_default_and_system_audio__`
- `use_local_transcription = true`
- `local_transcription_model = apple-speech`
- `use_legacy_mlx_whisper = false`
- Native Whisper 설치 상태 주입값 `.ready`

`AppState()` 초기화가 반환되는지 확인하고 다음 최종 상태를 검증한다.

- `currentNoteBrowserTranscriptionChoice`가 Native Whisper
- `useLocalTranscription == true`
- `realtimeStreamingEnabled == false`
- `useLegacyMlxWhisper == false`
- `localTranscriptionModel == nativeLocalWhisperSelectionModel`
- 저장된 설정도 최종 상태와 일치

기존 구현에서는 이 테스트가 초기화 중 무한 재귀로 실패해야 한다.

### 추가 상태 전환 테스트

- 같은 Native Whisper 선택을 다시 적용해도 상태가 안정적으로 유지된다.
- legacy mlx-whisper에서 Native Whisper로 전환한다.
- Native Whisper에서 legacy mlx-whisper로 전환한다.
- Apple Live가 현재 입력에서 사용 불가능하고 Native Whisper가 준비되면 Native Whisper로 한 번만 fallback한다.

### 기존 회귀 테스트 유지

다음 기존 동작은 계속 통과해야 한다.

- API key 제거 시 fallback
- 녹음 중 provider 변경 시 현재 선택 보존
- `System Default + System Audio`에서 API Realtime을 Standard로 정규화
- 사용할 fallback이 없을 때 Apple Live 또는 API Realtime 선택 보존
- Settings의 legacy 옵션 표시와 실제 engine 선택 분리

## 실제 앱 검증

1. 별도 bundle ID의 격리된 개발 앱을 빌드한다.
2. 테스트 bundle에 프로덕션 크래시 조건을 설정한다.
3. Native Whisper 설치 상태를 실제 모델 또는 안전한 테스트 fixture로 준비한다.
4. 앱을 실행해 메인 창이 표시되고 프로세스가 유지되는지 확인한다.
5. 설정 UI와 메인 화면에서 최종 선택이 Native Whisper로 보이는지 확인한다.
6. 치명적 로그와 `SIGSEGV`가 없는지 확인한다.
7. 현재 열어둔 프로덕션 v0.1.22 앱은 새 업데이트 설치 전까지 종료하거나 문제 설정으로 되돌리지 않는다.

## 완료 기준

- 프로덕션 크래시 조건을 재현하는 자동화 테스트가 수정 전 실패하고 수정 후 통과한다.
- 관련 AppState 전사 설정 테스트가 모두 통과한다.
- 전체 프로젝트 테스트가 통과한다.
- 격리된 실제 GUI 앱이 같은 설정 조합으로 정상 실행된다.
- 전사 선택 fallback 우선순위와 UI 동작에 의도하지 않은 변화가 없다.
- 설치된 프로덕션 앱과 사용자 데이터는 구현·검증 과정에서 덮어쓰지 않는다.
