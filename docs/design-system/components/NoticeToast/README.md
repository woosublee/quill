# NoticeToast

녹음을 멈추지 않는 알림을 오버레이 아래 별도 패널에 한 줄로 보여 줍니다(`RecordingNoticeToastView`, `DegradedCaptureNoticeView`).

- `overlay-surface` + `radius-10`(continuous), 좌우 `space-14`, 아이콘 12 Bold + `overlay-message`.
- 닫기는 hover할 때만 나타나는 18pt 원(`overlay-chip-strong`), VoiceOver에서는 항상 닿습니다.
- 계속·정지 버튼을 넣지 않습니다. 정지는 위 알약이 맡습니다.
