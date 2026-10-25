# StatusBanner

노트 상세 위에 붙는 한 줄 배너입니다(`QuillUserIssueView` `.warningBanner`, `QuillStatusBanner`, `quillBannerBackground()`).

- 표면: `fill-banner` + `hairline-strong` 1pt + `shadow-banner`, `radius-9`. 여백 위아래 6 · 왼쪽 10 · 오른쪽 6.
- 심각도는 아이콘 색에만: 경고 `issue-warning` 삼각형, 오류 `issue-error` 원. 표면은 항상 중립.
- 제목 `banner-title`, 이유는 다 들어갈 때만 `callout` + `label-secondary`로 옆에. 잘릴 것 같으면 숨기고 정보 버튼 팝오버로.
- 동작은 하나, 중립 버튼(작은 크기). 닫기는 선택.
- 배너가 여럿이면 첫 배너에 `+N` 알약(`fill-selected`, `chip-label` + `label-secondary`), 펼치면 "간단히". 새 배너 모양을 만들지 말고 이것을 씁니다.
