import base64, os, sys

# Usage: python3 docs/design-system/tools/gen_components.py docs/design-system
ROOT = sys.argv[1]
ICON = "data:image/png;base64," + base64.b64encode(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "app-icon-64.png"), "rb").read()).decode()

P = {
    "mic": '<path d="M8 2.5a2 2 0 0 1 2 2V8a2 2 0 0 1-4 0V4.5a2 2 0 0 1 2-2Z"/><path d="M4.5 7.5a3.5 3.5 0 0 0 7 0M8 11v2.5"/>',
    "laptop": '<rect x="3" y="4" width="10" height="7" rx="1"/><path d="M1.5 12.5h13"/>',
    "chev": '<path d="M5 6.5 8 9.5l3-3"/>',
    "search": '<circle cx="7" cy="7" r="4"/><path d="m10 10 3.5 3.5"/>',
    "x": '<path d="m4.5 4.5 7 7m0-7-7 7"/>',
    "info": '<circle cx="8" cy="8" r="6"/><path d="M8 7.2v4M8 4.9v.1"/>',
    "warn": '<path d="M8 2.2 14.3 13H1.7Z" fill="currentColor" stroke="none"/><path d="M8 6.3v3.2M8 11.2v.1" stroke="#000" stroke-opacity=".55"/>',
    "err": '<circle cx="8" cy="8" r="6.3" fill="currentColor" stroke="none"/><path d="M8 4.8v3.8M8 10.8v.1" stroke="#fff"/>',
    "check": '<path d="m4 8.3 2.6 2.6L12 5.5"/>',
    "pencil": '<path d="m10.5 2.8 2.7 2.7-7.4 7.4-3.3.6.6-3.3Z"/>',
    "down": '<circle cx="8" cy="8" r="6.3" fill="currentColor" stroke="none"/><path d="M8 4.8v5.6m-2.4-2.4L8 10.4 10.4 8" stroke="#000"/>',
    "gear": '<circle cx="8" cy="8" r="2.2"/><path d="M8 1.8v2M8 12.2v2M1.8 8h2M12.2 8h2M3.6 3.6 5 5M11 11l1.4 1.4M3.6 12.4 5 11M11 5l1.4-1.4"/>',
    "brush": '<path d="M13 2.5 7.5 8M6.5 9a2 2 0 0 0-3 2c0 1.2-1 1.8-1 1.8s3 .7 4.4-.7A2 2 0 0 0 6.5 9Z"/>',
    "wave": '<path d="M2 8h1.5M4.5 5.5v5M7 3.5v9M9.5 5.5v5M12 7v2M14 8h.5"/>',
    "bubble": '<path d="M2.5 4a1.5 1.5 0 0 1 1.5-1.5h8A1.5 1.5 0 0 1 13.5 4v5A1.5 1.5 0 0 1 12 10.5H7l-3 2.5v-2.5A1.5 1.5 0 0 1 2.5 9Z"/>',
    "key": '<rect x="1.5" y="4" width="13" height="8" rx="1.5"/><path d="M4 6.5h.1M6.5 6.5h.1M9 6.5h.1M11.5 6.5h.1M5 9.5h6"/>',
    "cal": '<rect x="2" y="3" width="12" height="11" rx="1.5"/><path d="M2 6.5h12M5 1.8v2.4M11 1.8v2.4"/>',
    "cloud": '<path d="M4.5 12.5a3 3 0 0 1-.3-6 4 4 0 0 1 7.6-.8 3.4 3.4 0 0 1-.3 6.8Z"/>',
    "link": '<path d="M6.8 9.2a2.5 2.5 0 0 0 3.5 0l2.2-2.2a2.5 2.5 0 0 0-3.5-3.5l-.8.8M9.2 6.8a2.5 2.5 0 0 0-3.5 0L3.5 9a2.5 2.5 0 0 0 3.5 3.5l.8-.8"/>',
    "undo": '<path d="M3 3.5v3.5h3.5"/><path d="M3.3 7A5 5 0 1 1 4.5 11.5"/>',
    "power": '<path d="M8 2v5.5M4.8 4.2a5 5 0 1 0 6.4 0"/>',
    "lock": '<rect x="3" y="7" width="10" height="7" rx="1.5"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2"/>',
    "dots": '<path d="M3.5 8h.1M8 8h.1M12.5 8h.1" stroke-width="2.4"/>',
    "share": '<path d="M8 2v8M5 4.8 8 2l3 2.8M4 7.5H3v6.5h10V7.5h-1"/>',
    "trash": '<path d="M2.5 4.5h11M6 4.5V3h4v1.5M4 4.5l.7 9h6.6l.7-9"/>',
    "play": '<path d="M5 3.5v9l7.5-4.5Z" fill="currentColor"/>',
    "back": '<path d="M10 3 5 8l5 5"/>',
    "plus": '<path d="M8 3v10M3 8h10"/>',
    "sidebar": '<rect x="1.5" y="3" width="13" height="10" rx="1.5"/><path d="M6 3v10"/>',
    "doc": '<path d="M4 1.8h5l3 3v9.4H4Z"/><path d="M9 1.8v3h3M6 8.5h4M6 11h4"/>',
    "import": '<path d="M2 8h1.2M4.4 5.5v5M6.6 4v8M8.8 6v4"/><path d="M12.5 9.5v4M10.5 11.5h4"/>',
    "copy": '<rect x="5.5" y="5.5" width="8" height="8.5" rx="1.5"/><path d="M3.5 10.5h-.5A1 1 0 0 1 2 9.5V3a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v.5"/>',
    "save": '<path d="M8 2v8M5 7.2 8 10l3-2.8M3 10.5V14h10v-3.5"/>',
    "sparkle": '<path d="M7 2.5 8.2 6 11.5 7.2 8.2 8.4 7 12 5.8 8.4 2.5 7.2 5.8 6Z"/><path d="M12.5 2v2.5M11.2 3.2h2.6"/>',
    "vol": '<path d="M2.5 6v4h2.5L8.5 13V3L5 6Z" fill="currentColor"/><path d="M11 5.5a3.5 3.5 0 0 1 0 5"/>',
    "pause": '<path d="M5.5 3.5v9M10.5 3.5v9" stroke-width="2.2"/>',
    "hourglass": '<path d="M4.5 2h7M4.5 14h7M5 2c0 3.5 6 3.5 6 6s-6 2.5-6 6M11 2c0 3.5-6 3.5-6 6s6 2.5 6 6"/>',
}

def ic(name, size=12, sw=1.5):
    return (f'<span class="q-sym"><svg width="{size}" height="{size}" viewBox="0 0 16 16" fill="none" '
            f'stroke="currentColor" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{P[name]}</svg></span>')

def wave(level=0.8):
    ms = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]
    return '<div class="q-wave">' + ''.join(f'<i style="height:{2 + 18 * min(level * m, 1):.1f}px"></i>' for m in ms) + '</div>'

def proc():
    hs = [7, 11, 16, 11, 7]; ops = [.5, .7, .94, .7, .5]
    return '<div class="q-proc">' + ''.join(f'<i style="height:{h}px;opacity:{o}"></i>' for h, o in zip(hs, ops)) + '</div>'

def doc(title, body, group, height, subtitle="", width=None):
    w = f' width={width}' if width else ''
    sub = f' subtitle="{subtitle}"' if subtitle else ''
    return (f'<!-- @dsCard group="{group}" height={height}{w}{sub} -->\n<!doctype html>\n<html lang="ko">\n<head><meta charset="utf-8"><title>{title}</title></head>\n'
            f'<body>\n{body}\n</body>\n</html>\n')

def cap(t):
    return f'<div class="q-cap">{t}</div>'

def item(inner, label):
    return f'<div>{inner}{cap(label)}</div>'

def row(title, preview, date="10월 24일 (토) 오후 2:00", cls="", badges="", status='<span class="q-dot done"></span>', check=""):
    return (f'<div class="q-row {cls}">{check}<div class="c"><div class="meta"><span class="date">{date}</span>{badges}'
            f'<span class="sp"></span>{status}</div><div class="ttl">{title}</div><div class="pv">{preview}</div></div></div>')

C = {}

