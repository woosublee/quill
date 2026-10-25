# iPhone · iPad

macOS 화면을 iPhone·iPad로 옮기는 규칙입니다. **토큰 이름과 역할은 그대로, 크기·배치·입력 방식만 플랫폼에 맞춥니다.** 아직 만들어지지 않은 화면이므로 이 섹션은 제안이며, 끝의 **결정할 것**에 확정이 필요한 항목을 모았습니다. 미리보기는 **5 · 화면 · iPhone**, **6 · 화면 · iPad** 묶음에 있습니다.

## 공통 규칙

1. **색은 의미 색 그대로.** `label-*`, `accent`, `status-*`, `fill-*`는 iOS 의미 색(`.label`, `.secondaryLabel`, `.tintColor`, `.systemRed` …)으로 연결합니다. 표면은 iOS 쪽 이름으로 바꿉니다: `surface-window` → `systemGroupedBackground`, `surface-control`·`surface-card` → `secondarySystemGroupedBackground`, `surface-text` → `systemBackground`.
2. **녹음은 여전히 검정 알약.** macOS 노치 오버레이 = iOS Dynamic Island / Live Activity. 같은 9막대 파형, 같은 `overlay-*` 색.
3. **누를 수 있는 것은 최소 44×44pt.** macOS의 20pt 닫기 원, 18pt 체크박스, 26pt 입력 버튼은 보이는 크기는 유지하되 누르는 영역을 44pt로 넓힙니다.
4. **hover 없음.** hover로만 보이는 것(경과 시간, 닫기 버튼)은 항상 보이거나 길게 누르기·스와이프로 옮깁니다.
5. **Dynamic Type 지원.** 아래 표의 역할별 iOS 글자 스타일을 쓰고 고정 pt를 쓰지 않습니다.

## 글자 대응표

| 역할(토큰) | macOS | iPhone / iPad |
| --- | --- | --- |
| `setup-hero` | 34 Rounded Bold | `.largeTitle` Rounded Bold (34) |
| `note-title` | 28 Regular | `.title` Bold (28) — 내비게이션 큰 제목 |
| `page-error-title` | 20 Semibold | `.title3` Semibold (20) |
| `empty-title` | 15 Semibold | `.headline` (17) |
| `transcript` | 15 / 줄간격 +5 | `.body` (17) / 줄간격 +5 |
| `body` (설정 라벨) | 13 | `.body` (17) |
| `row-title` | 13 Semibold | `.headline` (17 Semibold) |
| `row-preview` | 11.5 | `.subheadline` (15) |
| `callout` | 12 | `.callout` (16) |
| `caption` (설정 도움말) | 10 | `.footnote` (13) — List 섹션 footer |
| `meta-label` | 9 Semibold (예: 10월 24일 (토) 오전 9:56) | `.caption` Semibold (12), 자간 0.4 |
| `badge-label` | 8 Semibold | `.caption2` Semibold (11) |
| `chip-label` | 11 Semibold | `.subheadline` Semibold (15) |
| `elapsed-time` / `timer-mono` | 13 / 9 | `.body` monospacedDigit |

## 간격·크기 대응

| 토큰 | macOS | iPhone | iPad |
| --- | --- | --- | --- |
| 화면 좌우 여백 | `space-24` (설정) / `space-40` (본문) | 16 (리스트) / 20 (본문) | 20 / 본문 최대 폭 680 가운데 |
| `size-note-row` | 80 고정 | 내용 높이(최소 76) | 80 |
| `size-sidebar-notes` | 280 | — | 320 (`NavigationSplitView` 기본 폭) |
| `size-sidebar-settings` | 180 | — | 320 |
| `size-record-button` | 44 | 44 (하단 가운데 떠 있는 버튼) | 44 (사이드바 아래) |
| 반경 | `radius-8` 행 | 리스트는 insetGrouped 기본(10), 카드는 `radius-10` | 동일 |

## iPhone 구성

