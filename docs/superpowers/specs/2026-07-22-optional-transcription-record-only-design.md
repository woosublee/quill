# 선택형 전사와 녹음 전용 모드 설계

## 배경

Quill의 현재 녹음 흐름은 모든 녹음이 전사된다고 가정한다. 녹음 종료 진입점도 `stopAndTranscribe()`이며, Setup의 Processing 단계는 Local 또는 API 전사 방식을 반드시 선택하게 한다.

이 구조에서는 System Audio나 System Default + System Audio를 녹음하려는 사용자가 전사 결과를 원하지 않더라도 Native Whisper 모델을 내려받거나 API Provider를 설정해야 한다. 녹음 자체보다 전사 준비가 먼저 필요해 초기 사용 허들이 커진다.

Quill은 이미 오디오 파일 저장, 빈 전사문을 가진 기록, 재전사 가용성 판단, 모델이 없을 때의 안내 토스트를 지원한다. 이번 변경은 이 기존 경로를 확장해 전사를 독립적으로 끌 수 있게 하고, 녹음 전용 결과를 정상적인 Note Browser 상태로 표현한다.

## 목표

- Transcription을 Post-processing 및 Context처럼 독립적으로 켜고 끌 수 있게 한다.
- Transcription이 꺼진 녹음은 모델이나 API 키 없이 오디오 노트로 저장한다.
- 오디오 전용 노트를 실패나 미완료 전사가 아닌 정상 콘텐츠로 표시한다.
- 기존 재전사 버튼, 모델 가용성 판단, 안내 토스트를 재사용한다.
- 전사를 다시 켜면 마지막으로 선택했던 전사 백엔드를 복원한다.
- 기존 사용자의 녹음 동작은 업데이트 후에도 전사가 켜진 상태로 유지한다.
- 신규 설치에만 적용되는 앱 내부 기본값을 조정한다.
- 자동 붙여넣기 기본값 변경에 맞춰 Accessibility 권한을 Setup의 선택 권한으로 이동한다.

## 비목표

- 녹음별 일회성 전사 override를 추가하지 않는다.
- 녹음 종료 때마다 전사 여부를 묻지 않는다.
- 새로운 모델 설치 관리자나 다운로드 재개 기능을 만들지 않는다.
- Apple Speech가 저장된 오디오 파일을 전사하도록 확장하지 않는다.
- 전사가 꺼진 동안 Context를 별도로 수집하거나 분석하지 않는다.
- 오디오 전용 노트에 새로운 파일 형식이나 저장 위치를 도입하지 않는다.
- 이번 작업에서 Settings의 Sound Volume 카드 위치를 변경하지 않는다.

## 핵심 결정

### 전사 여부와 백엔드 선택 분리

`transcriptionEnabled`를 전사 백엔드 선택과 독립된 영구 설정으로 추가한다.

전사 Off를 `TranscriptionBackendChoice.none`으로 모델링하지 않는다. `None`을 백엔드로 취급하면 다음 문제가 생긴다.

- 현재의 backend fallback 및 normalization 로직이 사용자 의도를 덮어쓸 수 있다.
- Audio Import와 재전사에서는 `None`이 유효한 실행 백엔드가 아니다.
- 전사를 다시 켤 때 복원할 마지막 백엔드를 별도로 기억해야 한다.
- 모델 가용성과 사용자의 전사 의도가 하나의 enum에 섞인다.

독립 토글은 다음 세 상태를 분리한다.

1. 사용자가 향후 녹음에서 전사를 원하는가
2. 전사할 때 어떤 백엔드를 사용할 것인가
3. 개별 노트가 현재 어떤 처리 상태인가

## 상태와 저장

### `AppState.transcriptionEnabled`

새로운 `@Published var transcriptionEnabled: Bool`을 추가한다.

- 저장 키: `transcription_enabled`
- Settings에서 토글하면 즉시 저장한다.
- Off로 바꿔도 전사 모델, API 설정, Local Whisper 선택을 변경하지 않는다.
- On으로 바꾸면 마지막 백엔드 선택을 사용한다.
- On으로 전환하는 시점에 현재 입력과 Provider 상태를 기준으로 기존 normalization을 실행한다.
- Off인 동안에는 입력 변경이나 API 키 변경 때문에 기억된 백엔드가 자동으로 다른 백엔드로 바뀌지 않게 한다.
- 녹음 또는 전사 진행 중에는 Settings 토글을 비활성화한다.

### 세션 snapshot