# ---------- Overlay ----------
C["RecordingOverlay"] = (250, "녹음 상태 알약 · 항상 검정", None, f'''<div class="q-stage" style="background:#5b6472">
{item(f'<div class="q-pill w92"><div class="q-dots"><i class="on"></i><i></i><i></i></div></div>', '준비 중')}
{item(f'<div class="q-pill w92">{wave(.8)}</div>', '녹음 중(누르고 있기)')}
{item(f'<div class="q-pill w150">{wave(.55)}<span class="q-stop"></span></div>', '녹음 중(토글) · 정지')}
{item(f'<div class="q-pill w150"><span style="font-size:13px;font-weight:600">3:12</span><span class="q-stop"></span></div>', 'hover → 경과 시간')}
{item(f'<div class="q-pill w180"><span class="q-lead">{ic("pencil", 12, 1.7)}</span>{wave(.7)}</div>', '편집 모드')}
{item(f'<div class="q-pill w92">{proc()}</div>', '처리 중')}
{item(f'<div class="q-pill wide"><div class="q-pill-msg"><span style="color:var(--status-recording)">{ic("err", 13)}</span>마이크 입력이 없어요</div></div>', '오류')}
{item(f'<div class="q-pill w190"><div class="q-pill-msg update">{ic("down", 13)}버전 1.2.3 사용 가능</div></div>', '업데이트')}
{item(f'<div class="q-notch"><div class="side l">{wave(.6)}</div><div class="hw"></div><div class="side r">3:12</div></div>', '노치 옆 배치')}
</div>''',
"""# RecordingOverlay

녹음·처리·오류 상태를 화면 위쪽 노치 아래에 보여 주는 검정 알약입니다(`RecordingOverlay.swift`).

- 표면은 테마와 무관하게 `overlay-surface`, 아래 두 모서리만 `radius-12`, 높이 `size-overlay-height`.
- 폭은 상태별로 고정: 기본 92, 토글 150, 편집 모드 180, 업데이트 190. 폭이 바뀌면 spring(0.28, 0.8)으로 전환.
- 파형: 흰 막대 9개, 폭 3·간격 2.5·높이 2~20. 가운데가 가장 높게(0.35→1.0 배수). 처리 중은 알약 5개(폭 4, 높이 4~18) 펄스, 1초 넘으면 도는 링.
- 정지 버튼은 오른쪽 20pt 빨간 원(`status-recording` 92%). 누르고 있기 모드에는 없음.
- 오류는 빨간 아이콘 + `overlay-message` 한 줄, 말줄임.
- 배치 두 가지: 가운데(알약) / 노치 옆(노치 좌우로 92pt씩). 업데이트 알림은 항상 가운데.
- 동작 줄이기: 파형은 레벨만, 처리 중은 멈춘 모래시계, 준비 중은 멈춘 점 셋.
- 패널은 클릭을 통과시키고(hover 추적만), 입력 전환은 AppKit 메뉴로 엽니다.
- iPhone: 화면 아래 녹음 막대와 Live Activity·Dynamic Island가 같은 역할입니다. 막대는 짙은 회색 캡슐(`recorderPanel`)에 상태·시간·일시정지·정지만 있고, 파형은 없습니다.
""")

C["MeetingReminder"] = (150, "회의 시작 전 노치에서 내려오는 알림", None, f'''<div class="q-stage" style="background:#5b6472">
<div class="q-remind"><div class="top"><span class="app"><img src="{ICON}" alt="">Quill</span><span class="q-close">{ic("x", 9, 2)}</span></div>
<div class="row"><div><div class="t">디자인 리뷰</div><div class="m">2분 후 시작 · Google Meet</div></div><button class="go">시작</button></div></div>
</div>''',
"""# MeetingReminder

캘린더 회의 직전에 노치에서 내려와 녹음을 시작하게 하는 패널입니다(`MeetingReminderOverlay.swift`).

- 바탕 `overlay-surface-reminder`, 아래 모서리 `radius-26`. 위 30pt 줄에 앱 아이콘(22, `radius-6`)·앱 이름(`overlay-text-label`, 11 Bold)과 닫기 원(`overlay-chip`, 20).
- 회의 이름 `reminder-title`, 시작 시각 `reminder-meta` + `overlay-text-muted`.
- 주 버튼은 흰 캡슐 76×30(`overlay-button`, 글자 `overlay-button-text` 11 Bold), 누르면 85%.
- 노치 옆 배치에서는 한 줄(`MeetingInfoRow`)로 줄어들며 matchedGeometry로 이어집니다.
- macOS 알림은 이 패널을 못 띄울 때만 대체로 씁니다.
""")

C["NoticeToast"] = (110, "녹음 중 알림 한 줄", None, f'''<div class="q-stage" style="background:#5b6472">
{item(f'<div class="q-ntoast"><span style="color:var(--status-processing)">{ic("warn", 12)}</span>시스템 오디오 없음 — 마이크만으로 녹음 중</div>', '알림')}
{item(f'<div class="q-ntoast"><span style="color:var(--status-processing)">{ic("warn", 12)}</span>시스템 오디오를 가져오지 못했어요<span class="x">{ic("x", 8, 2.2)}</span></div>', 'hover 시 닫기')}
</div>''',
"""# NoticeToast

녹음을 멈추지 않는 알림을 오버레이 아래 별도 패널에 한 줄로 보여 줍니다(`RecordingNoticeToastView`, `DegradedCaptureNoticeView`).

- `overlay-surface` + `radius-10`(continuous), 좌우 `space-14`, 아이콘 12 Bold + `overlay-message`.
- 닫기는 hover할 때만 나타나는 18pt 원(`overlay-chip-strong`), VoiceOver에서는 항상 닿습니다.
- 계속·정지 버튼을 넣지 않습니다. 정지는 위 알약이 맡습니다.
""")

# ---------- Feedback ----------
C["StatusBanner"] = (170, "노트 위 한 줄 상태, 여러 개면 +N", None, f'''<div class="q-stage col text">
<div class="q-banner"><span class="err">{ic("err", 11)}</span><span class="ttl">전사하지 못했어요</span><span class="det">네트워크 연결을 확인해 주세요.</span><span class="sp"></span><button class="q-small-btn">전사 재시도</button><button class="q-icon-btn">{ic("info", 12)}</button></div>
<div class="q-banner"><span class="warn">{ic("warn", 11)}</span><span class="ttl">요약을 확인해 주세요</span><span class="sp"></span><button class="q-more">+2</button><button class="q-icon-btn">{ic("x", 9, 2)}</button></div>
<div class="q-banner"><span style="color:var(--status-processing)">{ic("undo", 11, 1.8)}</span><span class="ttl">복구된 녹음이에요</span><span class="det">앱이 갑자기 종료돼 녹음을 되살렸어요.</span><span class="sp"></span><button class="q-small-btn">폴더 열기</button></div>
</div>''',
"""# StatusBanner

노트 상세 위에 붙는 한 줄 배너입니다(`QuillUserIssueView` `.warningBanner`, `QuillStatusBanner`, `quillBannerBackground()`).

- 표면: `fill-banner` + `hairline-strong` 1pt + `shadow-banner`, `radius-9`. 여백 위아래 6 · 왼쪽 10 · 오른쪽 6.
- 심각도는 아이콘 색에만: 경고 `issue-warning` 삼각형, 오류 `issue-error` 원. 표면은 항상 중립.
- 제목 `banner-title`, 이유는 다 들어갈 때만 `callout` + `label-secondary`로 옆에. 잘릴 것 같으면 숨기고 정보 버튼 팝오버로.
- 동작은 하나, 중립 버튼(작은 크기). 닫기는 선택.
- 배너가 여럿이면 첫 배너에 `+N` 알약(`fill-selected`, `chip-label` + `label-secondary`), 펼치면 "간단히". 새 배너 모양을 만들지 말고 이것을 씁니다.
""")

C["IssueEmptyState"] = (300, "가운데 빈 상태와 전체 오류", None, f'''<div class="q-stage text" style="justify-content:center;gap:40px">
<div class="q-empty"><div class="disc">{ic("search", 30, 1)}</div><h3>일치하는 노트 없음</h3><p>"로드맵"과 일치하는 노트가 없어요. 다른 단어로 찾아보거나 검색어를 지워 보세요.</p></div>
<div class="q-empty"><div class="disc issue">{ic("warn", 24)}</div><h3>전사하지 못했어요</h3><p>오디오는 그대로 있어요. 다시 시도하거나 모델 설정을 확인해 보세요.</p><div class="acts"><button class="q-small-btn">전사 재시도</button><button class="q-small-btn">모델 설정 열기</button></div></div>
</div>''',
"""# IssueEmptyState

보여 줄 내용이 없을 때 가운데에 놓는 상태입니다(`QuillUserIssueView` `.full`, 노트 브라우저 빈 상태들).

- 표면 없음. 아이콘 원 → 제목 → 한 줄 → 동작 순서, 간격 `space-8`, 최대 폭 380.
- 빈 상태: 80pt 원(`fill-empty-disc` + `hairline-strong`), ultraLight 22~38 아이콘 `label-tertiary`.
- 오류 상태: 64pt 원에 심각도 색 10%, 아이콘 24 Medium.
- 제목 `empty-title` + `label-secondary`, 설명 `callout` + `label-tertiary`.
- 창 전체 오류(기록을 열 수 없음)는 같은 구조에 42 Light 아이콘, `page-error-title`, 큰 버튼.
- iOS의 `ContentUnavailableView`와 같은 모양입니다.
""")

C["InfoNotice"] = (70, "동작이 필요 없는 조용한 한 줄", None, f'''<div class="q-stage text"><div class="q-info">{ic("info", 11)}<span>정리할 내용이 없어 원문을 그대로 두었어요.</span><span class="sp"></span><button class="q-icon-btn">{ic("x", 9, 2)}</button></div></div>''',
"""# InfoNotice

정보만 주는 한 줄입니다(`QuillInfoNotice`). 표면 없이 `info.circle` 11 + `callout`, 전체 `label-secondary`, 닫기는 선택.
""")

C["Toast"] = (80, "노트 브라우저 하단 토스트", None, f'''<div class="q-stage text"><div class="q-toast">노트를 Markdown으로 내보냈어요<u>Finder에서 보기</u></div></div>''',
"""# Toast

작업 결과를 잠깐 알리는 하단 토스트입니다(`NoteBrowserToastView`).

- `overlay-toast` + `radius-9`(continuous) + `shadow-toast`, 여백 14×9, 최대 세 줄 가운데 정렬.
- 문구 `toast-text`, 동작은 밑줄 친 `chip-label`(흰색) 하나.
""")

