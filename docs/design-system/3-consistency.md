# 정리할 곳

지금 코드에서 이 시스템을 벗어난 부분입니다(main@fe43ee7에서 조사, 이후 고친 내용은 각 절에 적음). 새 화면에서는 이 패턴을 따라 하지 않고, 기존 코드는 항목마다 연결된 GitHub 이슈에서 하나씩 맞춥니다. 숫자는 `Sources/`에서 센 사용 횟수입니다.

## 1. 공통 토큰 파일 — 일부 완료 (#623)

`Sources/QuillDesignTokens.swift`에 간격·반경과 경고·오류 색을 먼저 두었습니다. 나머지 색·그림자와 기존 화면의 숫자는 아래 이슈들에서 옮깁니다.

색·간격·반경이 모두 각 뷰에 숫자로 직접 들어 있습니다(`spacing:` 값 18종, `cornerRadius:` 13종, 그림자 8종). iPhone·iPad와 같이 쓰려면 Swift 패키지(예: `QuillDesign`)에 `QuillColor`, `QuillSpacing`, `QuillRadius`, `QuillFont`를 두고 macOS·iOS가 함께 가져다 쓰는 구조를 권장합니다. 이미 있는 `QuillMotion`, `QuillContrast`, `QuillTransparency`(AccessibilityDisplayPreferences.swift)가 좋은 출발점입니다.

## 2. 강조색 대신 파랑을 직접 씀 (#624)

- `Color.blue` 22곳, `.foregroundStyle(.blue)` 11곳(SettingsView 19, NoteBrowserView 5, ShortcutComponents 5, MenuBarView 4).
- 사용자가 시스템 강조색을 바꾸면 이 부분만 파랗게 남습니다. 모두 `accent`(`Color.accentColor`)로.

## 3. 선택 카드 모양이 네 가지 (#625)

| 위치 | 바탕 | 테두리 | 반경 | 안쪽 여백 |
| --- | --- | --- | --- | --- |
| `OverlayLayoutOptionRow` | `surface-control` | 파랑 2pt | 8 | 14 |
| 모델 행(`ModelRowView` 등) | `accent-tint-selected` | `accent-stroke-selected` 1pt | 6 | 8 |
| `ShortcutComponents`, `MicrophoneOptionRow` | 파랑 10% | 파랑 1.5pt | 8 | 12 |
| 온보딩 선택 카드 | `accent-tint-selected` | — | — | — |

→ 하나로: 가장 많이 쓰는 모양(`accent` 10% + `accent` 1.5pt, `radius-8`, 여백 `space-12`)에 맞추고 `Color.blue` 대신 `accent`(컴포넌트 **OptionRow** 참고).

## 4. 경고 노랑이 두 가지 (#626)