녹음 시작 시 `transcriptionEnabled`를 세션 상태로 snapshot한다. 녹음 종료 처리는 이 snapshot만 사용한다.

- 녹음 도중 설정이 외부에서 바뀌어도 현재 녹음의 처리 방식은 변하지 않는다.
- 다음 녹음부터 새 값이 적용된다.
- 녹음 시작 전까지만 전사 여부를 바꿀 수 있다는 사용자 경험을 보장한다.

### 기존 사용자 마이그레이션

`transcription_enabled`가 없는 기존 설치는 `true`로 해석하고 저장한다.

- `hasCompletedSetup == true`
- `transcription_enabled`가 없음
- 결과: 기존 동작을 보존하기 위해 Transcription On

신규 설치는 Setup의 Processing 카드 선택이 값을 저장한다.

- Record only: Off
- On this Mac: On
- API Provider: On

Setup을 다시 실행하더라도 사용자가 선택한 Processing 카드 외의 신규 설치 공통 기본값은 다시 덮어쓰지 않는다.

## Setup 설계

### Processing 카드

Processing 화면의 최상위 선택지는 세 개다.

1. Record only
2. On this Mac
3. API Provider

처음 화면에 들어왔을 때는 현재처럼 아무 카드도 미리 선택하지 않는다. 사용자가 하나를 선택해야 Continue가 활성화된다.

Record only 설명:

> Save audio notes now. Transcribe them later if needed. No model download or API key required.

`SetupFlow.ProcessingPreset`에 `recordOnly`를 추가한다.

- `recordOnly`: `transcriptionEnabled = false`
- `localAppleSpeech`: `transcriptionEnabled = true`, Apple Speech 선택
- `localNativeWhisper`: `transcriptionEnabled = true`, Native Whisper 선택
- `apiStandard`: `transcriptionEnabled = true`, API Standard 선택

Record only는 Post-processing과 Context의 저장된 토글 값을 바꾸지 않는다. 해당 녹음에서만 두 기능을 실행하지 않는다.

### 권한

신규 기본값에서 자동 붙여넣기와 Command Mode가 모두 Off이므로 Accessibility는 기본 녹음에 필수가 아니다.

필수 권한:

- Record only: Microphone
- Local Apple Speech: Microphone + Speech Recognition
- Local Native Whisper: Microphone
- API Standard: Microphone

선택 권한:

- Accessibility
- Screen & System Audio Recording
- Notifications

Accessibility는 사용자가 나중에 자동 붙여넣기 또는 Command Mode를 켤 때 기존 앱 내 권한 요청 흐름으로 안내한다.

System Audio는 여전히 Screen & System Audio Recording 권한이 필요하다. 기본 오디오 소스는 System Default이므로 Setup 완료 자체는 이 권한으로 막지 않는다.

## Settings 설계

### Transcription 카드

`ModelsSettingsView`의 Transcription 카드를 Post-processing 및 Context 카드와 같은 패턴으로 맞춘다.

- 설명 오른쪽에 switch-style Toggle 배치
- 접근성 label: `Transcription`
- 녹음 또는 전사 중에는 토글 비활성화

On 상태:

- 기존 Model picker와 세부 설정 사용
- 현재 백엔드의 가용성 경고 사용
- 마지막으로 저장된 백엔드를 기준으로 동작

Off 상태:

- 안내 문구: `Record audio without creating a transcript.`
- 모델 선택과 Details를 흐리게 비활성화
- 모델, 언어, API override 값은 삭제하지 않음
- Post-processing과 Context는 실행하지 않음

Post-processing 및 Context 카드의 저장값은 유지하고 계속 편집할 수 있게 한다. Transcription Off 상태에서는 두 카드에 해당 기능이 전사가 켜진 녹음에 적용된다는 보조 설명을 표시한다.

### 메뉴 막대 문구

Transcription Off 상태에서는 메뉴 막대의 수동 시작 문구를 바꾼다.

- On: `Start Dictating`
- Off: `Start Recording`

녹음 완료 상태도 전사 완료 문구 대신 `Recording saved`를 사용한다.

별도의 `Next recording` 메뉴나 일회성 toggle은 추가하지 않는다.

## 녹음 실행 흐름

### 녹음 시작

세션 snapshot이 Off이면 물리적 녹음 장치와 녹음 저널만 시작한다.

시작하지 않는 구성 요소:

- Apple Speech `LiveTranscriber`
- Realtime transcription service
- Context capture task
- Post-processing service snapshot
- Cloud transcription job 및 checkpoint