C["DeletionCapsule"] = (120, "삭제 알림 + 줄어드는 취소", None, f'''<div class="q-stage" style="background:var(--surface-window)">
{item('<div class="q-glass"><span>노트 2개를 삭제했어요</span><button class="q-cancel"><span class="fill"></span><span>취소</span></button></div>', '취소 가능')}
{item('<div class="q-glass" style="padding-right:14px"><span>전사가 끝난 뒤에 노트를 삭제해 주세요</span></div>', '안내만')}
</div>''',
"""# DeletionCapsule

노트 목록 아래, 녹음 버튼 위에 뜨는 유리 캡슐입니다(`NoteDeletionCapsule`).

- 유리 재질(macOS 26+ `glassEffect`, 이전 `.ultraThinMaterial`, 투명도 줄이기 시 `surface-window`) + `stroke-glass` 0.6 + `shadow-glass`, `radius-18`, 최소 높이 36.
- 문구 12 Medium, 좁으면 세 줄까지 줄바꿈.
- 취소 버튼은 `radius-6` + `fill-selected` + `hairline`, 남은 시간만큼 채움이 줄어듭니다(동작 줄이기에서는 1초 단위).
""")

# ---------- Notes ----------
chk_on = f'<span class="q-check on">{ic("check", 10, 2.2)}</span>'
C["NoteListRow"] = (500, "노트 목록 한 줄과 상태", None, f'''<div class="q-stage">
<div class="q-list">
{row("주간 제품 회의", "출시 일정과 QA 범위를 이야기했어요. 다음 주까지 온보딩 문구를 정리하기로…", badges='<span class="q-badge">요약</span>')}
{row("고객 인터뷰 정리", "가장 자주 나온 불편은 녹음 파일을 찾기 어렵다는 점이었어요.", cls="sel", date="10월 23일 (금) 오전 11:20")}
{row("2026년 10월 22일 오후 3:40", "", cls="", date="10월 22일 (목) 오후 3:40", badges='<span class="q-badge">오디오만</span>')}
{row("아이디어 메모", "알림 묶음은 +N 알약 하나로 충분해 보여요.", cls="key", date="10월 21일 (수) 오전 9:05", status='<span class="q-dot done" style="box-shadow:0 0 0 1px rgba(255,255,255,.9)"></span>')}
</div>
<div class="q-list">
{row("녹음 중", "", date="10월 24일 (토) 오후 2:00", status='<span class="q-dot rec"></span><span class="q-timer">03:12</span>')}
{row("팀 스탠드업", "전사하는 중이에요…", date="10월 24일 (토) 오후 2:00", status='<span class="q-spin"></span>')}
{row("방금 도착한 노트", "다른 Mac에서 동기화된 노트예요.", cls="new", date="10월 24일 (토) 오후 2:00")}
{row("다중 선택", "선택 모드에서는 왼쪽에 원형 체크박스가 생겨요.", date="10월 20일 (화) 오후 4:30", check=chk_on)}
</div>
</div>''',
"""# NoteListRow

노트 브라우저 사이드바의 한 줄입니다(`NoteListRow`).

- 높이 `size-note-row`(80) 고정, 여백 12×9, `radius-8`. 내용 세 줄(간격 `space-3`): 날짜 줄 / 제목 / 미리보기 두 줄.
- 날짜 `meta-label`(대문자), 배지(`badge-label`, `fill-badge` 캡슐: 오디오만·요약), 오른쪽 끝 상태 표시.
- 제목 `row-title` 한 줄, 미리보기 `row-preview` + `label-secondary` 두 줄. 미리보기가 없어도 높이는 같습니다.
- 상태 바탕: 기본 없음 → hover `fill-hover` + `stroke-hover` 0.5 → 선택 `fill-selected` + `stroke-selected` 0.6 + `shadow-row-selected` → 키보드 포커스 `accent-highlight` + 흰 글자 → 방금 도착 `accent-tint-arrived`(잠깐).
- 상태 표시: 완료 초록 점, 녹음 중 빨간 점 + `timer-mono`, 전사 중 주황 스피너, 복구됨 주황 화살표 원, 실패 빨간 점(색 구분 없이 보기에서는 삼각형).
- VoiceOver는 행 하나로 묶어 제목·날짜·상태·선택 여부를 말로 읽습니다.
- iPhone은 이 행을 옮긴 공유 뷰(`quill-universal`의 `Sources/SharedUI/NoteRowView.swift`)를 씁니다. 화면 폭을 가득 채우고 반경·선택 바탕이 없으며, 글자는 메타 11 / 제목 15 Semibold / 미리보기 15로 Dynamic Type을 따릅니다. 높이는 견본 글자로 잡아 모든 행이 같고, 메타 줄에 녹음 길이가 붙습니다("날짜 · 길이").
""")

C["SelectionCheckbox"] = (80, "다중 선택 원", None, f'''<div class="q-stage">{item(chk_on, '선택')}{item('<span class="q-check off"></span>', '선택 안 함')}{item('<span class="q-check na"></span>', '선택 불가(녹음·처리 중)')}</div>''',
"""# SelectionCheckbox

다중 선택 모드에서 노트 행 왼쪽에 붙는 18pt 원입니다. 선택 `accent` + 흰 체크(9 Bold), 미선택 `label-secondary` 60% 1.5 테두리, 선택 불가 점선(35%) + 이유 도움말.
""")

C["StatusIndicator"] = (90, "노트 상태 점·스피너", None, f'''<div class="q-stage">
{item('<span class="q-dot done"></span>', '완료 · 오디오만')}
{item('<span style="display:inline-flex;gap:4px;align-items:center"><span class="q-dot rec"></span><span class="q-timer">03:12</span></span>', '녹음 중')}
{item('<span class="q-spin"></span>', '전사 중')}
{item(f'<span style="color:var(--status-processing)">{ic("undo", 9, 1.8)}</span>', '복구됨')}
{item('<span class="q-dot fail"></span>', '실패')}
{item(f'<span style="color:var(--status-recording)">{ic("warn", 9)}</span>', '실패(색 구분 없이 보기)')}
</div>''',
"""# StatusIndicator

노트 상태를 6~9pt 크기로 보여 주는 표시입니다. 색 토큰은 `status-done`, `status-recording`, `status-processing`. 완료와 실패가 같은 크기의 점이므로 색 구분 없이 보기에서는 실패를 삼각형으로 바꿉니다. 동작 줄이기에서 스피너는 멈춘 모래시계.
""")

# ---------- Actions ----------
C["CapsuleButton"] = (80, "사이드바·배너의 중립 캡슐", None, f'''<div class="q-stage" style="background:var(--surface-window)">{item('<button class="q-capsule">전사 방식 선택</button>', '기본')}{item('<button class="q-capsule" style="background:var(--fill-pressed)">전사 방식 선택</button>', '누름')}{item('<button class="q-capsule" disabled>전사 방식 선택</button>', '비활성')}{item('<button class="q-more">+3</button>', '+N 알약')}</div>''',
"""# CapsuleButton

중립 캡슐 버튼입니다(`SidebarCapsuleButtonStyle`). `chip-label`, 여백 10×5, `fill-chip` → 누름 `fill-pressed`, 비활성 `opacity-disabled`. 강조색을 쓰지 않습니다. 주 동작이 필요한 곳은 시스템 `.borderedProminent`를 씁니다.
""")

C["ToolbarButton"] = (80, "노트 툴바의 원형 아이콘 버튼", None, f'''<div class="q-stage text">{item(f'<button class="q-tool lg">{ic("copy", 14)}</button>', '기본')}{item(f'<button class="q-tool lg hover">{ic("copy", 14)}</button>', 'hover')}{item(f'<button class="q-tool lg" style="background:var(--fill-pressed);transform:scale(.92)">{ic("copy", 14)}</button>', '누름 0.92배')}{item(f'<button class="q-tool lg" style="opacity:.35">{ic("copy", 14)}</button>', '쓸 수 없음')}{item(f'<button class="q-tool lg" style="color:var(--status-recording)">{ic("trash", 14)}</button>', '삭제')}</div>''',
"""# ToolbarButton

`NoteToolbar` 안의 36pt 원형 아이콘 버튼입니다(`ToolbarIconButton` + `ToolbarButtonStyle`). 아이콘 13 Medium.

- 평소에는 아이콘만, hover 시 `fill-toolbar-hover` + `stroke-selected` 0.5, 누르면 `fill-pressed`에 0.92배. 전환 0.12초 easeInOut.
- 쓸 수 없으면 35% 불투명. 툴팁(help)과 VoiceOver 이름이 같습니다.
- 사이드바 머리의 배경 없는 버튼은 `IconButton`.
""")

C["RecordButton"] = (100, "떠 있는 녹음 버튼", None, f'''<div class="q-stage" style="background:var(--surface-window)">{item('<button class="q-rec" aria-label="녹음"></button>', '대기 44 · macOS')}{item('<button class="q-rec on" aria-label="정지"></button>', '녹음 중')}</div>''',
"""# RecordButton

노트 사이드바 아래 가운데의 녹음 버튼입니다. 지름 `size-record-button`, 대기 `status-recording`, 녹음 중 `status-processing` + 흰 14pt 사각형(`radius-3`). 흰 18% 테두리(`record-ring`) + `shadow-record`. 다중 선택 중에는 숨깁니다. iPhone은 56에서 시작해 글자 크기를 따라 최대 88까지 커지고, 선택 모드에서는 빨간 휴지통 버튼으로 바뀝니다. 크기는 플랫폼마다 따로 둡니다(`size-record-button-iphone`, 2026-10-25).
""")

