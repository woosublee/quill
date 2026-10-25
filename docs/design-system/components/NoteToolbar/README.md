# NoteToolbar

노트 상세 아래 가운데에 떠 있는 동작 캡슐입니다(`floatingToolbar`, `ToolbarIconButton`). 높이 48, 아래 여백 20, 좌우 8. 배경은 유리(macOS 26 이상 `glassEffect`, 이전은 `.ultraThinMaterial`, 투명도 줄이기에서는 불투명), 테두리 `stroke-glass` 0.6, 그림자 `shadow-glass`.

- 버튼은 36pt 원형, 아이콘 13 Medium. 순서: [다시 만들기] | 복사 · 파일 저장 · [요약 만들기] | 삭제. 구분선은 0.5×18, primary 12%.
- 열린 탭을 따라갑니다(#262): 요약 탭에서는 첫 버튼이 요약 다시 만들기, 전사 탭에서는 전사 재시도(필요할 때만). 다시 만들기 아이콘은 `status-processing`(주황), 삭제는 `status-recording` 80%.
- 요약이 없을 때만 전사 탭에 요약 만들기(`sparkles`)가 붙습니다. 복사하면 아이콘이 잠깐 체크 표시 + `accent`.
- 녹음 중인 노트, 요약·전사 비교 중에는 숨깁니다.