오디오 소스 접근 권한과 녹음 저장 안정성 검사는 기존 경로를 그대로 사용한다.

### 정상 종료

기존의 단일 종료 진입점은 유지하되, 내부에서 세션 snapshot에 따라 분기한다. 필요하면 `stopAndTranscribe()`처럼 전사를 전제로 한 helper 이름을 녹음 종료와 후처리를 포괄하는 이름으로 제한적으로 정리한다.

전사 Off 정상 종료 순서:

1. 녹음 초기화 timer와 recorder callback 정리
2. 물리적 녹음 장치 정지
3. 기존 recording journal finalization 수행
4. 기존 영구 오디오 파일 저장 경로 사용
5. 캘린더 snapshot 및 녹음 시작·종료 시각 해석
6. 같은 녹음 ID로 audio-only history item 저장
7. `Recording saved` 상태 표시
8. Note Browser에 파란색 Audio only 상태 표시

실행하지 않는 동작:

- Transcribing overlay
- Local 또는 Cloud transcription
- Post-processing
- Context 수집 및 분석
- 클립보드 write
- 자동 붙여넣기
- 기존 `lastTranscript` 또는 Paste Again 대상 삭제

### 저장 실패 및 복구

정상적으로 오디오 파일이 저장된 경우에만 audio-only 상태를 만든다.

- 녹음 저장 실패: 기존 recording storage failure 흐름
- journal finalization 실패: 기존 preserved-for-recovery 흐름
- 비정상 종료 후 복구: 기존 recovered recording 상태
- 빈 녹음: 기존 no-audio 오류

저장 실패나 복구 상태를 audio-only 정상 상태로 위장하지 않는다.

## 오디오 전용 노트 모델

### 명시적 machine status

`PipelineHistoryItem`에 audio-only 상태를 명시적으로 표현한다.

권장 표현:

- persisted `postProcessingStatus`: `audio-only`
- `PipelineHistoryMachineStatus.audioOnly`
- Note Browser 표시 상태에도 별도 audio-only case 추가

audio-only는 다음 범주에 포함되지 않는다.

- failed
- recovered
- importing
- live recording
- cloud transcribing
- incomplete transcription

audio-only item의 기본 필드:

- `rawTranscript = ""`
- `postProcessedTranscript = ""`
- `transcriptFileName = nil`
- `audioFileName` 존재
- `usedContextCapture = false`
- `usedPostProcessing = false`
- `usedLocalTranscription = false`
- 녹음 시작·종료 시각 저장
- 캘린더 match 저장
- 현재 전사 언어 코드는 진단 및 향후 기본값 참고용으로 저장 가능하지만, 실제 전사를 수행한 것으로 표시하지 않는다.

### 제목과 미리보기

파란색 A안의 시각 톤을 사용한다.

- 상태 점: 파란색
- 배지: `Audio only`
- 캘린더 적용 제목이 있으면 해당 제목 사용
- custom title이 있으면 custom title 우선
- 그 외 기본 제목: `Audio recording`
- 목록 미리보기: `Not transcribed`

오디오 전용은 경고색이나 오류 아이콘을 사용하지 않는다.

### 상세 화면

전사문이 없는 일반 `No content` 화면을 재사용하지 않는다.

- 파란색 waveform 계열 아이콘
- 제목: `Audio recording`
- 설명: `Saved without transcription. You can transcribe it later.`
- 저장된 오디오 player 표시
- toolbar의 재전사 action 표시
- audio-only action 도움말: `Transcribe audio`

## 후속 전사

### 기존 가용성 판단 재사용

오디오 전용 노트의 `Transcribe audio` action은 기존 `noteBrowserRetryAvailability(for:)`와 재전사 분기를 사용한다.

- `.ready`: 현재 선택된 실행 가능한 백엔드로 즉시 전사
- `.needsModelSelection`: 기존 모델 선택 안내 toast
- `.needsModelSetup`: 기존 Local Whisper 또는 API 설정 안내 toast
- `.noAudio`: action 비활성화

새로운 모델 설치 sheet나 다운로드 owner를 만들지 않는다.

Apple Speech는 저장된 오디오 파일 전사를 지원하지 않으므로 후속 전사의 실행 가능한 선택지에 포함하지 않는다.

### 글로벌 토글과의 관계

사용자가 audio-only 노트에서 명시적으로 Transcribe audio를 누른 경우에는 글로벌 `transcriptionEnabled == false`여도 해당 노트의 전사를 실행한다.

