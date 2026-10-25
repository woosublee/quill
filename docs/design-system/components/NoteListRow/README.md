# NoteListRow

노트 브라우저 사이드바의 한 줄입니다(`NoteListRow`).

- 높이 `size-note-row`(80) 고정, 여백 12×9, `radius-8`. 내용 세 줄(간격 `space-3`): 날짜 줄 / 제목 / 미리보기 두 줄.
- 날짜 `meta-label`(대문자), 배지(`badge-label`, `fill-selected` 캡슐: 오디오만·요약), 오른쪽 끝 상태 표시.
- 제목 `row-title` 한 줄, 미리보기 `row-preview` + `label-secondary` 두 줄. 미리보기가 없어도 높이는 같습니다.
- 상태 바탕: 기본 없음 → hover `fill-hover` + 0.5 테두리 → 선택 `fill-selected` + `stroke-selected` 0.6 + `shadow-row-selected` → 키보드 포커스 `accent-highlight` + 흰 글자 → 방금 도착 `accent-tint-arrived`(잠깐).
- 상태 표시: 완료 초록 점, 녹음 중 빨간 점 + `timer-mono`, 전사 중 주황 스피너, 복구됨 주황 화살표 원, 실패 빨간 점(색 구분 없이 보기에서는 삼각형).
- VoiceOver는 행 하나로 묶어 제목·날짜·상태·선택 여부를 말로 읽습니다.
- iPhone도 같은 공유 뷰(`Sources/SharedUI/NoteRowView.swift`)를 씁니다. 화면 폭을 가득 채우고 반경·선택 바탕이 없으며, 글자는 메타 11 / 제목 15 Semibold / 미리보기 15로 Dynamic Type을 따릅니다. 높이는 견본 글자로 잡아 모든 행이 같고, 메타 줄에 녹음 길이가 붙습니다("날짜 · 길이").
