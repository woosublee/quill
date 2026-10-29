Quill은 말로 쓰는 노트 앱입니다. 화면은 조용하고, 녹음 중인 순간만 또렷합니다. 이 문서는 macOS 앱의 실제 코드에서 뽑은 규칙이며, iPhone 앱(`quill-universal`)과 이후 iPad 앱도 같은 규칙에서 출발합니다. 화면 구성은 **화면 구성** 섹션, iPhone의 실제 배치와 iPad 제안은 **iPhone · iPad** 섹션, 지금 코드에서 규칙을 벗어난 곳은 **정리할 곳** 섹션에 있습니다.

## 디자인 원칙

1. **시스템이 먼저, 브랜드는 한 점.** 앱 UI는 플랫폼의 의미 색(`label-primary`, `surface-window`, `accent`)과 시스템 글꼴로 그립니다. 브랜드 색(`brand-ink`, `brand-glow`)은 아이콘·스토어·웹사이트에만 씁니다. 사용자가 강조색을 바꾸면 Quill도 따라 바뀌어야 합니다.
2. **녹음은 검정 알약.** 녹음 상태는 테마와 상관없이 `overlay-surface`(검정) 위 흰 파형으로 보여 줍니다. 노치·Dynamic Island와 이어 보이는 모양이 Quill의 얼굴입니다. 지금 iPhone은 파형 없는 짙은 회색 녹음 막대를 써서 이 원칙과 다릅니다(**iPhone · iPad › 결정할 것** 4번).
3. **심각도는 아이콘 색에만.** 경고·오류 배너는 중립 표면(`fill-banner` + `hairline-strong`)에 아이콘만 `issue-warning`/`issue-error`로 칠합니다. 표면 전체를 빨갛게 칠하지 않습니다.
4. **새 규칙보다 있는 컴포넌트.** 새 알림은 `StatusBanner`, 여러 개면 `+N` 알약으로 묶습니다. 새 배너 모양, 새 색을 만들지 않습니다.
5. **접근성 설정을 그대로 존중.** 동작 줄이기·투명도 줄이기·대비 높이기·색 구분 없이 보기 각각에 대체 표현이 있습니다(아래 **상태와 접근성**).

## 콘텐츠 원칙

- 한국어는 **해요체**, 영어는 Title Case 버튼·Sentence case 설명. 예: "전사하지 못했어요", "모델 설정 열기", "앱을 다시 열면 적용돼요."
- 버튼은 일어날 일을 동사로: `시작`, `취소`, `전사 재시도`, `나머지 알림 보기`. "확인"·"OK"만 쓰지 않습니다.
- 오류는 무엇이 잘못됐고 어떻게 하면 되는지. 사과하지 않습니다. 예: "녹음 기록을 열 수 없음 — 노트와 오디오 파일은 삭제되지 않았어요. Quill을 다시 시작하거나 데이터 폴더를 열어 보세요."
- 사람이 아는 말로. "회의 오디오"처럼 용도로 이름 붙이지 말고 소스 조합으로 말합니다: 마이크 / 시스템 오디오 / 마이크 + 시스템 오디오.
- 이모지 쓰지 않습니다. 기호는 SF Symbols만.
- 날짜 제목: 제목 없는 노트는 날짜가 제목이 됩니다. 행에서는 `meta-label`로 지역 형식의 날짜·요일·시각을 보입니다(예: 10월 24일 (토) 오전 9:56). 제목 없는 노트의 상세 제목 자리에는 "2026년 10월 24일 오전 9:56"이 흐린 글자로 보입니다.

## 색

