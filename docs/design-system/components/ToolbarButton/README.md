# ToolbarButton

`NoteToolbar` 안의 36pt 원형 아이콘 버튼입니다(`ToolbarIconButton` + `ToolbarButtonStyle`). 아이콘 13 Medium.

- 평소에는 아이콘만, hover 시 `fill-toolbar-hover` + `stroke-selected` 0.5, 누르면 `fill-pressed`에 0.92배. 전환 0.12초 easeInOut.
- 쓸 수 없으면 35% 불투명. 툴팁(help)과 VoiceOver 이름이 같습니다.
- 사이드바 머리의 배경 없는 버튼은 `IconButton`.