C["InputPicker"] = (80, "다음 녹음의 오디오 소스", None, f'''<div class="q-stage" style="background:var(--surface-window)">{item(f'<span class="q-input">{ic("mic", 11)}{ic("chev", 9, 1.8)}</span>', '마이크')}{item(f'<span class="q-input"><span style="display:inline-flex;align-items:center;gap:2px">{ic("mic", 11)}<b style="font-size:9px;color:var(--label-secondary)">+</b>{ic("laptop", 11)}</span>{ic("chev", 9, 1.8)}</span>', '마이크 + 시스템 오디오')}{item(f'<span class="q-input">{ic("laptop", 11)}{ic("chev", 9, 1.8)}</span>', '시스템 오디오')}</div>''',
"""# InputPicker

다음 녹음이 무엇을 담을지 아이콘으로 보여 주는 66×26 버튼입니다(노트 브라우저 사이드바 머리). `fill-chip`, 반경 7(정리할 곳 참고). 누르면 메뉴 막대 마이크 하위 메뉴와 같은 AppKit 메뉴. 소스는 이름 대신 조합으로 표현합니다: 마이크 / 마이크 + 시스템 오디오 / 시스템 오디오.
""")

# ---------- Atoms split out of larger components ----------
C["Badge"] = (80, "노트 행 배지와 상세 머리 태그", None, f'''<div class="q-stage">{item('<span class="q-badge">요약</span>', '행 배지 · 요약')}{item('<span class="q-badge">오디오만</span>', '행 배지 · 오디오만')}{item('<span class="q-tags"><span>CLOUD</span>·<span class="dim">NO CTX</span>·<span>LLM</span>·<span>KO</span></span>', '상세 머리 태그')}</div>''',
"""# Badge

노트의 성격을 짧게 붙이는 표시입니다. 두 종류만 씁니다.

- **행 배지**(`NoteListRow`): 8 Semibold, 좌우 5 · 위아래 1, `fill-badge` 캡슐, 글자는 행 날짜와 같은 색. `요약`(요약이 있을 때), `오디오만`(전사 없이 녹음만).
- **상세 머리 태그**(`metaTag`): SF Mono 9 Medium 대문자, 배경 없음, `label-secondary` 70%(꺼진 값은 50%). `CLOUD`/`LOCAL`, `CTX`/`NO CTX`, `LLM`/`NO LLM`, 전사 언어. 가운데 점으로 구분하고, VoiceOver는 문장으로 읽습니다.
- 새 배지 색을 만들지 않습니다. 상태(녹음 중·실패)는 배지가 아니라 `StatusIndicator`.
""")

C["Waveform"] = (90, "녹음 레벨 막대와 처리 중 펄스", None, f'''<div class="q-stage" style="background:var(--overlay-surface);color:var(--overlay-text)">{item(wave(.35), '조용함')}{item(wave(.8), '말하는 중')}{item(wave(1), '큰 소리')}{item(proc(), '처리 중 펄스')}</div>'''.replace('class="q-cap"', 'class="q-cap" style="color:var(--overlay-text-muted)"'),
"""# Waveform

Quill의 얼굴인 흰 막대 파형입니다(`WaveformBar`, `ProcessingPill`). 항상 `overlay-surface` 위 `overlay-text`로 그립니다.

- **레벨 막대**: 9개, 폭 3, 간격 2.5, 높이 2~20, 캡슐. 가운데가 가장 높도록 배수 0.35 → 1.0. 각 막대는 spring(0.18~0.24, damping 0.88), 가운데부터 0.01초씩 늦게 움직입니다.
- **처리 중 펄스**: 5개, 폭 4, 높이 4~18, 불투명도 0.5~0.94. 1초가 넘으면 도는 링으로 바뀝니다.
- 동작 줄이기: 레벨 막대는 높이만 바뀌고, 처리 중은 멈춘 모래시계(`hourglass`).
- 쓰는 곳: `RecordingOverlay`, 노치 옆 배치. iPhone 녹음 막대·Live Activity에는 쓰지 않습니다. 노트의 오디오 파형은 다른 것(`AudioPlayer`).
""")

C["CloseButton"] = (80, "배너·오버레이의 작은 원형 닫기", None, f'''<div class="q-stage">{item(f'<button class="q-icon-btn" aria-label="닫기">{ic("x", 9, 2)}</button>', '배너 · 기본')}{item(f'<button class="q-icon-btn" style="background:var(--fill-hover)" aria-label="닫기">{ic("x", 9, 2)}</button>', '배너 · hover')}{item(f'<button class="q-icon-btn" aria-label="자세히">{ic("info", 12)}</button>', '배너 · 정보')}{item(f'<span style="background:var(--overlay-surface);padding:6px;border-radius:8px;display:inline-flex"><span class="q-close">{ic("x", 9, 2)}</span></span>', '오버레이 위')}</div>''',
"""# CloseButton

배너와 오버레이 오른쪽 끝의 20pt 원형 아이콘 버튼입니다(`size-close`).

- 밝은 표면(배너·안내): 아이콘 `label-secondary`, 평소 배경 없음, hover에 `fill-hover`. 닫기 `xmark` 9 Bold, 정보 `info.circle` 12.
- 검정 오버레이 위: `overlay-chip` 원 + 흰 78% 아이콘.
- 누르는 영역은 보이는 크기보다 넓게 잡고, hover로만 나타나도 VoiceOver에서는 항상 닿게 합니다. iPhone·iPad는 누르는 영역 44pt.
""")

C["IconButton"] = (80, "노트 사이드바 머리의 아이콘 버튼", None, f'''<div class="q-stage" style="background:var(--surface-window)">{item(f'<button class="q-hicon">{ic("search", 13)}</button>', '검색')}{item(f'<button class="q-hicon" style="color:var(--accent)">{ic("search", 13)}</button>', '검색어 있음')}{item(f'<button class="q-hicon">{ic("import", 13)}</button>', '오디오 가져오기')}{item(f'<button class="q-hicon" style="opacity:.45">{ic("import", 13)}</button>', '쓸 수 없음')}</div>''',
"""# IconButton

노트 사이드바 첫 줄(신호등 버튼 옆)의 배경 없는 아이콘 버튼입니다(`headerIconButton`). 26×24, 아이콘 13 Medium, `label-secondary`.

- 검색(`magnifyingglass`, ⌘F)은 검색어가 있으면 `accent`. 오디오 가져오기(`waveform.badge.plus`)는 녹음 중·선택 중에 꺼집니다(45%).
- 배경·테두리를 그리지 않습니다. 원형 hover가 필요한 곳은 `ToolbarButton`.
""")

C["SearchField"] = (70, "노트 검색 필드", None, f'''<div class="q-stage col" style="background:var(--surface-window);width:256px">{item(f'<div class="q-searchf">{ic("search", 11)}<span class="ph">노트 검색</span></div>', '비어 있음')}{item(f'<div class="q-searchf">{ic("search", 11)}<span>로드맵</span><span class="clr">{ic("x", 7, 2.4)}</span></div>', '입력 중 · 지우기')}</div>''',
"""# SearchField

노트 사이드바 둘째 줄의 검색 필드입니다(`searchField`). 돋보기나 ⌘F로 열면 입력 선택·모델 선택 줄 자리를 대신해서, 머리 높이가 바뀌지 않습니다.

- 높이 26, 좌우 9, 반경 7, primary 6% 채움. 돋보기 11 Medium `label-tertiary`, 글자 12, 테두리 없는 텍스트 필드.
- 검색어가 있으면 오른쪽에 지우기(`xmark.circle.fill` 10, `label-tertiary`). Esc나 지우기는 검색어를 비우고 닫습니다. 검색어가 비어 있을 때 포커스가 떠나면 닫힙니다.
""")

C["ModelPicker"] = (80, "다음 녹음의 전사 모델", None, f'''<div class="q-stage" style="background:var(--surface-window);width:280px;flex-direction:column">{item(f'<span class="q-input model" style="width:200px">{ic("wave", 12)}<span class="lb">Whisper Large v3 Turbo</span>{ic("chev", 8, 1.8)}</span>', '기본')}{item(f'<span class="q-input model" style="width:200px;opacity:.45">{ic("wave", 12)}<span class="lb">끔</span>{ic("chev", 8, 1.8)}</span>', '녹음·전사 중(잠김)')}</div>''',
"""# ModelPicker

노트 사이드바 둘째 줄, `InputPicker` 옆 남은 폭을 채우는 전사 모델 선택입니다(`transcriptionModelMenu`).

- 높이 26, 좌우 8, 반경 7, primary 6% 채움. `waveform` 아이콘 + 모델 이름(12 Semibold, 끝 말줄임) + 아래 화살표 8.
- 누르면 AppKit 메뉴: 끔 / 클라우드 / 이 Mac에서 섹션. 녹음·전사 중에는 45%로 잠깁니다. 폭은 모델 이름에 따라 바뀌지 않습니다.
""")

