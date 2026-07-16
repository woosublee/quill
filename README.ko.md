<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="Quill 아이콘">
</p>

<h1 align="center">Quill</h1>

<p align="center">
  <a href="README.md">English</a> · 한국어
</p>

<p align="center">
  생각과 회의 메모, 수정할 내용을 Mac의 어떤 앱에서든 말하고 바로 사용할 수 있는 다듬어진 글로 바꾸세요.
</p>

<p align="center">
  <a href="https://github.com/woosublee/quill/releases/latest/download/Quill.dmg"><b>Quill.dmg 다운로드</b></a><br>
  <sub>모든 Mac 지원(Apple Silicon + Intel)</sub>
</p>

---

<p align="center">
  <img src="Resources/demo.gif" alt="Quill 데모" width="600">
</p>

## Quill이란?

Quill은 말로 떠올린 생각을 실제로 사용할 수 있는 글로 바꿔 주는 무료 오픈 소스 Mac 받아쓰기 앱입니다. 타이핑을 위해 흐름을 멈추는 대신 단축키를 누른 채 원하는 내용을 말하면, Quill이 이를 전사하고 다듬어 현재 사용 중인 앱에 붙여 넣습니다.

메시지 답장, 문서 초안 작성, 회의 중 떠오른 생각 기록, 선택한 텍스트 수정, 받아쓰기 기록 보관 등 일상적인 글쓰기와 업무 메모에 사용할 수 있습니다. Quill은 앱 문맥, 사용자 지정 어휘, 캘린더 문맥, 다듬기 프롬프트를 활용해 원본 전사문보다 완성된 글에 가까운 결과를 만들 수 있습니다.

## Quill로 할 수 있는 일

- **생각이 사라지기 전에 기록:** 사용 중인 앱을 벗어나지 않고 거친 아이디어, 회의 메모, 후속 작업, 초안을 말로 기록합니다.
- **필요한 오디오 소스 녹음:** System Default 입력, System Audio, System Default + System Audio(연결된 마이크 포함)를 녹음하고, 세션을 끝내지 않은 채 녹음 중에 소스를 전환합니다.
- **Mac의 어떤 앱에서든 작성:** 텍스트 필드, 문서, 채팅 앱, 브라우저, 터미널 등 현재 포커스된 입력 영역에 받아씁니다.
- **음성을 완성된 글로 변환:** 결과를 붙여 넣기 전에 불필요한 추임새, 문장 부호, 표현, 이름, 프로젝트별 어휘를 다듬습니다.
- **음성으로 편집:** 기존 텍스트를 선택한 뒤 “더 짧게 만들어 줘” 또는 “글머리 기호로 바꿔 줘”처럼 수정할 내용을 말합니다.
- **메모와 문맥 연결:** 로컬 기록, 선택형 캘린더 문맥, Note Browser 흐름을 활용해 녹음과 관련 업무를 연결합니다.
- **전사 방식 선택:** 개인정보 보호, 속도, 설정 요구 사항에 따라 제공자 기반 전사 또는 로컬 전사 옵션을 사용합니다.
- **Claude Code로 자동화:** 로컬 MCP 서버를 열어 Claude Code가 녹음을 시작하고, 문맥을 추가하고, 녹음을 중지하고, 최근 전사문을 읽을 수 있게 합니다.

## 동작 방식

1. 받아쓰기 단축키를 누르면 Quill이 오디오를 녹음하고 노치 근처의 작은 오버레이에 실시간 파형과 선택형 경과 시간을 표시합니다.
2. 설정한 로컬 또는 제공자 기반 전사 옵션으로 오디오를 전사합니다.
3. 앱 문맥, 사용자 지정 어휘, 출력 설정을 사용해 전사문을 다듬을 수 있습니다.
4. 완성된 텍스트를 현재 포커스된 앱에 붙여 넣고 검토하거나 다시 시도할 수 있도록 로컬 기록에 보관합니다.

## 요구 사항

- macOS 13 이상.
- Apple Silicon 또는 Intel Mac.
- macOS 손쉬운 사용 및 마이크 권한.
- 로컬 전사 옵션 또는 설정된 전사 제공자/API endpoint.
- 선택 사항: 회의와 관련된 메모 제목 및 녹음 알림에 사용할 Google Calendar 접근 권한.