- 글로벌 토글 값은 바꾸지 않는다.
- 이후 새 녹음은 계속 audio-only로 저장된다.
- 수동 전사 성공 시 같은 note ID를 일반 완료 상태로 갱신한다.

### Post-processing과 Context

오디오 전용 녹음 당시 Context는 수집하지 않았으므로 후속 전사에서도 당시 화면 Context를 재구성하지 않는다.

Post-processing은 수동 전사를 실행하는 시점의 현재 설정을 따른다.

- 현재 Post-processing On: 새 전사문에 후처리 적용
- 현재 Post-processing Off: raw transcript 사용
- 출력 언어, vocabulary, prompt, preserve exact wording도 전사 시점의 현재 설정 사용
- 현재 앱 화면을 과거 녹음의 Context로 사용하지 않는다.

### 성공과 실패

성공:

- 동일한 history item ID 유지
- raw 및 final transcript 저장
- transcript file 생성
- audio-only machine status를 completed로 전환
- 오디오 파일 유지
- 기존 retry 성공 clipboard 동작 재사용

실패:

- 오디오 파일 유지
- 기존 구조화된 Quill user issue 저장
- 기존 retry action 유지
- audio-only 정상 상태 대신 실패 상태를 표시해 실제 실행 실패임을 구분

모델이 준비되지 않아 toast만 표시된 경우에는 실행을 시작하지 않았으므로 audio-only 상태를 그대로 유지한다.

## 신규 설치 공통 기본값

아래 값은 Setup 화면에 추가 질문으로 노출하지 않는다. 신규 설치에서만 앱 내부 기본값으로 적용한다.

| 설정 | 신규 설치 기본값 | 기존 설치의 누락 키 동작 |
|---|---|---|
| Audio Source | System Default | System Default 유지 |
| Paste Automatically | Off | 이전 기본값 On 유지 |
| Preserve Clipboard | On | On 유지 |
| Keep Dictations in Clipboard History | Off | Off 유지 |
| Dictation Audio Interruption | Off | Off 유지 |
| Note Browser | On | On 유지 |
| Transcription Language | Auto Detect | 이전 기본값 Korean 유지 |
| Output Language | Same as spoken language | 유지 |
| Preserve Exact Wording | Off | Off 유지 |
| Recording Overlay Layout | Notch Sides | 이전 기본값 Centered 유지 |
| Waveform Display | Hover Time | 이전 기본값 Waveform Only 유지 |
| Alert Sounds | On | On 유지 |
| Command Mode | Off | Off 유지 |
| Calendar Recording Reminders | Off | Off 유지 |
| Launch at Login | Off | 기존 시스템 등록 상태 유지 |
| Press Enter Voice Command | Off | 이전 기본값 On 유지 |
| Realtime Transcription | Off | Off 유지 |

### 신규 설치와 기존 설치 구분

변경되는 기본값은 단순히 `UserDefaults.bool(forKey:)`의 fallback만 바꾸지 않는다. 그렇게 하면 저장 키가 없는 기존 사용자도 새 기본값으로 바뀐다.

초기화 규칙:

1. 저장 키가 있으면 항상 저장값 사용
2. 저장 키가 없고 `hasCompletedSetup == false`이면 새 기본값 사용 및 명시적으로 저장
3. 저장 키가 없고 `hasCompletedSetup == true`이면 이전 기본값 사용

신규 설치 시 초기화 단계에서 값을 저장해야 한다. 그렇지 않으면 Setup 완료 후 다음 실행에서 누락 키가 기존 설치로 해석되어 이전 기본값으로 되돌아갈 수 있다.

Setup 재실행은 Processing 카드가 직접 다루는 전사 preset과 사용자가 편집한 shortcut만 변경하며, 위 공통 기본값을 다시 seed하지 않는다.

## UI 및 접근성

- Transcription toggle에 명확한 accessibility label 제공
- audio-only 상태 점만으로 의미를 전달하지 않고 `Audio only` 텍스트 배지 병행
- `Transcribe audio` action에 tooltip 및 accessibility label 제공
- toast는 기존 `NSAccessibility.announcementRequested` 경로 재사용
- 영어 및 한국어 localization catalog에 신규 문자열 추가
- 진행 중인 녹음과 전사에서는 Transcription toggle이 비활성화되었다는 상태를 시각적으로 표현

## 테스트 계획

### AppState 및 저장