- 배너·이슈: `issue-warning`(#f2b35c). QuillUserIssueView.swift에 두 번 적혀 있던 리터럴은 `QuillColor.issueWarning` 하나로 합쳤습니다.
- 설정 안 주의 문구: 시스템 `.orange`(`status-processing`)를 그대로 사용.
→ 경고 의미는 `issue-warning` 하나로, `.orange`는 처리 중 상태에만.

## 5. 단계 밖의 값 (#627)

- 반경 7(입력 선택 버튼, 노트 내보내기 2곳), 5(18pt 앱 아이콘), 14(권한 안내 창), 1·1.5(막대) → 7은 `radius-6` 또는 `radius-8`, 14는 `radius-10` 또는 `radius-18`로.
- 간격 5, 7, 9, 18, 22, 2.5 → 가까운 단계로. 단, 파형 막대 간격 2.5와 노트 행 세로 9는 의도된 값이라 유지.
- 글자 11.5(행 미리보기, 취소 버튼), 10.5(회의 알림 시작 시각) → 반 단위 크기는 역할 토큰(`row-preview`, `reminder-meta`)으로만 허용하고 새로 만들지 않습니다.

## 6. 그 밖 (#628)

- `YellowSpinner`는 이름과 달리 주황(`status-processing`)으로만 쓰임 → `ProcessingSpinner`로 이름 정리.
- `SettingsCard`는 `.cornerRadius(10)` + 별도 테두리, 다른 카드는 `background(_, in: shape)` → 한 가지 방식으로.
- 라이트/다크 차이를 `colorScheme == .dark ? white : primary`로 매번 분기 → `fill-*`, `stroke-*` 토큰 하나로 감싸기.
- `label-tertiary` 글자는 대비 4.5:1 미달. 빈 상태 장식 외에 설명 문구로 쓰인 곳은 `label-secondary`로.
- `issue-warning`, `issue-error`는 밝은 바탕에서 3:1 미달. 아이콘 전용 규칙을 지키고, 대비 높이기에서는 진한 값으로 바꾸는 처리를 검토.

## 7. 설정 페이지 머리가 탭마다 다름 (#629)

캘린더, iCloud 동기화, AI 도구, 기록 복구 탭에는 큰 페이지 제목이 있고, 일반·모양·모델·프롬프트·단축키·입력에는 없습니다. 정보 탭은 앱 아이콘 머리를 씁니다. → 모두 없애거나 모두 두는 쪽으로 하나로.

## 8. 번역되지 않은 문구 (#630)

한국어 화면에 영어가 남아 있습니다: 모양 탭 카드 제목 "Recording Overlay", 단축키 탭의 "Hold to Talk", "Tap to Toggle", "Paste Again", "Disabled", "Custom Shortcut", "Record any key combo.", "Record…". 개발 빌드에서는 "Quill Dev이(가)"처럼 조사가 어색하게 붙는 문구도 있습니다.

## 9. 켜기/끄기 컨트롤이 섞여 있음 (#631)

같은 성격의 켜기/끄기가 체크박스와 스위치로 섞여 있습니다(화면 구성 › 설정 창의 규칙 참고). 카드 머리 스위치, 줄 안 스위치, 체크박스의 쓰임을 지금 규칙대로 유지하되, 새 설정은 이 규칙에 맞춥니다.

## 10. iPhone 앱(`quill-universal`)이 벗어난 곳

`quill-universal` main@8e715ae의 `ApplePlatforms/QuillMobile/QuilliOS/`에서 조사했습니다. 맞추는 작업은 그 저장소에서 합니다.

- **강조색이 고정 hex.** `QuillVisualSystem`의 `accent`가 `#007AFF` / `#0A84FF`로 고정이고 `.tint(...)`로 직접 겁니다. 시스템 강조색을 바꿔도 따라가지 않습니다(원칙 1). 다른 역할도 시스템 의미 색 대신 hex 팔레트라, 대비 높이기에서 시스템이 진하게 바꿔 주는 처리를 받지 못합니다.
- **오류 색 규칙이 반대.** 배너의 오류 아이콘(`exclamationmark.circle`)은 회색이고, 설정 화면의 오류 문구는 글자를 빨갛게 칠합니다(클라우드 공급자 설정 등 8곳). → 오류는 아이콘만 `issue-error` 계열로, 글자는 `label-secondary`로.
- **경고 노랑이 리터럴.** `QuillStatusBanner.warningTint`가 `Color(red:green:blue:)`로 `#C47318` / `#F2B35C`를 따로 적습니다(macOS `issue-warning`과 다크 값만 같음). 배너 면·테두리도 `Color.primary.opacity`를 직접 씁니다.
- **단계 밖 값.** 간격·여백 리터럴 1, 2, 3, 5, 6, 7, 10과 반경 리터럴 5, 6, 8, 9, 10이 `Spacing`·`Radius` 밖에 있습니다. `Radius`에는 10·16·20만 있어 배너 9, 녹음 막대 30이 이름 없이 쓰입니다.
- **움직임 값이 macOS와 다름.** 제자리 컨트롤 0.18 easeOut(macOS 0.12 easeInOut), 누름 0.97배(macOS 0.92배), 동작 줄이기에서도 0.15초 애니메이션이 남습니다(macOS는 없음). `QuillMotion`을 거치지 않는 애니메이션이 3곳(온보딩, Mac 노트 상세, 요약 탭) 있습니다.
- **색 구분 없이 보기가 한 곳뿐.** 노트 행의 실패 표시만 모양을 바꿉니다. 녹음 막대의 주의 상태 등은 확인이 필요합니다.
- **녹음 버튼·녹음 표면.** 녹음 버튼 56pt와 짙은 회색 녹음 막대는 지금 문서 규칙(44pt, 검정)과 다릅니다. 어느 쪽으로 맞출지는 **iPhone · iPad › 결정할 것** 4·5번.
- **토큰 공유 전.** iOS는 `Sources/QuillDesignTokens.swift`를 쓰지 않고 자체 `QuillVisualSystem`을 둡니다. 1번의 Swift 패키지로 옮길 때 `Spacing.xs`→`space8`처럼 이름을 맞춥니다.
- **남은 주석.** 노트 목록 코드(`CaptureLibraryView.swift`)에 지금 동작과 맞지 않는 "취소 토스트" 주석이 남아 있습니다.
