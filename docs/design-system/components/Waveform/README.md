# Waveform

Quill의 얼굴인 흰 막대 파형입니다(`WaveformBar`, `ProcessingPill`). 항상 `overlay-surface` 위 `overlay-text`로 그립니다.

- **레벨 막대**: 9개, 폭 3, 간격 2.5, 높이 2~20, 캡슐. 가운데가 가장 높도록 배수 0.35 → 1.0. 각 막대는 spring(0.18~0.24, damping 0.88), 가운데부터 0.01초씩 늦게 움직입니다.
- **처리 중 펄스**: 5개, 폭 4, 높이 4~18, 불투명도 0.5~0.94. 1초가 넘으면 도는 링으로 바뀝니다.
- 동작 줄이기: 레벨 막대는 높이만 바뀌고, 처리 중은 멈춘 모래시계(`hourglass`).
- 쓰는 곳: `RecordingOverlay`, 노치 옆 배치. iPhone 녹음 막대·Live Activity에는 쓰지 않습니다. 노트의 오디오 파형은 다른 것(`AudioPlayer`).