- `transcription_enabled`가 없는 기존 완료 설치는 On으로 마이그레이션된다.
- 저장된 Off 및 On 값은 그대로 복원된다.
- Transcription Off가 마지막 백엔드 선택을 변경하지 않는다.
- Off 상태의 입력 및 Provider 변경은 remembered backend를 normalization하지 않는다.
- 다시 On하면 현재 환경에 맞춰 기존 normalization이 실행된다.
- 녹음 시작 snapshot 이후 설정 변경이 현재 녹음에 영향을 주지 않는다.

### 신규 설치 기본값

- 신규 설치는 자동 붙여넣기 Off, 언어 Auto, Notch Sides, Hover Time, press-enter Off를 명시적으로 저장한다.
- 완료된 기존 설치의 누락 키는 이전 기본값을 유지한다.
- 저장된 사용자 값은 신규 기본값 로직이 덮어쓰지 않는다.
- Setup 재실행은 공통 기본값을 다시 seed하지 않는다.

### Setup

- Processing 화면에 정확히 Record only, On this Mac, API Provider가 표시된다.
- 아무 카드도 선택하지 않으면 Continue가 비활성화된다.
- Record only는 모델 및 API 키 없이 Continue가 가능하다.
- Record only는 `transcriptionEnabled = false`를 저장한다.
- Local 및 API preset은 `transcriptionEnabled = true`를 저장한다.
- Accessibility가 선택 권한으로 이동한다.
- Apple Speech만 Speech Recognition을 필수로 요구한다.

### 녹음 흐름

- Transcription Off에서 Apple Speech, Realtime, Context가 시작되지 않는다.
- 정상 종료 시 기존 finalizer를 거쳐 영구 오디오 파일이 저장된다.
- audio-only history item이 같은 recording ID와 정확한 시간 범위로 생성된다.
- 캘린더 match 및 제목 정보가 보존된다.
- Transcribing overlay가 표시되지 않는다.
- clipboard와 Paste Again 대상이 변경되지 않는다.
- 저장 실패 및 journal 복구가 기존 오류 상태로 유지된다.

### Note Browser

- audio-only가 별도 정상 machine status로 해석된다.
- 파란색 Audio only 상태, 제목, 미리보기가 표시된다.
- 상세 화면에 오디오 player와 전용 empty state가 표시된다.
- audio-only가 failed, recovered, transcribing으로 표시되지 않는다.
- 앱 재실행 후 상태가 보존된다.

### 후속 전사

- 실행 가능한 현재 backend가 있으면 기존 retry path로 전사한다.
- 모델 선택이 필요하면 기존 selection toast가 표시된다.
- usable backend가 없으면 기존 setup toast가 표시된다.
- toast만 표시된 경우 audio-only 상태가 유지된다.
- 글로벌 Transcription Off에서도 명시적 수동 전사는 실행된다.
- 성공 시 같은 item ID가 completed transcript 상태로 갱신된다.
- 전사 시점의 현재 Post-processing 설정이 적용된다.
- 과거 녹음 Context는 생성하거나 현재 화면으로 대체하지 않는다.
- 실패 시 오디오는 유지되고 기존 structured issue 및 retry action이 표시된다.

### UI 및 localization

- Transcription 카드가 Post-processing 및 Context와 같은 toggle 구조를 사용한다.
- 녹음 또는 전사 중 toggle이 비활성화된다.
- Off 상태에서 모델 설정이 비활성화되지만 값은 보존된다.
- 메뉴 막대 문구가 Transcription 상태에 따라 Start Recording 또는 Start Dictating으로 바뀐다.
- 신규 영어 및 한국어 문자열이 localization validation을 통과한다.

## 성공 기준

- 신규 사용자가 모델 다운로드나 API 키 없이 Record only로 Setup을 완료할 수 있다.
- System Audio를 포함한 모든 기존 오디오 소스를 전사 없이 녹음하고 재생 가능한 노트로 저장할 수 있다.
- 전사를 꺼도 마지막 모델 설정이 손실되지 않는다.
- 기존 사용자의 전사는 업데이트 후 자동으로 꺼지지 않는다.
- 오디오-only 노트는 실패가 아닌 정상 저장 상태로 명확히 보인다.
- 모델이 없어도 재전사 action은 crash나 빈 UI 없이 기존 toast로 안내한다.
- 전사를 다시 켜거나 개별 오디오 노트를 수동 전사할 때 기존 전사 파이프라인을 재사용한다.
