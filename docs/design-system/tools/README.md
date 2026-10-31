# 디자인 시스템 관리

`docs/design-system/`은 Quill 디자인 시스템의 기준본입니다. 같은 내용을 claude.ai의 Design System 아티팩트로도 게시하는데, 고칠 때는 이 폴더를 먼저 고치고 아티팩트에 다시 올립니다.

## 폴더 구성

| 경로 | 내용 |
| --- | --- |
| `README.md` | 원칙, 콘텐츠, 색, 글자, 간격, 모양, 움직임, 접근성, 컴포넌트 구성, 아이콘 |
| `1-screens.md` | macOS 화면 구성(설정 탭별 카드 포함) |
| `2-platforms.md` | iPhone 실제 구성(`quill-universal` 기준)과 iPad 제안, 확정한 것, 남은 결정 |
| `3-consistency.md` | 지금 코드에서 규칙을 벗어난 곳 |
| `tokens.json` | 색(라이트·다크), 글자, 간격, 반경, 그림자, 불투명도, 크기 토큰 |
| `components/<이름>/` | 컴포넌트별 `README.md`(사용 규칙)와 `preview.html`(정적 재현) |
| `components/bundle.css` | 미리보기 공통 스타일 |
| `components/bundle.js` | 컴포넌트 순서만 정하는 머리 줄(원자 → 분자 → 유기체 → 화면) |
| `components/Cover/preview.html` | 아티팩트 표지 |
| `design-system.json`, `assets/` | 아티팩트 색인과 에셋 설명(앱 아이콘 원본은 `Resources/`) |
| `tools/` | 생성·미리보기 스크립트 |

## 컴포넌트 고치기

컴포넌트의 `preview.html`과 `README.md`는 `tools/gen_components.py`가 만듭니다. 직접 고치지 말고 스크립트를 고친 뒤 다시 만듭니다. 예외는 표지(`components/Cover/preview.html`)로, 손으로 고치는 파일이며 로컬 갤러리에는 나오지 않고 아티팩트에서만 보입니다.

```bash
python3 docs/design-system/tools/gen_components.py docs/design-system
```

- 묶음과 순서는 스크립트 끝의 `ORDER`에서 정합니다. 새 컴포넌트는 `C["이름"]`을 추가하고 `ORDER`에도 넣습니다.
- 공통 스타일은 `components/bundle.css`를 직접 고칩니다.
- 앱 아이콘이 들어가는 미리보기는 `tools/app-icon-64.png`를 `data:` 주소로 넣습니다(아티팩트 미리보기 안에서는 업로드 주소가 열리지 않음).

## Swift 토큰과 맞추기

Mac과 iPhone이 함께 쓰는 Swift 모듈 `Packages/QuillDesignTokens`가 `tokens.json`의 일부를 Swift 값으로 가지고 있습니다(#623). 지금 들어 있는 것은 다음과 같습니다.

- 간격·반경 단계 전부(`space-32`, `radius-16`, `radius-20`은 #736에서 추가).
- 색 `issue-warning`·`issue-error`·`surface-note`·`surface-page-iphone`, 틴트 `stroke-glass`·`fill-toolbar-hover`·`fill-pressed`·`hairline-strong`·`hairline`·`fill-banner`·`fill-chip`·`fill-hover`·`fill-selected`·`stroke-selected`·`fill-empty-disc`·`record-ring`·`accent-tint-selected`·`accent-stroke-selected`·`accent-tint-arrived`·`accent-tint-nav`·`accent-highlight`(`QuillColor`).
- 그림자 `shadow-glass`·`shadow-status`·`shadow-banner`·`shadow-record`, 라이트·다크 값이 다른 `shadow-row-selected`(`QuillShadow`, `QuillSchemeShadow`).
- 불투명도 `opacity-status-wash`.
- 글자 `note-title`·`empty-title`·`row-title`·`transcript`·`callout`·`row-preview`·`banner-title`·`meta-label`·`badge-label`·`meta-mono`·`meta-chip-mono`·`status-title`·`status-percent`·`status-detail`(`QuillTypeStyle`: macOS는 고정 크기, iOS는 Dynamic Type. 메타 줄 두 스타일은 iOS에서도 macOS 크기에서 `.caption2` 기준으로 커짐. 자간이 플랫폼마다 다르면 `letterSpacingIphone`. 화면에서는 `quillTextStyle(_:)`로 그림).
- 크기 `size-note-toolbar`·`size-note-toolbar-button`(`-iphone`)·`size-status-progress`·`size-touch-min`·`size-note-row`·`size-checkbox`(`-iphone`)·`size-status-dot`·`size-empty-disc`·`size-record-button`(`-iphone`)(`QuillControlSize`).
- 노트 배치 크기 `size-sidebar-notes`·`size-note-margin-compact`·`size-note-margin-regular`·`size-note-body-max-width`(`QuillLayoutSize`, #697), 폭 경계 `breakpoint-regular`·`breakpoint-wide`.

#736 1단계에서 더한 토큰은 아직 두 앱 어느 화면도 읽지 않습니다(화면별로 다음 단계에서 옮김). `Tests/QuillDesignTokensTests.swift`가 두 파일을 비교하므로, 토큰을 더하거나 바꾸면 양쪽을 함께 고칩니다(`make check`에서 실패로 드러남).

- 이름은 두 앱이 같이 쓰고, 플랫폼마다 값이 다르면 `-iphone` 토큰을 따로 둡니다(예: 툴바 버튼 macOS 36, iPhone 44).
- 공통 노트 툴바(`QuillNoteUI`)는 이 모듈의 값을 씁니다. 다른 색과 그림자는 그 값을 쓰는 화면을 옮길 때 같은 방식으로 추가합니다.
- 두 앱의 나머지 화면을 이 모듈로 옮기는 일(iPhone의 `QuillVisualSystem` 포함)은 출시 뒤 #697에서, 지금 다른 값을 먼저 맞춘 다음 진행합니다.

## 로컬에서 보기

```bash
python3 docs/design-system/tools/build_gallery.py docs/design-system /tmp/quill-design-system.html
open /tmp/quill-design-system.html
```

모든 컴포넌트를 묶음 순서대로 한 페이지에 보여 주고, 위쪽 체크박스로 다크 테마를 확인할 수 있습니다. 결과 파일은 커밋하지 않습니다.

## 실제 앱과 맞추기

미리보기는 SwiftUI 코드를 손으로 다시 그린 것입니다. 화면을 바꾸는 PR에서는 관련 컴포넌트의 미리보기와 규칙도 같이 고칩니다. 실제 앱 화면과 비교할 때는 Quill Dev를 띄워 확인하고, 노트 내용이 보이는 캡처는 저장소나 아티팩트에 넣지 않습니다.

## 아티팩트에 다시 올리기

Claude Code에서 이 폴더 기준으로 아티팩트를 고쳐 달라고 요청합니다. 아티팩트의 `project/` 아래 경로가 이 폴더의 경로와 같습니다(`tools/`는 올리지 않음). `design-system.json`은 게시된 최신본을 먼저 읽고 `lastChange`만 바꿔서 마지막에 올립니다.