- 글자: 본문·제목은 `label-primary`, 설명은 `label-secondary`, 빈 상태 장식은 `label-tertiary`. 대비 높이기에서 `tertiary`는 `secondary`로 올립니다.
- 표면 세 단계: 창 바탕 `surface-window` → 카드 `surface-card`(설정) / `surface-control`(선택 카드) → 읽고 쓰는 영역 `surface-text`.
- 회색 채움은 primary 불투명도 단계로만 만듭니다: hover `fill-hover`(5%) → 칩 `fill-chip`(6%) → 선택 `fill-selected`(8%) → 누름 `fill-pressed`(12%). 다크에서는 흰색 3~12%.
- 선: 카드 `hairline`(6%), 배너 `hairline-strong`(8%), 유리 `stroke-glass`(10%), 선택 `stroke-selected`(12~14%).
- 강조: `accent`와 그 불투명도(`accent-tint-selected` 8%, `accent-tint-nav` 15%, `accent-stroke-selected` 30%, `accent-highlight` 85%). `Color.blue`를 직접 쓰지 않습니다.
- 상태: 녹음 `status-recording`, 처리 중 `status-processing`, 완료 `status-done`. 이슈 아이콘은 `issue-warning`, `issue-error`(아이콘 전용, 글자 금지).
- 오버레이: `overlay-surface` 위 `overlay-text`. 보조는 `overlay-text-muted`(62%), 닫기 원 `overlay-chip`.
- 네이티브 코드에서는 공통 모듈 `Packages/QuillDesignTokens`의 `QuillSpacing`, `QuillRadius`, `QuillColor`, `QuillShadow`, `QuillControlSize`를 씁니다(토큰 이름 `space-12` = `QuillSpacing.space12`). hex를 직접 쓰지 않습니다. 표의 값은 기본 파랑 강조색 기준의 근사값이고, 코드에서는 `Color.primary`, `.secondary`, `Color(nsColor: .windowBackgroundColor)`와 불투명도를 씁니다. iPhone은 `QuillVisualSystem`의 색 역할을 쓰며, 대응은 **iPhone · iPad › 색 대응**에 있습니다.

## 글자

- 글꼴은 시스템 하나: SF Pro(`sans`), 온보딩 큰 제목만 SF Rounded(`rounded`), 코드·로그·타이머는 SF Mono(`mono`). 한글은 시스템 대체(Apple SD Gothic Neo).
- 크기는 역할 이름으로 고릅니다. 화면 제목 `note-title`, 본문 `transcript`, 설정 라벨 `body`, 설정 도움말 `caption`, 행 제목 `row-title`, 행 미리보기 `row-preview`, 행 날짜 `meta-label`.
- 굵기는 regular / medium / semibold / bold 넷. 강조는 semibold가 기본, bold는 오버레이·회의 알림·온보딩 제목에만.
- 본문(`transcript`)은 줄 간격 +5pt, 문단 간격 6pt, 좌우 `space-40`.
- 플랫폼별 크기는 다르고 역할은 같습니다. iPhone은 15pt 본문 기준으로 한두 단계 크고 Dynamic Type을 따릅니다. 대응표는 **iPhone · iPad** 섹션.

## 간격과 배치

- 간격 단계: `space-2` `space-3` `space-4` `space-6` `space-8` `space-10` `space-12` `space-14` `space-16` `space-20` `space-24` `space-40`. 이 밖의 값(5, 7, 18, 22 등)은 새로 쓰지 않습니다. 노트 행의 위아래 9만 예외로 둡니다(80pt 행 높이에 맞춘 값).
- 설정 페이지: 바깥 `space-24`, 카드 사이 `space-20`, 카드 안 `space-16`, 카드 제목과 내용 `space-12`, 컨트롤 사이 `space-10`.
- 노트 행: 좌우 `space-12`, 위아래 9, 높이 `size-note-row`(80).
- 창: 노트 브라우저 최소 800×520, 사이드바 `size-sidebar-notes`. 설정 최소 680×520, 사이드바 `size-sidebar-settings`, 피커 280~`size-settings-control`. 온보딩 최소 560×600.

## 모양: 반경, 표면, 그림자

- 반경 단계: `radius-3`(정지 사각형·요약 하이라이트) → `radius-6`(작은 컨트롤) → `radius-8`(행·선택 카드) → `radius-9`(배너·토스트) → `radius-10`(설정 카드·오버레이 토스트) → `radius-12`(녹음 오버레이 아래 모서리·오디오 카드) → `radius-18`(유리 캡슐) → `radius-26`(회의 알림). 알약·배지는 `radius-capsule`. 오버레이처럼 화면 위에 뜨는 것은 연속 곡률(`.continuous`)을 씁니다.
- 카드 스타일은 역할이 있을 때만: 설정 카드, 선택 카드, 배너, 토스트. 노트 본문에는 카드 없음.
- 유리(재질)는 노트 사이드바(`.ultraThinMaterial`), 삭제 알림 캡슐, 노트 툴바 캡슐에만. macOS 26 이상은 `glassEffect`, 투명도 줄이기에서는 `surface-window`로 불투명하게.
- 그림자는 다섯 가지뿐: `shadow-banner`, `shadow-row-selected`, `shadow-toast`, `shadow-glass`, `shadow-record`.

