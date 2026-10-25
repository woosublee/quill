# IssueEmptyState

보여 줄 내용이 없을 때 가운데에 놓는 상태입니다(`QuillUserIssueView` `.full`, 노트 브라우저 빈 상태들).

- 표면 없음. 아이콘 원 → 제목 → 한 줄 → 동작 순서, 간격 `space-8`, 최대 폭 380.
- 빈 상태: 80pt 원(`fill-empty-disc` + `hairline-strong`), ultraLight 22~38 아이콘 `label-tertiary`.
- 오류 상태: 64pt 원에 심각도 색 10%, 아이콘 24 Medium.
- 제목 `empty-title` + `label-secondary`, 설명 `callout` + `label-tertiary`.
- 창 전체 오류(기록을 열 수 없음)는 같은 구조에 42 Light 아이콘, `page-error-title`, 큰 버튼.
- iOS의 `ContentUnavailableView`와 같은 모양입니다.
