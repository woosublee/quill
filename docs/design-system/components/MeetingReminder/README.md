# MeetingReminder

캘린더 회의 직전에 노치에서 내려와 녹음을 시작하게 하는 패널입니다(`MeetingReminderOverlay.swift`).

- 바탕 `overlay-surface-reminder`, 아래 모서리 `radius-26`. 위 30pt 줄에 앱 아이콘(22, `radius-6`)·앱 이름(`overlay-text-label`, 11 Bold)과 닫기 원(`overlay-chip`, 20).
- 회의 이름 `reminder-title`, 시작 시각 `reminder-meta` + `overlay-text-muted`.
- 주 버튼은 흰 캡슐 76×30(`overlay-button`, 글자 `overlay-button-text` 11 Bold), 누르면 85%.
- 노치 옆 배치에서는 한 줄(`MeetingInfoRow`)로 줄어들며 matchedGeometry로 이어집니다.
- macOS 알림은 이 패널을 못 띄울 때만 대체로 씁니다.