# ---------- Settings ----------
C["SettingsCard"] = (330, "설정 페이지의 기본 단위", None, f'''<div class="q-stage col" style="background:var(--surface-window);padding:24px;gap:20px">
<div class="q-card"><div class="hd">{ic("power", 13, 1.6)}앱</div><div class="rows">
<label class="q-cb"><span class="box"></span>로그인 시 Quill 실행</label>
<label class="q-cb"><span class="box on"></span>메뉴 막대 아이콘 표시</label>
<div class="q-warnline"><span style="color:var(--status-processing)">{ic("warn", 10)}</span>시스템 설정에서 로그인 항목을 승인해야 해요.</div></div></div>
<div class="q-card"><div class="hd">{ic("wave", 13, 1.6)}전사<span style="flex:1"></span><span class="q-sw on"></span></div><div class="rows"><span class="q-help" style="margin-top:-6px">음성을 텍스트로 변환해요.</span>
<div style="display:flex;flex-direction:column;gap:6px"><span class="q-field-label">모델</span><span class="q-popup">Whisper Large v3 Turbo (기기 내){ic("chev", 9, 1.8)}</span></div>
<span class="q-help">기기 안에서 전사해요. 오디오가 밖으로 나가지 않아요.</span></div></div>
</div>''',
"""# SettingsCard

설정 페이지를 이루는 카드입니다(`SettingsCard`).

- `surface-card` + `hairline` 1pt, `radius-10`, 안쪽 `space-16`, 제목과 내용 사이 `space-12`.
- 제목: SF Symbol + 라벨, `headline`.
- 내용 규칙: 토글은 한 줄씩(간격 `space-10`), 피커는 위에 `caption` semibold 라벨 + 280~`size-settings-control` 컨트롤, 도움말 `caption` + `label-secondary`, 주의는 주황 삼각형 + `caption`, 오류는 `QuillUserIssueView` inline.
- 페이지: `SettingsPageScrollView` 안에서 바깥 `space-24`, 카드 사이 `space-20`.
- iPhone·iPad에서는 `List(.insetGrouped)`의 Section 하나(제목 = 섹션 머리, 도움말 = 섹션 꼬리).
""")

side_items = [("gear", "일반"), ("brush", "모양"), ("wave", "모델"), ("bubble", "프롬프트"), ("key", "단축키"), ("mic", "입력"), ("cal", "캘린더"), ("cloud", "iCloud 동기화"), ("link", "AI 도구"), ("undo", "기록 복구"), ("info", "정보")]
def sidebar(on="일반"):
    return '<div class="q-side">' + ''.join(f'<div class="it{" on" if t == on else ""}">{ic(i, 13, 1.4)}{t}</div>' for i, t in side_items) + '</div>'

C["SettingsSidebar"] = (480, "설정 탭 목록", None, f'''<div class="q-stage">{sidebar("모델")}</div>''',
"""# SettingsSidebar

설정 창 왼쪽 탭 목록입니다(`SettingsSidebarRow`). 폭 `size-sidebar-settings`, 안쪽 `space-10`, 행 간격 `space-2`. 행은 아이콘 13 Regular(16pt 틀) + `body`, 여백 10×8. 현재 탭은 `accent-tint-nav` + `radius-6`. 스크롤하지 않습니다. iPhone 설정 루트는 이 목록을 옮기지 않고 아이콘 없는 네 묶음(노트·연결·동기화·앱)으로 줄였습니다.
""")

C["OptionRow"] = (260, "하나를 고르는 선택 행", None, f'''<div class="q-stage col" style="background:var(--surface-window);width:440px">
<div class="q-opt"><span class="r"></span><div class="t0">마이크</div></div>
<div class="q-opt on"><span class="r">{ic("check", 9, 2.2)}</span><div class="t0">시스템 오디오</div></div>
<div class="q-opt"><span class="r"></span><div class="t0">마이크 + 시스템 오디오</div></div>
<div class="q-opt big on" style="margin-top:8px"><span class="r">{ic("check", 11, 2.2)}</span><div><div class="t">포인터를 올리면 경과 시간 표시</div><div class="s">파형을 표시하고 포인터를 올리면 녹음 경과 시간을 잠시 보여 줘요.</div></div></div>
</div>''',
"""# OptionRow

여러 선택지 중 하나를 고르는 행입니다(`MicrophoneOptionRow`, `OverlayWaveformModeOptionRow` 등). 설정의 오디오 소스, 마이크, 단축키, 녹음 오버레이와 온보딩에서 씁니다.

- 기본: `surface-control`(`controlBackgroundColor`) 바탕, 테두리 없음, `radius-8`, 안쪽 `space-12`(설명이 있으면 14).
- 선택: `accent` 10% 바탕 + `accent` 테두리 1.5(설명 있는 큰 행은 2).
- 왼쪽 표시: 선택은 `checkmark.circle.fill` `accent`, 나머지는 `circle` `label-secondary`. 큰 행은 20pt.
- 제목은 `body`(큰 행은 `headline`), 설명은 `caption` + `label-secondary`.
- 지금 코드는 `accent` 대신 `Color.blue`를 직접 쓰고, 행마다 테두리 두께와 여백이 조금씩 달라요(정리할 곳 참고). 새 선택 목록은 이 규칙을 따릅니다.
""")

C["ModelRow"] = (150, "모델 하나의 상태와 동작", None, f'''<div class="q-stage col" style="background:var(--surface-window)">
<div class="q-model on"><div style="flex:1"><div style="font-weight:600">Whisper Large v3 Turbo</div><div class="q-help">1.6GB · 설치됨 · 사용 중</div></div><button class="q-small-btn">삭제</button></div>
<div class="q-model"><div style="flex:1"><div style="font-weight:600">Qwen3-ASR 0.6B</div><div class="q-help">내려받는 중 · 620MB 중 384MB</div></div><span class="q-donut"></span><button class="q-small-btn">취소</button></div>
</div>''',
"""# ModelRow

기기 내 모델 저장소의 한 줄입니다(`ModelRowView`, `NativeWhisperModelRowView`, `LocalAIModelRowView`). `surface-control`, `radius-6`, 안쪽 `space-8`. 사용 중인 모델은 `accent-tint-selected` + `accent-stroke-selected`. 진행은 16pt 도넛(`DonutProgressView`), 오른쪽 작은 버튼 하나, 오류는 아래에 inline 이슈.
""")

# ---------- Screens macOS ----------
def audio_card():
    hs=[.3,.5,.4,.7,.9,.6,.8,.5,.35,.6,.75,.95,.7,.5,.4,.65,.85,.55,.4,.3,.5,.7,.6,.45,.8,.6,.4,.3,.55,.7,.5,.35,.6,.45,.3,.5,.4,.6,.35,.25]
    import math
    hs=[max(.08, .5*abs(math.sin(i*1.7))*abs(math.cos(i*.31))+.06*(i%3)) for i in range(110)]
    bars=''.join(f'<i style="height:{h*44:.1f}px"{" class=on" if i<38 else ""}></i>' for i,h in enumerate(hs))
    return (f'<div class="q-audio"><span class="pb">{ic("play", 11)}</span><div class="bars">{bars}</div>'
            f'<span class="tm">12:04 / 32:10</span><span class="vol">{ic("vol", 12)}</span></div>')

def ftool():
    return (f'<div class="q-ftool"><button class="q-tool lg">{ic("copy", 14)}</button><button class="q-tool lg">{ic("save", 14)}</button>'
            f'<span class="dv"></span><button class="q-tool lg" style="color:var(--status-recording)">{ic("trash", 14)}</button></div>')

def detail_pane(top=32):
    return f'''<div style="flex:1;min-width:0;display:flex;flex-direction:column;background:var(--surface-text);position:relative">
<div style="padding:{top}px 40px 14px;display:flex;flex-direction:column;gap:6px;box-shadow:inset 0 -.5px 0 var(--divider-sidebar)">
<div style="display:flex;align-items:center;gap:8px"><span class="q-meta-mono">2026년 10월 24일 (토) 오후 2:00–2:32</span><span class="q-tags"><span>CLOUD</span>·<span class="dim">NO CTX</span>·<span>LLM</span>·<span>KO</span></span></div>
<div style="font-size:28px;font-weight:700;line-height:38px;height:38px">주간 제품 회의</div>
<div style="padding-top:4px">{audio_card()}</div></div>
<div style="display:flex;justify-content:center;padding:12px 40px 4px"><span class="q-seg"><span class="on">전사문</span><span>요약</span></span></div>
<div style="padding:12px 40px 0;display:flex;flex-direction:column;gap:12px;flex:1">
<div class="q-banner"><span class="warn">{ic("warn", 11)}</span><span class="ttl">요약을 확인해 주세요</span><span class="det">이름이 두 번 다르게 적혔어요.</span><span class="sp"></span><button class="q-more">+1</button></div>
<div class="q-body">출시 일정과 QA 범위를 이야기했어요. 다음 주까지 온보딩 문구를 정리하고, 화요일에 다시 확인하기로 했어요.<br><br>알림 묶음은 +N 알약 하나로 충분하다는 의견이 많았어요.</div>
</div>
<div style="position:absolute;bottom:20px;left:0;right:0;display:flex;justify-content:center">{ftool()}</div>
</div>'''

detail = detail_pane()

