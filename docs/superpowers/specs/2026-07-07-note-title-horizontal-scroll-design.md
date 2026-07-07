# Note Title Horizontal Scroll Design

## 배경

노트브라우저 상세 패널 상단의 큰 제목 입력칸은 현재 SwiftUI `TextField` 한 줄 입력으로 구성되어 있다. 제목이 표시 가능한 폭보다 길어지면 보이는 영역까지만 노출되고, 사용자는 키보드 커서 이동으로만 뒤쪽 내용을 확인할 수 있다.

사용자가 원하는 동작은 제목 편집 흐름은 유지하되, 긴 제목의 가려진 뒤쪽 내용을 제목 필드 위에서 가로 스크롤로 확인할 수 있게 하는 것이다.

## 목표

- 상세 패널 상단의 큰 제목 입력칸에만 적용한다.
- 제목 입력칸은 한 줄 UI를 유지한다.
- 긴 제목이 폭을 넘으면 트랙패드/마우스 가로 스크롤로 숨은 영역을 볼 수 있게 한다.
- 클릭 편집, 키보드 커서 이동, 텍스트 선택, 복사/붙여넣기 동작은 기존처럼 유지한다.
- 기존 debounce 저장 흐름은 그대로 유지한다.

## 비목표

- 왼쪽 노트 목록 제목 행은 변경하지 않는다.
- 제목을 여러 줄로 확장하지 않는다.
- 본문 스크롤, 노트 목록 스크롤, 제목 결정 로직(`NoteTitleResolver`)은 변경하지 않는다.
- 제목 저장 방식이나 저장 타이밍은 변경하지 않는다.

## 설계

### 컴포넌트

`NoteBrowserView.swift`에 상세 제목 전용 컴포넌트를 추가한다.

- 이름: `HorizontallyScrollableTitleField`
- 입력:
  - `placeholder: String`
  - `text: Binding<String>`
- 역할:
  - AppKit 기반 한 줄 텍스트 필드를 SwiftUI에서 사용할 수 있게 감싼다.
  - 긴 텍스트가 필드 폭을 넘어갈 때 내부 가로 스크롤 위치를 변경할 수 있게 한다.
  - 텍스트 변경은 `Binding<String>`으로 상위 `titleDraft`에 전달한다.

이 컴포넌트는 저장 로직을 알지 않는다. 저장은 기존처럼 `NoteDetailView`의 `titleDraft` 변경 감지와 debounce 타이머가 담당한다.

### 상세 헤더 적용

`NoteDetailView.noteHeader`의 제목 `TextField`를 `HorizontallyScrollableTitleField`로 교체한다.

기존 시각 속성은 유지한다.

- 폰트: `.system(size: 28, weight: .bold)`에 해당하는 AppKit 폰트
- 텍스트 색: primary label 색상
- plain 스타일
- 최소 높이 38
- iBeam 커서

`onChange(of: titleDraft)`, `onAppear`, `overrideCursor(.iBeam)` 흐름은 기존처럼 `NoteDetailView`에 남긴다.

### 스크롤 동작

컴포넌트 내부 AppKit 뷰는 다음 동작을 지원한다.

- 한 줄 편집을 유지한다.
- 사용자가 제목 필드 위에서 horizontal scroll 이벤트를 보내면 필드 내부 표시 위치가 좌우로 이동한다.
- 텍스트가 짧거나 더 이상 이동할 영역이 없으면 기존 입력 동작을 방해하지 않는다.
- 키보드 커서 이동, 클릭 위치 지정, 드래그 선택은 기존 AppKit 텍스트 필드 동작을 따른다.

### 테스트

자동화 테스트는 source-level 회귀 테스트로 시작한다. 이 프로젝트의 기존 UI 테스트 패턴처럼 SwiftUI 런타임 상호작용을 직접 구동하지 않고, 의도한 배선이 유지되는지 확인한다.

검증 항목:

1. `NoteBrowserView.swift`에 `HorizontallyScrollableTitleField`가 정의되어 있다.
2. `NoteDetailView.noteHeader`가 제목 입력에 기본 `TextField` 대신 `HorizontallyScrollableTitleField`를 사용한다.
3. 새 컴포넌트가 `Binding<String>`을 받아 상위 `titleDraft`와 연결된다.
4. 기존 `onChange(of: titleDraft)` debounce 저장 로직은 `NoteDetailView`에 남아 있다.

수동/빌드 검증 항목:

- 긴 제목을 가진 노트를 열었을 때 제목 필드가 한 줄로 유지된다.
- 제목 필드 위에서 가로 스크롤하면 보이지 않던 뒤쪽 제목이 보인다.
- 제목을 편집하면 기존처럼 저장된다.

## 예상 파일 변경

- `Sources/NoteBrowserView.swift`
  - `HorizontallyScrollableTitleField` 추가
  - `NoteDetailView.noteHeader`의 제목 필드 교체

- `Tests/AppStateTranscriptionConfigurationTests.swift` 또는 별도 source-level 테스트 파일
  - 상세 제목 필드 배선 회귀 테스트 추가

## 성공 기준

- 상세 패널 제목이 긴 경우 커서 이동 없이 가로 스크롤로 숨은 부분을 볼 수 있다.
- 제목 필드는 한 줄로 유지된다.
- 제목 편집과 자동 저장은 기존처럼 동작한다.
- 왼쪽 노트 목록과 본문 스크롤 동작은 바뀌지 않는다.
- 관련 테스트와 앱 빌드가 통과한다.
