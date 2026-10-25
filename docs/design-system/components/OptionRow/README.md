# OptionRow

여러 선택지 중 하나를 고르는 행입니다(`MicrophoneOptionRow`, `OverlayWaveformModeOptionRow` 등). 설정의 오디오 소스, 마이크, 단축키, 녹음 오버레이와 온보딩에서 씁니다.

- 기본: `surface-control`(`controlBackgroundColor`) 바탕, 테두리 없음, `radius-8`, 안쪽 `space-12`(설명이 있으면 14).
- 선택: `accent` 10% 바탕 + `accent` 테두리 1.5(설명 있는 큰 행은 2).
- 왼쪽 표시: 선택은 `checkmark.circle.fill` `accent`, 나머지는 `circle` `label-secondary`. 큰 행은 20pt.
- 제목은 `body`(큰 행은 `headline`), 설명은 `caption` + `label-secondary`.
- 지금 코드는 `accent` 대신 `Color.blue`를 직접 쓰고, 행마다 테두리 두께와 여백이 조금씩 달라요(정리할 곳 참고). 새 선택 목록은 이 규칙을 따릅니다.