## 움직임

- 빠르고 짧게. hover·누름 0.12초 easeInOut, 일반 전환 0.2초 easeInOut, hover로 나타나는 닫기 버튼 0.14초 easeOut.
- 녹음 오버레이 상태 전환은 spring(response 0.28, damping 0.8), 파형 막대는 spring(0.18~0.24, damping 0.88)에 가운데부터 0.01초씩 지연.
- 누르는 툴바 버튼은 0.92배로 줄어듭니다.
- 모든 애니메이션은 `QuillMotion.animation(_, reduceMotion:)`을 거칩니다. 동작 줄이기에서는 애니메이션 없음, 도는 스피너는 멈춘 모래시계(`hourglass`), 움직이는 점은 멈춘 점 셋.

## 상태와 접근성

- 대비 높이기: 글자 불투명도는 `QuillContrast.opacity`(1에 반쯤 가깝게), 선·채움은 `QuillContrast.fillOpacity`(두 배).
- 투명도 줄이기: 모든 재질을 `QuillTransparency.background`로 불투명하게.
- 색 구분 없이 보기: 실패 노트는 빨간 점 대신 삼각형 아이콘. 상태는 색 + 모양 또는 글자로 함께 보입니다.
- VoiceOver: 행은 하나의 요소로 묶고 상태를 말로 읽습니다. hover로만 보이는 닫기 버튼도 항상 VoiceOver에서 닿습니다.
- 포커스·선택: 키보드 포커스 행은 `accent-highlight` 바탕 + 흰 글자 + `accent` 테두리.

## 컴포넌트 구성

컴포넌트는 작은 것부터 네 단계로 묶습니다. 새 화면은 위 단계의 것을 조합해서 만들고, 아래 단계에 없는 모양을 새로 만들지 않습니다.

1. **원자**: 더 나눌 수 없는 하나의 요소. `Badge`, `StatusIndicator`, `SelectionCheckbox`, `Waveform`, `CapsuleButton`, `IconButton`, `CloseButton`, `ToolbarButton`, `RecordButton`.
2. **분자**: 원자 몇 개가 한 가지 일을 하는 묶음. `InputPicker`, `ModelPicker`, `SearchField`, `NoteListRow`, `StatusBanner`, `InfoNotice`, `Toast`, `NoticeToast`, `DeletionCapsule`, `AudioPlayer`, `OptionRow`, `ModelRow`.
3. **유기체**: 화면의 한 구역. `RecordingOverlay`, `MeetingReminder`, `NoteToolbar`, `IssueEmptyState`, `SettingsCard`, `SettingsSidebar`.
4. **화면**: 유기체를 배치한 전체 화면. macOS(`MacNoteBrowser`, `MacSettings`)는 지금 코드 그대로, iPhone(`PhoneNotes`, `PhoneSettings`)은 지금 앱 구조를 macOS 토큰으로 근사한 재현, iPad는 제안입니다.

macOS 시스템 컨트롤(토글, 팝업 버튼, 세그먼트, 슬라이더)은 Quill이 따로 꾸미지 않으므로 컴포넌트로 두지 않고 시스템 것을 씁니다.

## 아이콘

- 모든 아이콘은 SF Symbols. 설정 탭: 일반 `gearshape`, 모양 `paintbrush`, 모델 `waveform.badge.magnifyingglass`, 프롬프트 `text.bubble`, 단축키 `keyboard.fill`, 입력 `mic.fill`, 캘린더 `calendar`, iCloud 동기화 `icloud`, AI 도구 `link`, 기록 복구 `arrow.counterclockwise`, 정보 `info.circle`.
- 상태: 경고 `exclamationmark.triangle.fill`, 오류 `exclamationmark.circle.fill`, 정보 `info.circle`, 복구됨 `arrow.clockwise.circle`, 업데이트 `arrow.down.circle.fill`, 편집 모드 `pencil`.
- 빈 상태 아이콘은 ultraLight 22~38pt, `label-tertiary`, 80pt 원 안.
- 앱 아이콘(Logos 그룹)은 남색 유리 사각 위 다섯 개의 빛나는 깃털이 파형을 이룹니다. 깃털 = 쓰기, 높낮이 = 목소리. 개발 빌드는 Dev 아이콘으로 구분합니다.