**탭 없이 하나의 내비게이션 스택**으로 확정했습니다(노트가 앱의 전부이고 설정은 가끔 들어가므로).

미리보기: **5 · 화면 · iPhone › PhoneNotes**(목록 → 상세 → 녹음 중), 설정은 **PhoneSettings**

- **노트 목록**: `List(.plain)`. 행 구조는 `NoteListRow` 그대로(날짜 `meta-label` + 배지 + 상태 점 / 제목 / 미리보기 두 줄). 선택 배경 대신 표준 탭 하이라이트. 스와이프로 삭제(삭제 후 `DeletionCapsule` 대신 하단 실행 취소 토스트).
- **녹음 버튼**: 화면 아래 가운데 `size-record-button`(44pt) 원, 같은 빨강→주황 규칙과 `shadow-record`. 녹음을 시작하면 전체 화면 녹음 시트가 올라오고, 앱을 나가면 Live Activity로 이어집니다.
- **노트 상세**: macOS와 같은 순서. 날짜 줄 → 큰 제목 `note-title`(편집 가능) → `AudioPlayer`(낮은 높이) → 세그먼트(`전사` / `요약`) → 배너 → 본문 `transcript`. `NoteToolbar`의 복사·저장·다시 만들기·삭제는 오른쪽 위 `…` 메뉴로 옮깁니다.
- **설정**: 목록 오른쪽 위 톱니 → 시트로 열리는 설정 내비게이션(아래 표).
- **입력 선택**: macOS 사이드바의 입력 버튼 → 녹음 시트의 `마이크 ▾` 메뉴.

## iPad 구성

**`NavigationSplitView` 두 열**: macOS 노트 브라우저와 같은 모양입니다.

미리보기: **6 · 화면 · iPad › PadNotes**, 설정은 **PadSettings**

- 가로: 두 열 항상 보임(사이드바 320, 유리 재질 `.ultraThinMaterial`). 세로·좁은 Stage Manager 창: 사이드바가 덮개로 열림. 아주 좁으면(Slide Over) iPhone 스택으로.
- 선택 행은 macOS와 같은 `fill-selected` + `stroke-selected` + `radius-8`(시스템 강조 하이라이트 대신). 하드웨어 키보드 포커스 시 `accent-highlight`.
- 하드웨어 키보드: ⌘N 새 녹음, ⌘F 검색, ⌘, 설정, ↑↓ 노트 이동, ⌫ 삭제. 포인터 hover 시 macOS의 hover 상태(`fill-hover`) 그대로.
- 설정: 시트 대신 별도 창(Scene) 또는 큰 시트 안의 두 열 `NavigationSplitView` — 왼쪽 탭 목록(macOS 사이드바와 같은 순서·아이콘), 오른쪽 해당 페이지.

## 설정 대응표

macOS의 `SettingsCard` 하나 = iOS의 `List(.insetGrouped)` **Section** 하나. 카드 제목은 섹션 머리, `caption` 도움말은 섹션 꼬리(footer)가 됩니다. 탭 하나 = 설정 루트 목록의 한 줄(왼쪽 SF Symbol, macOS와 같은 아이콘).

