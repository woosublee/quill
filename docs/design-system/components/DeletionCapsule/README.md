# DeletionCapsule

노트 목록 아래, 녹음 버튼 위에 뜨는 유리 캡슐입니다(`NoteDeletionCapsule`).

- 유리 재질(macOS 26+ `glassEffect`, 이전 `.ultraThinMaterial`, 투명도 줄이기 시 `surface-window`) + `stroke-glass` 0.6 + `shadow-glass`, `radius-18`, 최소 높이 36.
- 문구 12 Medium, 좁으면 세 줄까지 줄바꿈.
- 취소 버튼은 `radius-6` + `fill-selected` + `hairline`, 남은 시간만큼 채움이 줄어듭니다(동작 줄이기에서는 1초 단위).