C["NoteToolbar"] = (110, "노트 상세 아래 떠 있는 동작 캡슐", None, f'''<div class="q-stage text" style="flex-direction:column;align-items:center;gap:14px">{ftool()}<div class="q-ftool"><button class="q-tool lg" style="color:var(--status-processing)">{ic("undo", 14).replace('<svg', '<svg style="transform:scaleX(-1)"')}</button><span class="dv"></span><button class="q-tool lg">{ic("copy", 14)}</button><button class="q-tool lg">{ic("save", 14)}</button><button class="q-tool lg">{ic("sparkle", 14)}</button><span class="dv"></span><button class="q-tool lg" style="color:var(--status-recording)">{ic("trash", 14)}</button></div></div>''',
"""# NoteToolbar

노트 상세 아래 가운데에 떠 있는 동작 캡슐입니다. 두 앱이 같은 공유 뷰를 씁니다: 공개 `quill` 레포 `Packages/QuillNoteUI`의 `NoteFloatingToolbar`(화면)와 `NoteToolbarState`(#690 상태표, #697). 앱은 노트 상태를 `NoteToolbarInput`으로 넘기고 동작을 받기만 합니다. 높이 48(iPhone 56), 아래 여백 20, 좌우 8. 배경은 유리(macOS·iOS 26 이상 `glassEffect`, 이전은 `.ultraThinMaterial`, 투명도 줄이기에서는 불투명), 테두리 `stroke-glass` 0.6, 그림자 `shadow-glass`.

- 버튼은 36pt 원형(iPhone 44pt), 아이콘 13 Medium. 순서: [첫 자리] | 복사 · 파일 저장 · [요약 만들기] | 삭제. 구분선은 0.5×18, primary 12%. 꺼진 버튼은 자리를 지킨 채 흐려집니다(35%). 사라지지 않습니다.
- 열린 탭을 따라갑니다(#262): 요약 탭의 첫 자리는 요약 다시 만들기, 전사 탭의 첫 자리는 다시 전사입니다. 다시 만들기 아이콘은 `status-processing`(주황), 삭제는 `status-recording` 80%.
- 요약이 없을 때만 전사 탭에 요약 만들기(`sparkles`)가 붙습니다. 전사·후처리 중에는 흐린 채 자리를 지키다 둘 다 끝나면 켜집니다. 복사하면 아이콘이 잠깐 체크 표시 + `accent`.
- 복사는 열린 탭의 내용(전사문 또는 요약)을 복사합니다. 파일 저장(전사문·요약·오디오)과 삭제(노트 전체·요약만)는 어느 탭에서나 같은 창을 엽니다.
- 파일 저장 자리는 Mac `square.and.arrow.down`, iPhone 공유 시트 `square.and.arrow.up`입니다.

## 상태별 모양 (#690, 2026-10-28 결정)

Mac과 iPhone이 같은 규칙을 씁니다. 규칙은 `NoteToolbarState`(QuillNoteUI) 한 곳에 있습니다(#697). 앱이 그 노트를 취소할 길이 없으면 ✕ 대신 진행 표시를 둡니다.

- 툴바를 숨기는 때는 셋뿐입니다: 녹음 중인 노트(녹음 패널이 대신), 요약·전사 후보를 비교하는 동안(고르기 막대가 대신), iPhone에서 키보드를 올려 고치는 동안(키보드를 가리지 않게). Mac은 고치는 동안에도 툴바를 둡니다.
- 그 밖에는 작업 중에도 툴바를 두고 버튼만 켜고 끕니다. 꺼진 버튼은 흐리게 그립니다.
- 전사 탭의 첫 자리는 전사 작업 중에 ✕ 취소(취소 중에는 진행 표시)가 됩니다. 요약 탭은 전사 작업 중에도 요약 탭 툴바를 보이고, 요약을 만드는 동안 첫 자리가 ✕ 취소가 됩니다.
- 파일 저장과 삭제는 두 탭이 함께 켜지고 꺼집니다(같은 창이라서). 어떤 작업(전사·후처리·요약) 중이든 둘 다 끕니다.
- 복사는 열린 탭의 내용이 바뀌는 중이면 끕니다(전사 작업 중의 전사 탭, 요약을 만드는 동안의 요약 탭).

| 상태 | 전사 탭 | 요약 탭 |
|---|---|---|
| 평소(완료) | 모두 켜짐. 요약 만들기는 요약이 없을 때만 | 모두 켜짐 |
| 녹음 중 | 툴바 없음 | 툴바 없음 |
| 전사 대기·전사 중·다시 전사 중 | ✕ 취소만 켜짐 | 다시 만들기 꺼짐, 복사 켜짐, 저장·삭제 꺼짐 |
| 취소 중 | 첫 자리 진행 표시, 모두 꺼짐 | 다시 만들기 꺼짐, 복사 켜짐, 저장·삭제 꺼짐 |
| 후처리 중(대기 포함) | ✕ 취소만 켜짐 | 다시 만들기 꺼짐, 복사 켜짐, 저장·삭제 꺼짐 |
| 요약 만드는 중 | 다시 전사 꺼짐, 복사 켜짐, 저장·삭제 꺼짐(요약 탭으로 넘어가 요약 만들기는 없음) | 첫 자리 ✕ 취소, 복사·저장·삭제 꺼짐 |
| 전사 실패·오디오만 | 첫 자리 전사하기, 복사 꺼짐, 저장(오디오)·삭제 켜짐 | 요약이 있으면 평소(완료)와 같음 |
| 후보 비교 중 | 고르기 막대가 툴바 대신 | 같음 |
| 고치는 중 | Mac은 그대로, iPhone은 키보드가 올라와 있는 동안 숨김 | 같음 |

첫 전사에는 요약 탭이 아직 없습니다. 요약 탭 칸은 요약이 있는 노트를 다시 전사하거나 다듬을 때의 모양입니다. 지우려면 먼저 ✕로 작업을 멈춥니다.

취소의 뜻:

- **첫 전사:** 전사만 멈추고 녹음은 남깁니다(노트는 오디오만). Mac의 받아쓰기 중 Esc 취소(세션 버리기)는 따로입니다.
- **다시 전사:** 다시 전사를 멈추고 원래 전사문을 그대로 둡니다.
- **후처리:** 다듬기를 멈추고 원래 전사문을 둡니다. 실패가 아니라 후처리하지 않은 노트로 남고, 다른 기기에 경고가 뜨지 않습니다. 기다리는 중에 취소하면 기다리던 다듬기를 뺍니다.
- **요약:** 만들기를 멈추고 이전 요약이 있으면 그대로 둡니다.
""")

C["AudioPlayer"] = (120, "노트 머리의 오디오 카드", None, f'''<div class="q-stage text" style="flex-direction:column"><div style="width:560px">{audio_card()}</div></div>''',
"""# AudioPlayer

노트 상세 머리, 제목 아래에 붙는 오디오 카드입니다(`NoteAudioBar` → `NoteAudioPlayerView`). 높이 72, 반경 `radius-12`, 안쪽 16×14.

- 배경은 `accent` 6%에서 투명으로 흐르는 대각 그라데이션 + primary 8% 0.5 테두리, 그림자 두 겹(0 4 12 검정 8%, 0 1 3 검정 4%).
- 왼쪽 36pt 유리 원 재생/일시정지(11 Semibold), 가운데 파형 막대(높이 44, 재생한 부분 `accent`, 나머지 primary 45%, 끌어서 이동), 오른쪽 `경과 / 전체` SF Mono 11 + 소리 크기 버튼(팝오버 슬라이더).
- 오디오가 iCloud에만 있으면 같은 자리에 받기 막대, 오디오가 없는 노트는 카드 없음.
- iPhone: 같은 공유 파형, 최소 높이 72(접근성 크기 88), 반경 16, 바탕 `surfaceRaised` + 0.5 테두리 + 옅은 그림자. 시간은 `.footnote` SF Mono Semibold.
""")
macnotes = f'''<div class="q-stage" style="background:var(--surface-window)"><div class="q-mac" style="width:900px;height:520px">
<div style="width:280px;flex:none;display:flex;flex-direction:column;background:color-mix(in srgb, var(--surface-window) 88%, transparent);box-shadow:inset -.5px 0 0 var(--divider-sidebar);position:relative">
<div style="display:flex;align-items:center;gap:4px;padding-right:10px;height:52px"><div class="q-lights" style="padding:0 0 0 14px"><i></i><i></i><i></i></div><span style="flex:1"></span><button class="q-hicon">{ic("search", 13)}</button><button class="q-hicon">{ic("import", 13)}</button><button class="q-capsule">선택</button></div>
<div style="display:flex;gap:6px;padding:0 12px 8px"><span class="q-input">{ic("mic", 11)}{ic("chev", 8, 1.8)}</span><span class="q-input model">{ic("wave", 12)}<span class="lb">Whisper Large v3 Turbo</span>{ic("chev", 8, 1.8)}</span></div>
<div class="q-list" style="background:none;width:auto">{row("주간 제품 회의", "출시 일정과 QA 범위를 이야기했어요.", cls="sel", badges='<span class="q-badge">요약</span>')}{row("고객 인터뷰 정리", "가장 자주 나온 불편은 녹음 파일 찾기였어요.", date="10월 23일 (금) 오전 11:20")}{row("팀 스탠드업", "전사하는 중이에요…", date="10월 23일 (금) 오전 11:20", status='<span class="q-spin"></span>')}{row("아이디어 메모", "알림은 한 줄로.", date="10월 21일 (수) 오전 9:05")}</div>
<div style="position:absolute;bottom:16px;left:0;right:0;display:flex;justify-content:center"><span class="q-rec"></span></div>
</div>{detail}</div></div>'''
C["MacNoteBrowser"] = (560, "노트 브라우저 전체 배치", 940, macnotes,
"""# MacNoteBrowser

노트 브라우저 창의 배치 예시입니다(정적 재현, `NoteBrowserView` 기준).

- **사이드바**(`size-sidebar-notes`, 유리): 첫 줄은 신호등 버튼과 같은 줄에 검색·오디오 가져오기 아이콘 버튼과 `선택` 캡슐. 둘째 줄은 입력 선택(66×26)과 전사 모델 선택(남은 폭). 검색을 열면 둘째 줄이 검색 필드로 바뀌고, 선택 모드에서는 선택 개수와 `모두 선택`으로 바뀝니다. 아래에 `NoteListRow` 목록, 맨 아래 가운데 녹음 버튼.
- **상세**(`surface-text`, 좌우 `space-40`): 머리(날짜 줄 SF Mono 10 대문자 + `CLOUD · CTX · LLM` 태그 → 제목 28 Bold → 오디오 카드) → 구분선 → 가운데 세그먼트(`전사` / `요약`, 요약이 있을 때만) → 배너 → 본문 → 아래 가운데 떠 있는 `NoteToolbar`.
""")