| 탭 / 카드 | iPhone·iPad | 이유 |
| --- | --- | --- |
| 일반 · 앱 (로그인 시 실행, 메뉴 막대 아이콘) | 제외 | iOS에 없는 개념 |
| 일반 · 업데이트 | 제외 | App Store가 업데이트 |
| 일반 · 권한 | 유지(마이크, 음성 인식, 알림만) | 손쉬운 사용·화면 기록은 iOS에서 쓰지 않음 |
| 모양 · 앱 모양 | 유지 | |
| 모양 · 녹음 오버레이(가운데/노치 옆) | 변형 → "Live Activity 표시" 토글, 파형 표시 방식은 유지 | 노치 오버레이 대신 Dynamic Island |
| 모델 · 클라우드 제공자 / 전사 / 후처리 / 회의 요약 | 유지 | |
| 모델 · 컨텍스트(화면 맥락) | 제외 | 다른 앱 화면을 읽을 수 없음 |
| 모델 · 기기 내 모델 저장소 | 유지(용량 표시 강조) | 기기 저장 공간이 더 중요 |
| 프롬프트 | 유지(iPad), iPhone은 "고급" 아래로 | 긴 편집은 작은 화면에 부담 |
| 단축키 · 받아쓰기 단축키 / 편집 모드 / 클립보드 / 받아쓰기 중 오디오 | 제외 또는 키보드 확장으로 이동 | 전역 단축키·다른 앱 붙여넣기 불가 |
| 단축키 · 음성 매크로 | 유지 | |
| 입력 · 오디오 소스 | 변형 → 마이크만(시스템 오디오 없음) | iOS는 시스템 소리를 녹음할 수 없음 |
| 입력 · 마이크 | 유지(내장 / 블루투스 / 유선) | |
| 입력 · 소리 크기 | 유지(알림음) | |
| 캘린더 | 유지 | 회의 알림은 로컬 알림 + Live Activity |
| iCloud 동기화 | 유지(문구만 "이 iPhone의 노트") | |
| AI 도구(MCP) | 제외 | Mac에서만 동작 |
| 기록 복구 · 최근 삭제된 노트 | 유지 | |
| 기록 복구 · 보관된 기록 | 제외 | Mac 데이터 폴더 기반 |
| 정보 | 유지 | |

## 컴포넌트 대응

| macOS | iPhone / iPad |
| --- | --- |
| `RecordingOverlay` (노치 알약) | Live Activity·Dynamic Island 압축/확장 모양, 같은 검정·흰 파형 |
| `MeetingReminder` (노치 패널) | 로컬 알림 + 시간 민감 알림, 앱 안에서는 상단 배너 |
| `NoticeToast` | 녹음 시트 상단 한 줄 |
| `StatusBanner` / `+N` | 그대로(상세 상단). 누르면 상세 시트 |
| `IssueEmptyState` | 그대로(`ContentUnavailableView` 모양과 같음) |
| `NoteListRow` | 그대로, 높이만 내용에 맞춤 |
| `SelectionCheckbox` | 편집 모드의 표준 선택 원 |
| `DeletionCapsule` | 하단 실행 취소 토스트(같은 줄어드는 취소 버튼) |
| `Toast` | 그대로, 홈 인디케이터 위 |
| `NoteToolbar` / `ToolbarButton` | iPhone: 오른쪽 위 `…` 메뉴 · iPad: 그대로 떠 있는 캡슐 |
| `IconButton` | 내비게이션 막대 버튼 |
| `AudioPlayer` | 그대로, iPhone은 높이 56 |
| `SearchField` | `.searchable` 표준 검색 |
| `SidebarCapsuleButton` | 그대로(최소 높이 44) |
| `SettingsCard` | `List` Section |
| `SettingsSidebarRow` | 설정 루트 목록 행 |
| `OptionRow` | 체크 표시가 있는 목록 행, 미리보기가 필요하면 그대로 카드 |
| `ModelRow` | 목록 행 + 진행 도넛·용량 |

## 확정한 것

- **iPhone은 탭 막대 없이 내비게이션 스택 하나**(2026-10-25). 노트 목록 → 노트 상세 → 녹음 시트, 설정은 목록 오른쪽 위 톱니에서 시트로 엽니다.
- **녹음 버튼은 모든 플랫폼에서 44pt**(2026-10-25). `size-record-button` 하나만 쓰고 플랫폼별 크기를 따로 두지 않습니다.

## 결정할 것

1. iOS에서 받아쓰기(다른 앱에 붙여넣기)를 키보드 확장으로 제공할지, 노트 녹음만 할지.
2. iPad 노트 행 선택을 macOS처럼 회색 카드로 할지, iPadOS 기본 강조색 하이라이트로 할지.
3. 설정을 iPad에서 별도 창으로 열지, 시트로 열지.
