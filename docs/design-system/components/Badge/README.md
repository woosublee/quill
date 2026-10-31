# Badge

노트의 성격을 짧게 붙이는 표시입니다. 두 종류만 씁니다.

- **행 배지**(`NoteListRow`): 8 Semibold, 좌우 5 · 위아래 1, `fill-badge` 캡슐, 글자는 행 날짜와 같은 색. `요약`(요약이 있을 때), `오디오만`(전사 없이 녹음만).
- **상세 머리 태그**(`metaTag`): SF Mono 9 Medium 대문자, 배경 없음, `label-secondary` 70%(꺼진 값은 50%). `CLOUD`/`LOCAL`, `CTX`/`NO CTX`, `LLM`/`NO LLM`, 전사 언어. 가운데 점으로 구분하고, VoiceOver는 문장으로 읽습니다.
- 새 배지 색을 만들지 않습니다. 상태(녹음 중·실패)는 배지가 아니라 `StatusIndicator`.
