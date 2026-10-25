# SettingsCard

설정 페이지를 이루는 카드입니다(`SettingsCard`).

- `surface-card` + `hairline` 1pt, `radius-10`, 안쪽 `space-16`, 제목과 내용 사이 `space-12`.
- 제목: SF Symbol + 라벨, `headline`.
- 내용 규칙: 토글은 한 줄씩(간격 `space-10`), 피커는 위에 `caption` semibold 라벨 + 280~`size-settings-control` 컨트롤, 도움말 `caption` + `label-secondary`, 주의는 주황 삼각형 + `caption`, 오류는 `QuillUserIssueView` inline.
- 페이지: `SettingsPageScrollView` 안에서 바깥 `space-24`, 카드 사이 `space-20`.
- iPhone·iPad에서는 `List(.insetGrouped)`의 Section 하나(제목 = 섹션 머리, 도움말 = 섹션 꼬리).
