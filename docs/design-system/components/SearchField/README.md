# SearchField

노트 사이드바 둘째 줄의 검색 필드입니다(`searchField`). 돋보기나 ⌘F로 열면 입력 선택·모델 선택 줄 자리를 대신해서, 머리 높이가 바뀌지 않습니다.

- 높이 26, 좌우 9, 반경 7, primary 6% 채움. 돋보기 11 Medium `label-tertiary`, 글자 12, 테두리 없는 텍스트 필드.
- 검색어가 있으면 오른쪽에 지우기(`xmark.circle.fill` 10, `label-tertiary`). Esc나 지우기는 검색어를 비우고 닫습니다. 검색어가 비어 있을 때 포커스가 떠나면 닫힙니다.
