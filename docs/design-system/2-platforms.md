# iPhone · iPad

macOS 규칙을 iPhone·iPad로 옮긴 결과입니다. **토큰 이름과 역할은 그대로, 크기·배치·입력 방식만 플랫폼에 맞춥니다.**

- **iPhone**: 출시된 실제 앱의 코드를 옮겨 적었습니다. 기준은 `quill-universal` main@b8a32b02(#140)이고, 화면 코드는 `ApplePlatforms/QuillMobile/QuilliOS/`, 시각 값은 `Design/QuillVisualSystem.swift`에 있습니다. 앱은 iPhone 전용입니다(`TARGETED_DEVICE_FAMILY = 1`).
- **iPad**: 아직 만들지 않았으므로 제안입니다.

미리보기는 **5 · 화면 · iPhone**, **6 · 화면 · iPad** 묶음에 있습니다. iPhone 코드가 이 시스템에서 벗어난 곳은 **정리할 곳**의 10번 절에 모았습니다.

## 공통 규칙

1. **색은 의미 색으로 연결.** macOS 토큰은 iOS 의미 색(`.label`, `.secondaryLabel`, `.tintColor`, `.systemRed` …)에 연결하고, 강조색은 시스템 tint를 따릅니다. 지금 iPhone 코드는 `QuillColorRole`마다 라이트·다크 hex를 직접 두고 강조색도 고정 파랑이라 이 규칙에서 벗어나 있습니다(**정리할 곳** 10번). 지금 값은 아래 **색 대응**에 있습니다.
2. **녹음은 검정 알약(원칙 2).** 지금 iPhone 녹음 막대는 `recorderPanel`(라이트 `#1C1C1E` 94%, 다크 `#2C2C2E`) 위 흰 글자이고, macOS 오버레이 같은 9막대 파형은 없습니다. Live Activity와 Dynamic Island는 시스템 배경에 아이콘·상태·타이머만 보입니다. 검정으로 맞출지 원칙을 넓힐지는 **결정할 것** 4번.
3. **누를 수 있는 것은 최소 44×44pt**(`QuillVisualSystem.minimumTouchTarget`). 보이는 모양이 작아도 누르는 틀은 44입니다. 배너의 닫기, `+N`, 동작 버튼도 마찬가지입니다.
4. **hover 없음.** macOS에서 hover로만 보이던 것(경과 시간, 닫기 버튼)은 늘 보이게 하거나 길게 누르기·스와이프로 옮깁니다.
5. **Dynamic Type을 따름.** 시스템 글자 스타일을 쓰거나, macOS와 같은 pt를 기준으로 두고 `@ScaledMetric(relativeTo:)`로 키웁니다(노트 행, 상세 메타 줄). 고정 pt 그대로 두지 않습니다.
6. **스위치는 시스템 녹색**(`QuillVisualSystem.switchTint` = `.systemGreen`, 2026-10-24). 앱 강조색을 물려받지 않게 모든 스위치에 직접 답니다.

## 색 대응

| macOS 토큰 | iOS 역할 | 라이트 / 다크 |
| --- | --- | --- |
| `surface-window` | `backgroundPrimary` | `#F5F5F7` / `#1C1C1E` |
| `surface-card` · `surface-control` | `surfaceRaised`(설정 행, 오디오 카드, 툴바 불투명 대체) | `#FFFFFF` / `#2C2C2E` |
| — | `backgroundSecondary` | `#E5E5EA` / `#2C2C2E` |
| `fill-chip` | `controlFillQuiet` | primary 6% / 흰색 8% |
| `fill-selected` | `controlFillStrong`(대비 높이기의 컨트롤 바탕) | primary 8% / 흰색 12% |
| `hairline-strong`(근사) | `borderSubtle` | primary 12% / 흰색 16% |
| `label-primary` / `label-secondary` | `textPrimary` / `textSecondary`(불투명 회색) | `#1D1D1F`·`#6E6E73` / `#F5F5F7`·`#A1A1A6` |
| `label-tertiary` | 역할 없음(설정 꺾쇠만 시스템 `.tertiary`) | |
| `accent` | `accent`(고정) | `#007AFF` / `#0A84FF` |
| `status-recording` · 오류 | `recording` = `failure` | `#FF3B30` / `#FF453A` |
| `status-done` | `completed` | `#1F7A36` / `#30D158` |
| `status-processing` | `attention` | `#B95000` / `#FF9F0A` |
| `overlay-surface` | `recorderPanel` | `#1C1C1E` / `#2C2C2E` |
| `overlay-text` | `recorderForeground` | `#FFFFFF` |
| `shadow-record`(근사) | `recorderScrim` | 검정 22% / 45% |
| `issue-warning` | `QuillStatusBanner.warningTint`(리터럴) | `#C47318` / `#F2B35C` |

배너 표면은 macOS와 같습니다. 중립 면(primary 4.5%) + 테두리 8% + `radius-9`이고, 경고는 아이콘만 칠합니다.

## 글자 대응표

| 역할(토큰) | macOS | iPhone(실제) |
| --- | --- | --- |
| `setup-hero` | 34 Rounded Bold | `.title` Bold(28), 기본 글꼴 |
| `page-error-title` | 20 Semibold | 쓰는 곳 없음. 쓰게 되면 `.title3` Semibold(20) |
| `callout` | 12 | 쓰는 곳 없음. 쓰게 되면 `.callout`(16) |
| `note-title` | 28 Regular | `.title` Bold(28), 자간 -0.3. 본문 안 입력란, 최대 3줄 |
| `transcript` | 15 / 줄 간격 +5 | `.subheadline`(15) / 줄 간격 6 |
| 요약 본문 | 15 | `.subheadline`(15) |
| `body`(설정 라벨) | 13 | `List` 기본 `.body`(17) |
| `caption`(설정 도움말) | 10 | 섹션 꼬리(footer) 기본 글자 |
| `row-title` | 13 Semibold | 15 Semibold(`.subheadline` 기준 크기 조절), 한 줄 |
| `row-preview` | 11.5 | 15(`.subheadline` 기준), 두 줄 |
| `meta-label`(행 날짜) | 9 Semibold | 11 Semibold(`.caption2` 기준), 대문자, 자간 0.4 |
| 상세 메타 줄 | SF Mono 10 + 배지 | SF Mono 10(날짜) / 9 Medium(칩), `.caption2` 기준 크기 조절, 자간 0.2 |
| `badge-label` | 8 Semibold | `.caption2` Semibold(11) |
| `chip-label`(전사 방식 캡슐) | 11 Semibold | `.subheadline` Semibold(15) |
| `empty-title` | 15 Semibold | `.subheadline` Semibold(15) |
| `elapsed-time`(녹음) | 13 | `.title3` Rounded Semibold, monospacedDigit |
| `timer-mono`(오디오 재생) | 9 | `.footnote` SF Mono Semibold |

iPhone 화면은 macOS와 같은 크기 체계를 15pt 본문 기준으로 한두 단계 키운 것입니다. 시스템 기본 17pt 본문은 설정 목록에만 씁니다.

## 간격·크기 대응

iOS 간격 단계는 `QuillVisualSystem.Spacing`의 여섯 개입니다: `xxs` 4 = `space-4`, `xs` 8 = `space-8`, `sm` 12 = `space-12`, `md` 16 = `space-16`, `lg` 24 = `space-24`, `xl` 32.

| 항목 | macOS | iPhone(실제) | iPad(제안) |
| --- | --- | --- | --- |
| 화면 좌우 여백 | `space-24`(설정) / `space-40`(본문) | 16(목록 머리, 행 글자, 상세 본문) | 20 / 본문 최대 폭 680 가운데 |
| 상세 본문 위 여백 | 32 | 24 | 32 |
| `size-note-row` | 80 고정 | 고정 높이. 견본 글자로 메타 1줄 + 제목 1줄 + 미리보기 2줄 높이를 잡고 글자 크기를 따라 커짐. 위아래 9 | 80 |
| 노트 행 폭 | 사이드바 안 `radius-8` 행 | 화면 폭 가득, 0.5pt 구분선도 끝까지 | 사이드바 안 `radius-8` 행 |
| `size-sidebar-notes` | 280 | — | 320(`NavigationSplitView` 기본 폭) |
| `size-sidebar-settings` | 180 | — | 320 |
| `size-record-button` / `size-record-button-iphone` | 44 | 56(`size-record-button-iphone`)에서 시작해 글자 크기를 따라 커짐, 최대 88 | 44(사이드바 아래) |
| `AudioPlayer` 높이 | 72 | 최소 72(접근성 크기 88), 반경 16 | 72 |
| `NoteToolbar` 높이 | 48 | 48 | 48 |
| 녹음 막대 | 오버레이 높이 `size-overlay-height` | 한 줄 캡슐, 반경 30, 안쪽 8 | 사이드바 아래 |

iOS 반경: 입력란·행 눌림 면 `Radius.field` 10, 오디오 카드 `Radius.object` 16, 안내 패널 `Radius.shelf` 20, 녹음 막대 30, 배너 9. 설정 목록은 `insetGrouped` 기본 모양을 씁니다.

## 움직임·햅틱

| 전환 | macOS | iPhone(`QuillMotion`) |
| --- | --- | --- |
| hover·누름, 제자리 컨트롤 | 0.12 easeInOut | 0.18 easeOut |
| 일반 전환, 전사문 나타남 | 0.2 easeInOut | 0.2 easeOut |
| 녹음 표면 | spring(0.28, 0.8) | 하단 패널 spring(0.4, 1.0) |
| 누름 축소 | 0.92배 | 0.97배 |
| 동작 줄이기 | 애니메이션 없음 | 모든 전환 0.15 easeOut, 누름은 축소 대신 불투명도 0.76, 스피너는 모래시계 |

햅틱(`QuillFeedbackEvent`): 누름 확인 light, 녹음 시작 medium, 일시정지·재개 selection, 마무리·복사 success, 삭제 warning. macOS에는 대응이 없습니다.

## 상태와 접근성(iPhone)

- 대비 높이기: 옅은 컨트롤 바탕을 `controlFillStrong` + `borderSubtle` 1pt 테두리로 바꿉니다(`quillQuietControlBackground`). 행 메타 불투명도는 macOS처럼 1에 반쯤 가깝게 올립니다.
- 투명도 줄이기: 툴바·안내 패널은 `surfaceRaised`로, 녹음 막대는 불투명도 1로 바꿉니다.
- 색 구분 없이 보기: 실패한 노트 행은 빨간 점 대신 `exclamationmark.triangle.fill`.
- VoiceOver: 행과 메타 줄은 하나의 요소로 묶어 읽고, 녹음 막대는 상태와 시간을 한 문장으로 읽습니다.

## iPhone 구성(실제)

**탭 막대 없이 `NavigationStack` 하나.** 노트 목록이 루트이고, 노트 상세·설정·최근 삭제된 노트를 push로 엽니다. 시트로 뜨는 것은 전사 방식 고르기(`.medium`/`.large`)뿐이고, 온보딩은 `fullScreenCover`입니다. 미리보기: **5 · 화면 · iPhone › PhoneNotes**, **PhoneSettings**.

### 노트 목록

- 내비게이션 막대는 숨기고, 큰 제목·노트 수 배지도 두지 않습니다(2026-09-28, macOS #384와 같은 머리). "노트"는 상세의 뒤로가기 라벨로만 쓰입니다.
- **머리**(화면 위 고정): 왼쪽 전사 방식 캡슐(`waveform` + 방식 이름 + `chevron.down`, 높이 34, `controlFillQuiet`, 누르면 전사 방식 시트), 오른쪽 검색(`magnifyingglass`)과 `…`(`ellipsis`) 메뉴. 좁은 폭·큰 글자에서는 두 줄로 나뉩니다. macOS 사이드바 머리의 `ModelPicker` 자리에 해당합니다.
- **`…` 메뉴**: 선택, 최근 삭제된 노트, 구분선, 설정(`gearshape`). 설정 전용 톱니 버튼은 없습니다.
- **검색**: `.searchable` 대신 머리 안의 검색창이 캡슐 자리에 들어오고 오른쪽에 `취소`가 붙습니다.
- **목록**: `List(.plain)`, 배경 숨김. 행은 macOS `NoteListRow`를 옮긴 공유 뷰(`quill-universal`의 `Sources/SharedUI/NoteRowView.swift`)를 씁니다. 메타 줄은 "날짜 · 길이"(예: 10월 15일 (목) 오전 9:05 · 12:48) + `요약` 배지(배지는 이것 하나) + 상태 점·스피너·진행 링. 녹음 중인 행은 끝에 빨간 `REC 3:12`(경과 시간, M:SS)가 붙습니다. 전사하지 않은 노트는 배지 대신 미리보기 자리에 "전사되지 않음"이 보입니다. 선택 배경은 칠하지 않습니다. 날짜별 묶음 머리는 보이지 않습니다.
- iPhone 노트와 iCloud로 들어온 Mac 노트가 같은 행 모양으로 시각순으로 섞이고, 출처는 따로 표시하지 않습니다. 녹음 중인 노트가 맨 위에 옵니다.
- **동작**: 끝까지 밀어서 삭제, 길게 누르기 메뉴 `선택` · `삭제…`. 삭제한 노트는 실행 취소 토스트 없이 바로 **최근 삭제된 노트**(30일 보관)로 옮깁니다. 되살리면 그 화면에서 "복구했어요" 토스트가 뜹니다.
- **선택 모드**: 머리가 `모두 선택` + 개수 / `완료`로 바뀌고, 행 왼쪽에 체크 원이 나옵니다. 하단에는 녹음 버튼 대신 빨간 원 휴지통 버튼이 나옵니다.
- **빈 상태**: `mic` + "녹음이 없어요" + 안내 두 줄. 검색 결과가 없으면 `magnifyingglass` + 한 줄.

### 녹음

- **대기**: 목록 아래 가운데 빨간 원 버튼(56pt부터, 흰 18% 테두리 + 그림자). 루트 목록에서만 보이고 검색 중에는 숨깁니다.
- **녹음 중**: 화면 아래 한 줄 캡슐 막대(`recorderPanel`, 반경 30). 순서는 상태 표시(녹음 점 / 일시정지 / 주의) → 상태 문구(녹음 중 · 일시정지됨) → 경과 시간 → 일시정지·재개(회색 원) → 정지(빨간 원 + 흰 사각형). 전체 화면 녹음 시트는 없습니다(2026-09-30).
- 막대는 `NavigationStack` 바깥에 있어 상세·설정으로 가도 계속 보입니다(2026-09-28). 마이크 안내와 주의 문구는 막대 위 한 줄로 붙습니다.
- 실시간 전사(Apple 음성 인식)로 녹음하면 그 노트 상세가 바로 열려 전사문이 흐릅니다. 녹음 뒤에 전사하는 모델은 목록에 머물고, 끝나면 상세로 갑니다.
- 입력 장치를 고르는 화면은 없습니다. 시스템 오디오 경로를 따릅니다.
- **Live Activity**: compact는 왼쪽 앱 아이콘 / 오른쪽 타이머, minimal은 빨간 점(일시정지면 `pause`). 확장·잠금 화면은 아이콘·상태·타이머·일시정지·정지 한 줄(높이 52 / 76). 노트 제목 같은 사용자 내용은 싣지 않습니다.

### 노트 상세

- 내비게이션 막대에는 뒤로가기만 있고 제목은 비웁니다. 머리를 고정하지 않고 화면 전체가 한 스크롤입니다.
- 순서는 macOS 상세 머리와 같습니다: 메타 줄 → 제목 → [캘린더 제목 제안] → `AudioPlayer` → [세그먼트 `전사문` / `요약`] → 본문.
  - 메타 줄: "2026년 10월 15일 (목) 오전 9:05~9:17" + 칩(전사 방식 · CTX · LLM · 언어, macOS `statusBadges`와 같고 CLOUD·NO CTX·NO LLM처럼 꺼진 값은 켜진 칩의 약 0.7배로 흐리게, 전사하지 않은 노트는 첫 칩이 `오디오만`, 2026-10-25). 넘치면 날짜와 칩 단위로 줄을 바꿉니다.
  - 제목: 바로 고치는 입력란. 제목이 없으면 녹음 시각을 흐린 글자로 보입니다.
  - 세그먼트: 요약이 있거나 만드는 중이거나 실패했을 때만 보입니다.
  - 배너(`StatusBanner`): 위치를 고정하지 않고 요약 탭 안, Mac 노트 전사문 위처럼 해당 내용 바로 위에 붙습니다.
  - 요약: 편집 버튼 없이 바로 고치고 스스로 저장합니다(macOS와 같음).
- **`NoteToolbar`**: macOS와 같은 떠 있는 유리 캡슐. 공개 `quill` 레포 `Packages/QuillNoteUI`의 공유 뷰 `NoteFloatingToolbar`와 상태표 `NoteToolbarState`(#697)를 씁니다. 순서도 같습니다: [다시 전사 / 요약 다시 만들기] | 복사 · 파일 공유 · [요약 만들기] | 삭제. 키보드를 올려 고치는 동안에는 숨깁니다. 상태별 모양은 `NoteToolbar`의 상태별 표(#690)를 따릅니다.
- 삭제 확인은 가운데 알림이고, 요약이 있으면 `요약만` / `노트 전체`를 고릅니다.
- Mac 노트 상세도 같은 틀입니다. 다시 전사하면 지금 전사문과 새 전사문을 비교해 고르는 화면이 나옵니다.

### 설정

- 목록 `…` 메뉴의 `설정`에서 push로 엽니다. `List(.insetGrouped)`, 제목은 inline "설정". 바탕은 `backgroundPrimary`, 행은 `surfaceRaised`입니다.
- **루트는 묶음 넷, 행에 아이콘 없음**(2026-10-23): 노트 › 모델 / 연결 › 캘린더 / 동기화 › iCloud / 앱 › 정보. 캘린더(켬·끔), iCloud(상태), 정보(버전) 행은 오른쪽에 값과 꺾쇠가 붙고, 모델 행은 값 없이 이름만 둡니다(전사 방식 이름이 후처리·요약 모델과 헷갈려서, 2026-10-23). 개발 빌드에만 Developer 묶음이 더 있습니다.
- **모델**: 한 화면에 클라우드 → 전사 → 후처리 → 회의 요약 섹션. 전사·후처리·회의 요약은 섹션 첫 줄의 스위치로 켜고 끕니다(macOS 카드 머리 스위치와 같은 역할, 2026-10-22). 전사는 켜면 전사 모델 행(push)이 나오고, 전사 언어는 스위치와 상관없이 늘 보입니다. 후처리와 회의 요약은 켜면 모델, 대체 모델이 이어지고 회의 요약은 언어가 더 있습니다. 클라우드 섹션의 `API 제공업체` 행은 키가 있으면 `켬`입니다. 후처리 아래 `어휘·프롬프트`에 사용자 어휘, 시스템 프롬프트, 받아쓴 명령 실행 방지가 있습니다.
- **모델 고르기 화면**: 묶음 "이 iPhone에서"(Apple 음성 인식, 받는 모델)와 "클라우드". 순서는 가벼운 것부터(Apple 음성 인식 → Qwen → Whisper → Gemma). 선택한 행만 이름 왼쪽에 체크(Wi-Fi 설정처럼), 받기·취소·삭제는 글자 없는 아이콘 버튼(받기 화살표 원, 받는 중 진행 원 + 정지, 빨간 휴지통). 밀어서 삭제는 쓰지 않습니다. 설명은 한 줄 + 용량.
- **캘린더**: 스위치, 권한이 거부됐을 때 설정 열기, 회의 녹음 알림, 읽을 캘린더 체크 목록.
- **iCloud 동기화**: 스위치 + 상태 줄, (조건부) 먼저 글로 바꿀 기기(이 iPhone / Mac), 셀룰러 사용 스위치.
- **정보**: 버전, 개인정보 처리방침·지원 링크, 오픈 소스 라이선스, 처음 안내 다시 보기.

### 온보딩

`fullScreenCover`로 띄우고 쓸어내려 닫지 못합니다. 환영 → 처리 방식(녹음만 / 이 iPhone / API 제공업체) → 권한(마이크, Apple 음성 인식을 쓸 때만 음성 인식) → 캘린더 → iCloud 동기화(로그인했을 때) → 먼저 글로 바꿀 기기(조건부) → 잠금 화면 조작 안내 → 준비 완료. 모든 단계에 빨간 파형 표식(`OnboardingVoiceMark`)이 이어집니다.

## 설정 대응표(실제)

macOS의 `SettingsCard` 하나 = iOS `List(.insetGrouped)`의 Section 하나. 카드 제목은 섹션 머리, `caption` 도움말은 섹션 꼬리가 됩니다. 다만 iPhone 루트는 macOS 탭 목록을 그대로 옮기지 않고 네 묶음으로 줄였습니다.

| macOS 탭 / 카드 | iPhone | 이유 |
| --- | --- | --- |
| 일반 · 앱, 업데이트 | 제외 | iOS에 없는 개념, App Store가 업데이트 |
| 일반 · 권한 | 제외(온보딩과 시스템 설정에서 처리) | |
| 모양 · 앱 외관, 녹음 오버레이 | 제외 | 시스템 외관을 따르고, 녹음 막대는 고정 |
| 모델 · 클라우드 공급자 / 전사 / 후처리 / 회의 요약 | 유지(모델 화면 한 곳에 네 섹션) | |
| 모델 · 컨텍스트 | 제외(노트 칩 `CTX`만 표시) | 다른 앱 화면을 읽을 수 없음 |
| 모델 · 기기 내 모델 저장소 | 변형 → 모델 고르기 화면의 행마다 받기·취소·삭제 | 따로 모아 두지 않음 |
| 프롬프트 | 변형 → 후처리 › 어휘·프롬프트 | |
| 단축키(음성 매크로 포함) | 제외 | 전역 단축키·다른 앱 붙여넣기 불가 |
| 입력 · 오디오 소스, 마이크, 소리 크기 | 제외 | 마이크만 쓰고 시스템 경로를 따름 |
| 캘린더 | 유지(연결 묶음) | 회의 알림은 로컬 알림 |
| iCloud 동기화 | 유지(동기화 묶음, 행 이름 "iCloud") | |
| AI 도구(MCP) | 제외 | Mac에서만 동작 |
| 기록 복구 · 최근 삭제된 노트 | 변형 → 노트 목록 `…` 메뉴 | 노트와 가까운 곳에 둠 |
| 기록 복구 · 보관된 기록 | 제외 | Mac 데이터 폴더 기반 |
| 정보 | 유지 + 오픈 소스 라이선스, 처음 안내 다시 보기 | |

## 컴포넌트 대응

| macOS | iPhone(실제) | iPad(제안) |
| --- | --- | --- |
| `RecordingOverlay`(노치 알약) | 하단 녹음 막대 + Live Activity·Dynamic Island(파형 없음) | 같음 |
| `MeetingReminder`(노치 패널) | 로컬 알림 | 같음 |
| `NoticeToast` | 녹음 막대 위 한 줄 안내 | 같음 |
| `StatusBanner` / `+N` | 같은 모양, 해당 내용 바로 위 | 같음 |
| `IssueEmptyState` | 목록 빈 상태(`CaptureLibraryView` 안의 `mic`·`magnifyingglass` + `textSecondary`). `QuillUnavailableState`는 노트를 열 수 없을 때의 오류 화면(주황 삼각형)으로 따로 씀 | 같음 |
| `NoteListRow` | 같은 공유 뷰, 화면 폭 가득·고정 높이 | 사이드바 안 `radius-8` 행 |
| `SelectionCheckbox` | 선택 모드의 체크 원 | 같음 |
| `DeletionCapsule` | 없음(바로 최근 삭제로) | 같음 |
| `Toast` | 최근 삭제 화면의 "복구했어요" | 같음 |
| `NoteToolbar` / `ToolbarButton` | 같은 떠 있는 유리 캡슐(공유 뷰) | 같음 |
| `IconButton` | 목록 머리의 검색·`…` | 같음 |
| `AudioPlayer` | 같은 공유 파형, 최소 72 | 같음 |
| `SearchField` | 목록 머리 안의 검색창 + `취소` | 같음 |
| `ModelPicker` | 목록 머리의 전사 방식 캡슐 → 시트 | 같음 |
| `InputPicker` | 없음 | 없음 |
| `RecordButton` | 56pt 떠 있는 원(최대 88) | 44(사이드바 아래) |
| `SettingsCard` | `List` Section | 같음 |
| `SettingsSidebarRow` | 설정 루트 행(아이콘 없음) | 왼쪽 탭 목록 |
| `OptionRow` | 이름 왼쪽 체크 표시 목록 행 | 같음 |
| `ModelRow` | 목록 행 + 아이콘 버튼(받기·진행 원·휴지통)·용량 | 같음 |

## iPad 구성(제안)

**`NavigationSplitView` 두 열**: macOS 노트 브라우저와 같은 모양입니다. 미리보기: **6 · 화면 · iPad › PadNotes**, 설정은 **PadSettings**.

- 가로: 두 열 항상 보임(사이드바 320, 유리 재질 `.ultraThinMaterial`). 세로·좁은 Stage Manager 창: 사이드바가 덮개로 열림. 아주 좁으면(Slide Over) iPhone 스택으로.
- 사이드바 머리는 iPhone 목록 머리(전사 방식 캡슐, 검색, `…`)와 같고, 녹음 버튼·녹음 막대는 사이드바 아래.
- 선택 행은 macOS와 같은 `fill-selected` + `stroke-selected` + `radius-8`(시스템 강조 하이라이트 대신). 하드웨어 키보드 포커스 시 `accent-highlight`.
- 하드웨어 키보드: ⌘N 새 녹음, ⌘F 검색, ⌘, 설정, ↑↓ 노트 이동, ⌫ 삭제. 포인터 hover 시 macOS의 hover 상태(`fill-hover`) 그대로.
- 설정: 왼쪽 목록, 오른쪽 해당 페이지. 미리보기는 macOS 탭 순서·아이콘이고, iPhone처럼 네 묶음으로 줄일지는 iPad 작업 때 정합니다. 별도 창(Scene)으로 열지 시트로 열지는 결정할 것 3번.

## 확정한 것

- **iPhone은 탭 막대 없이 `NavigationStack` 하나**(2026-10-25 문서 확정, 앱은 그 전부터). 노트 목록 → 노트 상세, 설정과 최근 삭제된 노트는 목록 `…` 메뉴에서 push.
- **목록 머리에 큰 제목·개수 배지 없음**, 이름은 "노트"(2026-09-28).
- **노트 행은 고정 높이, 화면 폭 가득, 구분선 끝까지**(2026-09-29).
- **녹음 막대는 모든 화면 위에 남고, 전체 화면 녹음 시트는 두지 않음**(2026-09-28, 2026-09-30).
- **삭제는 실행 취소 토스트 없이 최근 삭제로, 30일 보관**(2026-10-17~18).
- **세그먼트는 요약이 있거나 만드는 중·실패일 때만**(2026-10-19). **삭제 확인은 가운데 알림**(2026-10-22).
- **전사·후처리·회의 요약은 스위치로 켜고 끄며, 모델 목록에 "끔"을 두지 않음**(2026-10-22).
- **설정 루트는 노트·연결·동기화·앱 네 묶음, 아이콘 없음**(2026-10-23). **스위치는 시스템 녹색**(2026-10-24).
- **노트 상세 칩은 macOS `statusBadges`와 같게**(2026-10-25).
- **녹음 버튼 크기는 플랫폼마다 따로**(2026-10-25). macOS `size-record-button` 44, iPhone `size-record-button-iphone` 56(엄지 조작, 글자 크기를 따라 최대 88). iPad는 사이드바 아래라 macOS와 같은 44를 제안합니다.

## 결정할 것

1. iOS에서 받아쓰기(다른 앱에 붙여넣기)를 키보드 확장으로 제공할지, 노트 녹음만 할지.
2. iPad 노트 행 선택을 macOS처럼 회색 카드로 할지, iPadOS 기본 강조색 하이라이트로 할지.
3. 설정을 iPad에서 별도 창으로 열지, 시트로 열지.
4. **녹음 표면(보류, 2026-10-25: 지금 iPhone 모양을 그대로 두고 나중에 다시 정함).** 원칙 2는 "테마와 상관없이 검정 위 흰 파형"인데 iPhone 녹음 막대는 짙은 회색(다크 `#2C2C2E`)이고 막대와 Dynamic Island 모두 파형이 없습니다. 원칙을 "짙은 단색, 파형은 macOS 오버레이에만"으로 넓힐지, iPhone을 검정·파형으로 맞출지.