macset = f'''<div class="q-stage" style="background:var(--surface-window)"><div class="q-mac" style="width:900px;height:520px;background:var(--surface-window)">
<div style="flex:none;box-shadow:inset -1px 0 0 var(--hairline-strong)"><div class="q-lights" style="padding-bottom:6px"><i></i><i></i><i></i></div>{sidebar("일반")}</div>
<div style="flex:1;padding:40px 24px 24px;display:flex;flex-direction:column;gap:20px;overflow:hidden">
<div class="q-card"><div class="hd">{ic("power", 13, 1.6)}앱</div><div class="rows"><label class="q-cb"><span class="box"></span>로그인 시 Quill 실행</label><label class="q-cb"><span class="box on"></span>메뉴 막대 아이콘 표시</label></div></div>
<div class="q-card"><div class="hd">{ic("undo", 13, 1.6)}업데이트</div><div class="rows"><label class="q-cb"><span class="box on"></span>업데이트 자동 확인</label><div style="display:flex;gap:10px;align-items:center"><button class="q-small-btn">지금 업데이트 확인</button><span class="q-help">마지막 확인: 2026년 10월 24일 오후 10:24</span></div></div></div>
<div class="q-card"><div class="hd">{ic("lock", 13, 1.6)}권한</div><div class="rows" style="gap:8px"><div class="q-perm"><span class="pi">{ic("mic", 13)}</span><span>마이크</span><span style="flex:1"></span><span class="ok">{ic("check", 10, 2)}</span><span class="okt">허용됨</span></div><div class="q-perm"><span class="pi">{ic("key", 13)}</span><span>손쉬운 사용</span><span style="flex:1"></span><button class="q-small-btn">접근 허용</button></div><div class="q-perm"><span class="pi">{ic("wave", 13)}</span><span>음성 인식</span><span style="flex:1"></span><span class="ok">{ic("check", 10, 2)}</span><span class="okt">허용됨</span></div><div class="q-perm"><span class="pi">{ic("doc", 13)}</span><span>화면 기록</span><span style="flex:1"></span><span class="ok">{ic("check", 10, 2)}</span><span class="okt">허용됨</span></div><div class="q-perm"><span class="pi">{ic("info", 13)}</span><span>알림</span><span style="flex:1"></span><button class="q-small-btn">접근 허용</button></div></div></div>
</div></div></div>'''
C["MacSettings"] = (560, "설정 창 · 일반 탭", 940, macset,
"""# MacSettings

설정 창 배치 예시입니다(정적 재현). 왼쪽 `SettingsSidebar`, 오른쪽 `SettingsCard`를 세로로 쌓은 페이지(첫 카드는 위에서 40). 탭별 카드 목록은 **화면 구성** 섹션의 표.
""")

# ---------- Screens iPhone ----------
def irow(t, p, d="10월 24일 (토) 오후 2:00 · 12:48", st='<span class="q-dot done"></span>', b=""):
    return f'<div class="q-irow"><div class="meta"><span class="date">{d}</span>{b}<span style="flex:1"></span>{st}</div><div class="ttl">{t}</div><div class="pv">{p}</div></div>'

def ihead(model="Whisper Large v3 Turbo"):
    return f'<div class="q-ihead"><span class="cap">{ic("wave", 14)}<span class="lb">{model}</span>{ic("chev", 10, 1.8)}</span><span class="act">{ic("search", 18, 1.6)}{ic("dots", 18)}</span></div>'

phone_list = f'''<div class="q-phone" style="background:var(--surface-window)"><div class="island"></div><div class="status"></div>
{ihead()}
<div class="q-ilist">{irow("주간 제품 회의", "출시 일정과 QA 범위를 이야기했어요. 다음 주까지 온보딩 문구를 정리하기로 했어요.", "10월 24일 (토) 오후 2:00 · 32:10", b='<span class="q-badge">요약</span>')}{irow("고객 인터뷰 정리", "가장 자주 나온 불편은 녹음 파일을 찾기 어렵다는 점이었어요.", "10월 23일 (금) 오전 11:20 · 4:32")}{irow("팀 스탠드업", "전사하는 중이에요…", "10월 23일 (금) 오전 9:05 · 9:15", '<span class="q-spin"></span>')}{irow("2026년 10월 22일 오후 3:40", "전사되지 않음", "10월 22일 (목) 오후 3:40 · 0:58")}</div>
<span class="q-ifab"></span><div class="home"></div></div>'''
phone_detail = f'''<div class="q-phone" style="background:var(--surface-window)"><div class="island"></div><div class="status"></div>
<div style="padding:0 16px;flex:none"><span class="q-iback">{ic("back", 16, 2)}</span></div>
<div style="padding:16px 16px 0;display:flex;flex-direction:column;gap:10px;flex:1">
<div class="q-meta-mono" style="font-size:10px;letter-spacing:.2px;color:var(--label-secondary)">2026년 10월 24일 (토) 오후 2:00~2:32<br><span style="font-size:9px;font-weight:500">LOCAL · <span style="opacity:.71">NO CTX</span> · LLM · KO</span></div>
<div style="font-size:28px;font-weight:700;line-height:32px;letter-spacing:-.3px">주간 제품 회의</div>
<div class="q-audio" style="border-radius:16px;padding:12px 14px;background:var(--surface-control)"><span class="pb">{ic("play", 11)}</span><div class="bars">{''.join(f'<i style="height:{h}px"{" class=on" if i<8 else ""}></i>' for i,h in enumerate([10,18,14,26,32,22,28,18,12,22,26,34,24,18,14,22,30,20,14,10]))}</div><span class="tm" style="font-size:13px;font-weight:600">0:00 / 32:10</span></div>
<div class="q-seg" style="display:flex;font-size:13px"><span class="on" style="flex:1;text-align:center">전사문</span><span style="flex:1;text-align:center">요약</span></div>
<div style="font-size:15px;line-height:21px">출시 일정과 QA 범위를 이야기했어요. 다음 주까지 온보딩 문구를 정리하고, 화요일에 다시 확인하기로 했어요.</div></div>
<div style="position:absolute;bottom:28px;left:0;right:0;display:flex;justify-content:center"><div class="q-ftool"><button class="q-tool lg" style="color:var(--status-processing)">{ic("undo", 14).replace('<svg', '<svg style="transform:scaleX(-1)"')}</button><span class="dv"></span><button class="q-tool lg">{ic("copy", 14)}</button><button class="q-tool lg">{ic("share", 14)}</button><span class="dv"></span><button class="q-tool lg" style="color:var(--status-recording)">{ic("trash", 14)}</button></div></div>
<div class="home"></div></div>'''
phone_rec = f'''<div class="q-phone" style="background:var(--surface-window)"><div class="island live"><span style="width:16px;height:16px;border-radius:5px;background:url({ICON}) center/cover"></span><span style="color:#fff;font-size:12px;font-weight:600;font-variant-numeric:tabular-nums">3:12</span></div><div class="status"></div>
{ihead()}
<div class="q-ilist">{irow("2026년 10월 24일 오후 3:00", "", "10월 24일 (토) 오후 3:00 · 3:12", '<span style="color:var(--status-recording);font-size:11px;font-weight:600;font-family:var(--font-mono)">REC 3:12</span>')}{irow("주간 제품 회의", "출시 일정과 QA 범위를 이야기했어요. 다음 주까지 온보딩 문구를 정리하기로 했어요.", "10월 24일 (토) 오후 2:00 · 32:10", b='<span class="q-badge">요약</span>')}</div>
<div class="q-recbar"><span class="st"><span class="q-dot rec"></span>녹음 중</span><span class="tm">3:12</span><span class="b">{ic("pause", 14)}</span><span class="b stop"></span></div><div class="home"></div></div>'''
C["PhoneNotes"] = (700, "목록 → 상세 → 녹음 중", 1080, f'<div class="q-stage" style="gap:40px;padding:24px 28px;background:var(--surface-window)">{phone_list}{phone_detail}{phone_rec}</div>',
"""# PhoneNotes

iPhone 노트 흐름입니다(지금 앱 구조의 정적 재현, 색은 macOS 토큰으로 근사). 탭 없이 `NavigationStack` 하나입니다.

- **노트 목록**: 큰 제목 없이 위에 고정된 머리 한 줄(전사 방식 캡슐 / 검색 · `…`). 설정과 최근 삭제된 노트는 `…` 메뉴에 있습니다. 행은 macOS `NoteListRow`를 옮긴 공유 뷰로, 화면 폭 가득·고정 높이이고 메타 줄에 녹음 길이가 붙습니다. 아래 가운데 56pt 녹음 버튼.
- **노트 상세**(push): 원형 뒤로가기만 있는 막대 → 메타 줄(SF Mono 10, 칩 9, 좁은 폭에서는 날짜와 칩을 두 줄로) → 제목 28 Bold → 오디오 카드(72, 반경 16) → 세그먼트(요약이 있을 때만) → 본문 15. 아래에 macOS와 같은 `NoteToolbar` 캡슐.
- **녹음 중**: 전체 화면 시트 없이 화면 아래 짙은 회색 녹음 막대(상태 · 시간 · 일시정지 · 정지)가 모든 화면 위에 남습니다. Dynamic Island에는 앱 아이콘과 타이머만, 파형은 없습니다.

크기·글자 대응은 **iPhone · iPad** 섹션.
""")

def sec(header, rows_html, footer=""):
    f = f'<div class="q-sec-f">{footer}</div>' if footer else ''
    return f'<div class="q-sec-h">{header}</div><div class="q-sec">{rows_html}</div>{f}'

