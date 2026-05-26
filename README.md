<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="Quill icon">
</p>

<h1 align="center">Quill</h1>

<p align="center">
  Quill is a maintained fork of <code>zachlatta/freeflow</code> that keeps the upstream dictation experience while adding Quill-specific workflows and integrations.
</p>

## Quill 소개

Quill은 `zachlatta/freeflow`를 기반으로 유지하는 포크로, upstream의 핵심 dictation 경험은 최대한 따라가면서 한국어 사용자와 개인 워크플로우에 필요한 기능들을 추가로 제공합니다.

### Quill에서 추가로 안내하는 내용

- **Quill 브랜딩:** 앱 이름과 사용자 노출 문구를 `Quill` 기준으로 정리합니다.
- **로컬 전사 확장:** Apple Speech 및 local transcription 모델 선택 흐름을 제공합니다.
- **MCP 연동:** 앱 실행 중 로컬 MCP 서버를 통해 Claude Code와 연결할 수 있습니다.
- **Note Browser 워크플로우:** 전사 이력, 노트 탐색, 후속 정리 흐름을 함께 사용합니다.
- **포크 전용 설정 UX:** upstream 설정을 수용하면서도 Quill 전용 옵션을 함께 제공합니다.

### Claude Code MCP Setup

Quill exposes a local MCP server at `http://localhost:3457` while the app is running.

To connect Quill to Claude Code, run:

```bash
claude mcp add -s user -t http quill http://localhost:3457
```

Then:

1. Install and launch Quill
2. Complete the app setup if prompted
3. Keep Quill running
4. Ask Claude to use the `quill` MCP server

#### Notes

- Quill MCP does not require a separate MCP API key.
- This is a user-scoped local connection.
- Each person should run Quill on their own machine and register their own local `quill` MCP server.

> 아래부터는 upstream README 내용을 기본으로 유지합니다.

---

<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="Quill icon">
</p>

<h1 align="center">Quill</h1>

<p align="center">
  Free and open source alternative to <a href="https://wisprflow.ai">Wispr Flow</a>, <a href="https://superwhisper.com">Superwhisper</a>, and <a href="https://monologue.to">Monologue</a>.
</p>

<p align="center">
  <a href="https://github.com/woosublee/quill/releases/latest/download/Quill.dmg"><b>⬇ Download Quill.dmg</b></a><br>
  <sub>Works on all Macs (Apple Silicon + Intel)</sub>
</p>

---

<p align="center">
  <img src="Resources/demo.gif" alt="Quill demo" width="600">
</p>

<p align="center">
  <i>Thank you to <a href="https://github.com/marcbodea">@marcbodea</a> for maintaining the original FreeFlow project!</i>
</p>

## Overview

Quill is a free Mac dictation app inspired by [Wispr Flow](https://wisprflow.ai/), [Superwhisper](https://superwhisper.com/), and [Monologue](https://www.monologue.to/). It gives you fast AI transcription, context-aware cleanup, and voice-driven text editing without a monthly subscription.

## Quick Start

1. Download the app from above or [click here](https://github.com/woosublee/quill/releases/latest/download/Quill.dmg)
2. Get a free Groq API key from [groq.com](https://groq.com/)
3. Hold `Fn` to talk, or tap `Command-Fn` to start and stop dictation, and have whatever you say pasted into the current text field

## Features

- **Custom shortcuts:** Customize both hold-to-talk and toggle dictation shortcuts. If your toggle shortcut extends your hold shortcut, you can start in hold mode and press the extra modifier keys to latch into tap mode without stopping the recording.
- **Context-aware cleanup:** Quill can read nearby app context so names, terms, and phrases are spelled correctly when you dictate into email, terminals, docs, and other apps.
- **Custom vocabulary:** Add names, jargon, and project-specific words that Quill should preserve during cleanup.
- **OpenAI-compatible providers:** Use Groq by default, or configure a custom model and API URL in settings.

## Edit Mode

Edit Mode lets you highlight existing text and transform it with a spoken instruction, like "make this shorter" or "turn this into bullets." Enable it in settings, then use your normal dictation shortcut on selected text, or choose Manual mode to require an extra modifier key.

## Privacy

There is no Quill server, so Quill does not store or retain your data. The only information that leaves your computer are API calls to your configured transcription and LLM provider.

## Custom Cleanup

If you'd rather keep cleanup more literal and less context-aware, you can paste this simpler prompt into the custom system prompt setting:

<details>
  <summary>Simple post-processing prompt</summary>

  <pre><code>You are a dictation post-processor. You receive raw speech-to-text output and return clean text ready to be typed into an application.

Your job:
- Remove filler words (um, uh, you know, like) unless they carry meaning.
- Fix spelling, grammar, and punctuation errors.
- When the transcript already contains a word that is a close misspelling of a name or term from the context or custom vocabulary, correct the spelling. Never insert names or terms from context that the speaker did not say.
- Preserve the speaker's intent, tone, and meaning exactly.

Output rules:
- Return ONLY the cleaned transcript text, nothing else. So NEVER output words like "Here is the cleaned transcript text:"
- If the transcription is empty, return exactly: EMPTY
- Do not add words, names, or content that are not in the transcription. The context is only for correcting spelling of words already spoken.
- Do not change the meaning of what was said.

Example:
RAW_TRANSCRIPTION: "hey um so i just wanted to like follow up on the meating from yesterday i think we should definately move the dedline to next friday becuz the desine team still needs more time to finish the mock ups and um yeah let me know if that works for you ok thanks"

Then your response would be ONLY the cleaned up text, so here your response is ONLY:
"Hey, I just wanted to follow up on the meeting from yesterday. I think we should definitely move the deadline to next Friday because the design team still needs more time to finish the mockups. Let me know if that works for you. Thanks."</code></pre>
</details>

## FAQ

**Why does this use Groq instead of a local transcription model?**

I love this idea, and originally planned to build Quill using local models, but to have post-processing (that's where you get correctly spelled names when replying to emails / etc), you need to have a local LLM too.

If you do that, the total pipeline takes too long for the UX to be good (5-10 seconds per transcription instead of <1s). I also had concerns around battery life.

Some day!

**Update:** You can now use a custom model with Quill by configuring the LLM API URL in the Quill settings to use Ollama. Thank you @taciturnaxolotl!

## License

Licensed under the MIT license.