## 빠른 시작

1. [Quill.dmg를 다운로드](https://github.com/woosublee/quill/releases/latest/download/Quill.dmg)합니다.
   - macOS가 첫 실행을 차단하면 **시스템 설정 → 개인정보 보호 및 보안**에서 Quill의 **확인 없이 열기**를 선택한 뒤 **열기**를 눌러 주세요. 현재 self-signed 릴리스에서는 처음 한 번만 필요합니다.
2. Quill을 열고 설정 안내를 완료합니다.
3. 받아쓰기와 붙여 넣기 자동화에 필요한 macOS 권한을 허용합니다.
4. Settings에서 전사 제공자, 로컬 전사 옵션 또는 OpenAI-compatible API endpoint를 설정합니다.
5. 말하는 동안 `Fn`을 누르고 있거나, `Command-Fn`을 눌러 받아쓰기를 시작하고 중지합니다.

## Claude Code MCP 설정

Quill이 실행 중일 때 로컬 MCP 서버를 열 수 있습니다. 그러면 Claude Code가 녹음을 시작하고, 문맥을 추가하고, 녹음을 중지하고, 로컬 Quill 기록에서 최근 전사문을 읽을 수 있습니다.

로컬 MCP endpoint는 다음과 같습니다.

```text
http://localhost:3457
```

Claude Code에 Quill을 등록하려면 다음 명령을 실행합니다.

```bash
claude mcp add -s user -t http quill http://localhost:3457
```

그다음 다음 순서로 진행합니다.

1. Quill을 설치하고 실행합니다.
2. 설정 안내가 나타나면 완료합니다.
3. MCP 서버를 사용하는 동안 Quill을 실행해 둡니다.
4. Claude에게 `quill` MCP 서버를 사용하도록 요청합니다.

사용할 수 있는 MCP 도구:

- `start_recording` — 회의 이름, 참석자, 주제, Notion URL 등의 초기 문맥을 선택적으로 포함해 Quill 녹음 세션을 시작합니다.
- `add_context` — 녹음 진행 중에 문맥을 추가합니다.
- `stop_recording` — 녹음을 중지하고 전사를 시작합니다.
- `get_status` — Quill이 대기, 녹음, 전사 중인지 확인합니다.
- `list_transcripts` — 최근 전사 기록을 나열합니다.
- `get_transcript` — id로 특정 전사문을 가져옵니다.
- `get_meeting_source` — id로 특정 전사문의 구조화된 회의 데이터를 회의록 생성을 위해 JSON으로 가져옵니다. 여기에는 확정된 제목, ISO 8601 타임스탬프, 일치한 캘린더 일정, 참석자, 오디오 파일 경로, 전사문, 문맥이 포함됩니다.

참고:

- Quill MCP에는 별도의 MCP API key가 필요하지 않습니다.
- 서버는 사용자의 Mac에서 로컬로 실행되며 Quill이 실행 중일 때만 사용할 수 있습니다.
- Claude Code 등록은 사용자 단위로 적용됩니다.
- 각 사용자가 자신의 컴퓨터에서 Quill을 실행하고 로컬 `quill` MCP 서버를 직접 등록해야 합니다.

## 개인정보 보호

Quill은 전사문, 오디오 녹음, 캘린더 데이터, OAuth token 또는 앱 기록을 저장하는 서버를 운영하지 않습니다. 설정한 전사 또는 AI 제공자에게 직접 데이터를 전송하도록 선택한 경우를 제외하면 앱 데이터는 사용자의 Mac에 로컬로 저장됩니다.

Google Calendar를 연결하면 Quill은 읽기 전용 접근 권한을 요청하며, 선택된 캘린더 일정은 메모 제목 제안과 녹음 알림 같은 로컬 회의 관련 기능에만 사용합니다.

## 크레딧

Quill은 [`zachlatta/freeflow`](https://github.com/zachlatta/freeflow)의 fork로 관리되며, 원래 FreeFlow 프로젝트와 upstream 기여자들의 작업을 바탕으로 합니다.

## 라이선스

MIT license에 따라 라이선스가 부여됩니다.