def li(icon, text, value="", tog=None, color=None):
    c = f' style="background:{color}"' if color else ''
    ico = f'<span class="ic"{c}>{ic(icon, 16, 1.5)}</span>' if icon else ''
    right = f'<span class="v">{value} ›</span>' if value else ''
    if tog is not None:
        right = f'<span class="q-itog{"" if tog else " off"}"></span>'
    return f'<div class="li">{ico}<span>{text}</span>{right}</div>'

def iset_nav(title):
    return f'<div style="display:flex;align-items:center;padding:0 16px;height:40px;flex:none;position:relative"><span class="q-iback">{ic("back", 16, 2)}</span><span style="position:absolute;left:0;right:0;text-align:center;font-weight:600;font-size:17px;pointer-events:none">{title}</span></div>'

phone_set_root = f'''<div class="q-phone" style="background:var(--surface-window)"><div class="island"></div><div class="status"></div>
{iset_nav("설정")}
<div class="q-group">{sec("노트", li("", "모델", " "))}
{sec("연결", li("", "캘린더", "켬"))}
{sec("동기화", li("", "iCloud", "최신 상태"))}
{sec("앱", li("", "정보", "1.0.0"))}</div><div class="home"></div></div>'''
phone_set_models = f'''<div class="q-phone" style="background:var(--surface-window)"><div class="island"></div><div class="status"></div>
{iset_nav("모델")}
<div class="q-group">{sec("클라우드", li("", "API 제공업체", "켬"))}
{sec("전사", li("", "전사", tog=True) + li("", "전사 모델", "Whisper") + li("", "전사 언어", "자동"), "녹음을 글로 바꿔요.")}
{sec("후처리", li("", "후처리", tog=False))}
{sec("회의 요약", li("", "회의 요약", tog=True) + li("", "모델", "Gemma 4 E2B"))}</div><div class="home"></div></div>'''
C["PhoneSettings"] = (700, "설정 루트와 모델 화면", 700, f'<div class="q-stage" style="gap:40px;padding:24px 28px;background:var(--surface-window)">{phone_set_root}{phone_set_models}</div>',
"""# PhoneSettings

iPhone 설정입니다(지금 앱 구조의 정적 재현, 색은 macOS 토큰으로 근사). 노트 목록 `…` 메뉴의 `설정`에서 push로 엽니다.

- **루트**: `List(.insetGrouped)`, inline 제목. macOS 탭 목록을 옮기지 않고 아이콘 없는 네 묶음으로 줄였습니다: 노트 › 모델 / 연결 › 캘린더 / 동기화 › iCloud / 앱 › 정보. 캘린더·iCloud·정보 행은 오른쪽에 값과 꺾쇠, 모델 행은 이름만.
- **모델**: 한 화면에 클라우드 → 전사 → 후처리 → 회의 요약 섹션. macOS `SettingsCard` 하나가 Section 하나이고, 카드 머리 스위치는 섹션 첫 줄 스위치(시스템 녹색)가 됩니다. 모델 행을 누르면 체크 표시 목록에서 고릅니다.

유지·변형·제외 표는 **iPhone · iPad** 섹션.
""")

# ---------- Screens iPad ----------
pad_notes = f'''<div class="q-stage" style="padding:28px;background:var(--surface-window)"><div class="q-tablet">
<div style="width:280px;flex:none;background:var(--surface-window);box-shadow:inset -.5px 0 0 var(--divider-sidebar);display:flex;flex-direction:column;position:relative">
<div class="q-nav" style="margin-top:14px"><span>{ic("sidebar", 18, 1.4)}</span><span style="display:flex;gap:16px">{ic("gear", 18, 1.4)}{ic("dots", 18)}</span></div>
<div class="q-large" style="font-size:28px">노트</div>
<div style="display:flex;gap:8px;padding:0 12px 8px"><span class="q-input" style="height:34px;width:72px;border-radius:10px">{ic("mic", 13)}{ic("chev", 10, 1.8)}</span><div class="q-search" style="margin:0;flex:1">{ic("search", 14)}검색</div></div>
<div class="q-list" style="width:auto;background:none">{row("주간 제품 회의", "출시 일정과 QA 범위를 이야기했어요.", cls="sel", badges='<span class="q-badge">요약</span>')}{row("고객 인터뷰 정리", "가장 자주 나온 불편은 녹음 파일 찾기였어요.", date="10월 23일 (금) 오전 11:20")}{row("팀 스탠드업", "전사하는 중이에요…", date="10월 23일 (금) 오전 11:20", status='<span class="q-spin"></span>')}</div>
<div style="position:absolute;bottom:20px;left:0;right:0;display:flex;justify-content:center"><span class="q-rec"></span></div></div>
{detail_pane(28)}</div></div>'''
C["PadNotes"] = (680, "두 열 노트 화면 (제안)", 920, pad_notes,
"""# PadNotes

iPad 노트 화면 제안입니다(정적 재현). `NavigationSplitView` 두 열 — macOS 노트 브라우저와 같은 구조(상세 머리에 오디오 카드, 아래 가운데 `NoteToolbar`), 사이드바 280(`size-sidebar-notes`), 녹음 버튼 44, 본문 최대 폭 680. 선택 행은 macOS와 같은 `fill-selected` 카드(결정할 것 2번). 창 폭이 800보다 좁으면 목록과 노트가 따로 된 화면입니다(`QuillNoteLayout`). iPad 앱은 아직 없습니다.
""")

pad_set = f'''<div class="q-stage" style="padding:28px;background:var(--surface-window)"><div class="q-tablet" style="background:var(--surface-window)">
<div style="width:320px;flex:none;box-shadow:inset -.5px 0 0 var(--divider-sidebar);padding-top:20px">
<div class="q-large" style="font-size:28px">설정</div>
<div class="q-sec">{li("gear", "일반")}{li("brush", "모양")}<div class="li" style="background:var(--accent);color:#fff"><span class="ic" style="background:#fff;color:var(--accent)">{ic("wave", 16)}</span><span>모델</span></div>{li("bubble", "프롬프트")}{li("key", "단축키")}{li("mic", "입력")}{li("cal", "캘린더", color="var(--status-recording)")}{li("cloud", "iCloud 동기화")}{li("undo", "기록 복구", color="var(--label-secondary)")}{li("info", "정보", color="var(--label-secondary)")}</div></div>
<div style="flex:1;padding-top:20px"><div style="text-align:center;font-weight:600;font-size:17px;padding-bottom:6px">모델</div>
<div style="max-width:560px;margin:0 auto">{sec("클라우드 제공자", li("", "제공자", "OpenAI") + li("", "API 키", "저장됨"))}{sec("전사", li("", "모델", "기기 내 Whisper") + li("", "실시간 전사 옵션 보기", tog=False), "기기 안에서 전사해요. 오디오가 밖으로 나가지 않아요.")}{sec("회의 요약", li("", "모델", "기기 내 Gemma"))}</div></div>
</div></div>'''
C["PadSettings"] = (680, "두 열 설정 (제안)", 920, pad_set,
"""# PadSettings

iPad 설정 제안입니다(정적 재현). 왼쪽 탭 목록(macOS 사이드바와 같은 순서·아이콘, Mac 전용인 AI 도구는 제외)과 오른쪽 해당 페이지의 insetGrouped 섹션(최대 폭 560 가운데). iPhone처럼 네 묶음으로 줄일지는 iPad 작업 때 정합니다. 별도 창으로 열지 시트로 열지는 결정할 것 3번.
""")

ORDER = {'1 · 원자': ['Badge', 'StatusIndicator', 'SelectionCheckbox', 'Waveform', 'CapsuleButton', 'IconButton', 'CloseButton', 'ToolbarButton', 'RecordButton'], '2 · 분자': ['InputPicker', 'ModelPicker', 'SearchField', 'NoteListRow', 'StatusBanner', 'InfoNotice', 'Toast', 'NoticeToast', 'DeletionCapsule', 'AudioPlayer', 'OptionRow', 'ModelRow'], '3 · 유기체': ['RecordingOverlay', 'MeetingReminder', 'NoteToolbar', 'IssueEmptyState', 'SettingsCard', 'SettingsSidebar'], '4 · 화면 · macOS': ['MacNoteBrowser', 'MacSettings'], '5 · 화면 · iPhone': ['PhoneNotes', 'PhoneSettings'], '6 · 화면 · iPad': ['PadNotes', 'PadSettings']}
GROUP = {n: g for g, ns in ORDER.items() for n in ns}
NAMES = [n for ns in ORDER.values() for n in ns]
assert sorted(NAMES) == sorted(C), set(NAMES) ^ set(C)
import json
for name in NAMES:
    height, subtitle, width, body, readme = C[name]
    group = GROUP[name]
    d = os.path.join(ROOT, "components", name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "preview.html"), "w") as f:
        f.write(doc(name, body, group, height, subtitle, width))
    with open(os.path.join(d, "README.md"), "w") as f:
        f.write(readme)
header = {"format": 4, "namespace": "Quill", "components": [{"name": n} for n in NAMES]}
with open(os.path.join(ROOT, "components", "bundle.js"), "w") as f:
    f.write("/* @ds-bundle: " + json.dumps(header, ensure_ascii=False) + " */\n")
    f.write("/* Quill는 SwiftUI 앱이라 웹 컴포넌트 코드가 없습니다. 미리보기는 정적 재현이고, 이 파일은 컴포넌트 순서만 정합니다. */\n")
    f.write("window.Quill = {};\n")
print(len(C), "components")
