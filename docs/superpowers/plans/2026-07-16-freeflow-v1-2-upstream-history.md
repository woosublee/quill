# FreeFlow v1.2 Upstream History Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PR #197의 Quill-native FreeFlow v1.2 구현을 보존하면서 확인된 literal translation 데이터 유실 결함을 수정하고, 검증된 Quill tree를 유지한 채 `upstream/main@1de2c2f`를 두 번째 부모로 연결한다.

**Architecture:** 현재 구현은 upstream v1.2.0의 5개 기능군을 wholesale merge가 아니라 Quill 구조에 맞게 선택 수용한다. 코드 대조 결과 실제 수정이 필요한 항목은 quote-only literal translation이 정리 후 빈 성공값이 되는 경로 하나이며, 이를 기존 fallback 경로로 보내도록 회귀 테스트와 최소 수정을 추가한다. 전체 검증 후 과거 `270b193 Merge upstream main history`와 같은 code-tree-preserving 2-parent merge를 만들고 PR 설명과 리뷰 스레드를 실제 결과에 맞게 정리한다.

**Tech Stack:** Swift, Foundation, URLSession, standalone Swift `@main` tests, Make, Git, GitHub CLI.

## Global Constraints

- Quill 구현 기준 커밋은 `b68e374`, 승인된 설계 문서 커밋은 `31ab493`이다.
- 연결할 upstream 커밋은 `upstream/main@1de2c2f` (`v1.2.0`)이다.
- Quill의 제품명, local transcription 경로, release metadata, model-first Settings 구조를 유지한다.
- upstream `CHANGELOG.md`, README/release metadata, FreeFlow 브랜딩을 복사하지 않는다.
- 기능 대조와 검증이 끝나기 전에는 upstream history merge를 만들지 않는다.
- `Disable Post-Processing`은 LLM cleanup과 translation을 모두 사용하지 않는 기존 의미를 유지한다.
- `Preserve Exact Wording`은 post-processing이 활성화된 경우에만 선택 가능하며, Output Language가 있으면 literal translation을 수행한다.
- verbatim translation의 문자열 `"EMPTY"`는 유효한 번역 결과다. cleanup pipeline의 sentinel로 취급하지 않는다.
- 이번 범위에서는 앱 실행과 수동 UI 테스트를 하지 않는다.
- 완료 전 `make test`, 깨끗한 ad-hoc 전체 빌드, codesign 검증, Git tree/ancestry 검증을 모두 수행한다.

---

## File Structure

- Modify: `Sources/PostProcessingService.swift`
  - literal translation 응답을 정리한 뒤 비어 있으면 `PostProcessingError.emptyOutput`을 발생시키는 책임을 추가한다.
- Modify: `Tests/AppStateTranscriptionConfigurationTests.swift`
  - quote-only 출력은 실패하고 `"EMPTY"` 및 일반 quoted output은 유지되는 회귀 테스트를 추가한다.
- Preserve: `Sources/TranscriptionService.swift`
  - #218 response-format 수용은 이미 완료되어 있다.
- Preserve: `Sources/AppContextService.swift`, `Sources/ModelConfiguration.swift`, `Sources/AppState.swift`
  - #262 Qwen 3.6, think-tag sanitization, default migration을 유지한다.
- Preserve: `Sources/LLMAPITransport.swift`
  - #250 caller timeout 수용과 Quill의 20초 shared-session reuse를 유지한다.
- Preserve: `Sources/LLMCooldownManager.swift`, `Tests/LLMCooldownManagerTests.swift`
  - #246 provider-qualified cooldown identity와 persistence semantics를 유지한다.
- Preserve: `docs/superpowers/specs/2026-07-16-freeflow-v1-2-upstream-history-design.md`
  - 승인된 설계 문서는 수정하지 않는다.
- Modify through history only: Git commit graph
  - 최종 Quill fix commit을 첫 번째 부모, `1de2c2f`를 두 번째 부모로 하는 tree-preserving merge commit을 만든다.

---

### Task 1: Literal Translation의 정리 후 빈 출력 거부

**Files:**
- Modify: `Sources/PostProcessingService.swift:955-975`
- Test: `Tests/AppStateTranscriptionConfigurationTests.swift:6-25,253-261`

**Interfaces:**
- Consumes: `PostProcessingError.emptyOutput`, `PostProcessingService.sanitizeVerbatimTranslation(_:)`, `translateVerbatim(transcript:targetLanguage:model:)`
- Produces: `PostProcessingService.validatedVerbatimTranslation(_:) throws -> String`
- Produces invariant: 성공한 literal translation의 sanitized transcript는 항상 비어 있지 않다.

- [ ] **Step 1: 회귀 테스트를 `main()`에 등록한다**

`Tests/AppStateTranscriptionConfigurationTests.swift`에서 다음 줄 바로 뒤에:

```swift
testVerbatimTranslationPromptAndSanitizer()
```

다음을 추가한다.

```swift
testVerbatimTranslationRejectsOutputThatSanitizesToEmpty()
```

- [ ] **Step 2: quote-only 출력과 유효 literal 출력을 구분하는 실패 테스트를 작성한다**

`testVerbatimTranslationPromptAndSanitizer()` 바로 뒤에 다음 테스트를 추가한다.

```swift
private static func testVerbatimTranslationRejectsOutputThatSanitizesToEmpty() {
    do {
        _ = try PostProcessingService.validatedVerbatimTranslation("\"\"")
        assertionFailure("Quote-only literal translation must be treated as empty output")
    } catch PostProcessingError.emptyOutput {
        // Expected: stripping the outer quotes leaves no literal text to paste.
    } catch {
        assertionFailure("Expected emptyOutput, got \(error)")
    }

    do {
        let literalEmpty = try PostProcessingService.validatedVerbatimTranslation("\"EMPTY\"")
        assert(literalEmpty == "EMPTY")

        let translated = try PostProcessingService.validatedVerbatimTranslation("\" translated text \"")
        assert(translated == "translated text")
    } catch {
        assertionFailure("Nonempty literal translations must remain valid: \(error)")
    }
}
```

이 테스트는 다음 경계를 고정한다.

- `""`는 성공한 빈 dictation이 아니라 `.emptyOutput`이다.
- `"EMPTY"`는 cleanup sentinel이 아니라 실제 literal text다.
- 일반 quoted translation은 outer quote와 공백만 제거한다.

- [ ] **Step 3: 테스트가 아직 컴파일되지 않는지 확인한다**

Run:

```bash
make test
```

Expected:

```text
error: type 'PostProcessingService' has no member 'validatedVerbatimTranslation'
make: *** [test] Error 1
```

- [ ] **Step 4: post-sanitization validation을 최소 구현한다**

`Sources/PostProcessingService.swift`의 다음 코드를:

```swift
return PostProcessingResult(
    transcript: Self.sanitizeVerbatimTranslation(content),
    prompt: promptForDisplay
)
```

다음으로 교체한다.

```swift
let sanitizedTranslation = try Self.validatedVerbatimTranslation(content)
return PostProcessingResult(
    transcript: sanitizedTranslation,
    prompt: promptForDisplay
)
```

기존 `sanitizeVerbatimTranslation(_:)` 바로 뒤에 다음 helper를 추가한다.

```swift
static func validatedVerbatimTranslation(_ value: String) throws -> String {
    let sanitized = sanitizeVerbatimTranslation(value)
    guard !sanitized.isEmpty else {
        throw PostProcessingError.emptyOutput
    }
    return sanitized
}
```

최종 경로는 다음과 동등해야 한다.

```swift
let content = config.shouldStripThinkTags
    ? ModelConfiguration.stripThinkTags(rawContent)
    : rawContent
guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw PostProcessingError.emptyOutput
}

let sanitizedTranslation = try Self.validatedVerbatimTranslation(content)
return PostProcessingResult(
    transcript: sanitizedTranslation,
    prompt: promptForDisplay
)
```

다음은 변경하지 않는다.

- `sanitizeVerbatimTranslation(_:)`에서 `"EMPTY"`를 빈 문자열로 바꾸지 않는다.
- think-tag 제거 직후의 기존 raw-content guard를 제거하지 않는다.
- fallback routing을 새로 만들지 않는다. `.emptyOutput` throw가 기존 distinct fallback 또는 raw transcript 보존 경로를 사용한다.

- [ ] **Step 5: 전체 테스트를 실행한다**

Run:

```bash
make test
```

Expected:

- 모든 test executable이 exit zero다.
- 출력에 다음 항목이 포함된다.

```text
LLMCooldownManagerTests passed
UpstreamMergeBehaviorTests passed
AppStateTranscriptionConfigurationTests passed
```

- [ ] **Step 6: 변경 범위와 whitespace를 확인한다**

Run:

```bash
git diff --check
git diff -- Sources/PostProcessingService.swift Tests/AppStateTranscriptionConfigurationTests.swift
```

Expected:

- `git diff --check` 출력이 없다.
- diff에는 validation helper, call-site 변경, 테스트 등록, 회귀 테스트만 있다.

- [ ] **Step 7: 수정과 회귀 테스트를 독립 커밋한다**

Run:

```bash
git add Sources/PostProcessingService.swift Tests/AppStateTranscriptionConfigurationTests.swift
git commit -m "Fix empty literal translation handling" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

Expected:

- source와 test 두 파일만 커밋된다.
- 승인된 설계 문서는 변경되지 않는다.

---

### Task 2: 5개 upstream 기능군의 최종 수용 상태와 리뷰 판단 확인

**Files:**
- Read-only verification: `Sources/TranscriptionService.swift`
- Read-only verification: `Sources/AppContextService.swift`
- Read-only verification: `Sources/ModelConfiguration.swift`
- Read-only verification: `Sources/AppState.swift`
- Read-only verification: `Sources/LLMAPITransport.swift`
- Read-only verification: `Sources/LLMCooldownManager.swift`
- Read-only verification: `Sources/PostProcessingService.swift`
- Read-only verification: `Sources/SettingsView.swift`
- Read-only verification: `Tests/AppStateTranscriptionConfigurationTests.swift`
- Read-only verification: `Tests/LLMCooldownManagerTests.swift`

**Interfaces:**
- Consumes: upstream feature commits `abfc058`, `849b101`, `7427ca9`, `a55be95`, `4293959`
- Produces: PR 본문과 review reply에 사용할 최종 acceptance matrix

- [ ] **Step 1: #218 response-format 수용을 확인한다**

Run:

```bash
git diff --no-index \
  <(git show upstream/main:Sources/TranscriptionService.swift | grep -n -A30 -B5 'modelsSupportingVerboseJSON') \
  <(grep -n -A30 -B5 'modelsSupportingVerboseJSON' Sources/TranscriptionService.swift) || true
grep -n -A20 -B5 'testTranscriptionResponseFormat' Tests/AppStateTranscriptionConfigurationTests.swift
```

Expected acceptance:

- `whisper-1`, `whisper-large-v3`, `whisper-large-v3-turbo`만 `verbose_json`을 사용한다.
- 기타 모델은 `json`을 사용한다.
- Quill local transcription 경로는 유지된다.
- 추가 코드 변경은 없다.

- [ ] **Step 2: #262 Qwen 3.6 수용을 확인한다**

Run:

```bash
git show upstream/main:Sources/ModelConfiguration.swift | grep -n -A12 -B5 'qwen/qwen3.6-27b'
grep -n -A12 -B5 'qwen/qwen3.6-27b' Sources/ModelConfiguration.swift
grep -n -A15 -B5 'activitySummary' Sources/AppContextService.swift
grep -n -A65 -B5 'testQwen36ModelConfiguration' Tests/AppStateTranscriptionConfigurationTests.swift
```

Expected acceptance:

- Qwen 3.6 모델, alias, think-tag sanitization, default context model, old-default migration, custom-model 보존이 있다.
- `reasoningEffort: "none"`은 upstream `1de2c2f`와 동일하고, prior implementation decision에서 provider-side reasoning 비활성화를 위해 의도적으로 수용했다.
- Gemini의 `reasoningEffort: nil` 제안은 upstream 수용 의도와 반대이므로 적용하지 않는다.

- [ ] **Step 3: #250 timeout 수용과 pooling 보존을 확인한다**

Run:

```bash
grep -n -A55 -B5 'enum LLMAPITransport' Sources/LLMAPITransport.swift
grep -nE 'request.timeoutInterval[[:space:]]*=' \
  Sources/AppContextService.swift Sources/PostProcessingService.swift Sources/TranscriptionService.swift
grep -n -A10 -B5 'testLLMTransportTimeoutNormalization' Tests/AppStateTranscriptionConfigurationTests.swift
```

Expected acceptance:

- context, post-processing, API transcription 기본 caller timeout은 20초다.
- 20초 이하 data request는 shared session을 재사용한다.
- 20초 초과 data request와 upload는 caller timeout과 일치하는 전용 session을 사용한다.
- standard `URLRequest` 60초 기본값이 주요 LLM call path에 그대로 남아 있다는 Gemini 가정은 현재 코드에 해당하지 않는다.
- 추가 코드 변경은 없다.

- [ ] **Step 4: #246 cooldown 수용과 state semantics를 확인한다**

Run:

```bash
grep -n -A100 -B5 'struct LLMCooldownIdentity' Sources/LLMCooldownManager.swift
grep -nE 'effectivePrimary|retryModel != primaryModel|skippedDueToCooldown' Sources/PostProcessingService.swift
grep -n -A50 -B10 'testPersistedCooldown' Tests/LLMCooldownManagerTests.swift
```

Expected acceptance:

- cooldown key는 normalized `(baseURL, model)`이다.
- primary가 cooling이면 fallback을 먼저 선택한다.
- 이미 fallback을 primary로 선택한 뒤에는 `retryModel != primaryModel` guard가 동일 모델 재호출을 막는다.
- primary와 fallback 모두 cooling이면 request 없이 `skippedDueToCooldown`을 반환한다.
- memory cooldown 만료 후 persisted cooldown을 확인하는 것은 오래된 daily limit을 의도치 않게 단축하지 않는 보수적 동작이다.
- Gemini 제안처럼 memory cooldown을 설정할 때 persisted daily cooldown을 삭제하지 않는다.
- 추가 코드 변경은 없다.

- [ ] **Step 5: #248 exact wording 수용과 Task 1 수정을 확인한다**

Run:

```bash
grep -n -A95 -B15 'if preserveExactWording' Sources/AppState.swift
grep -n -A25 -B10 'Preserve Exact Wording' Sources/SettingsView.swift
grep -n -A50 -B10 'validatedVerbatimTranslation' Sources/PostProcessingService.swift
grep -n -A55 -B10 'testVerbatimTranslationPromptAndSanitizer' Tests/AppStateTranscriptionConfigurationTests.swift
```

Expected acceptance:

- `Disable Post-Processing`이 우선 raw transcript를 반환한다.
- exact wording UI는 post-processing disabled 상태에서 비활성화된다.
- output language가 없으면 LLM 없이 raw transcript를 유지한다.
- output language가 있으면 literal translation을 수행한다.
- quote-only sanitized output은 `.emptyOutput`으로 기존 fallback에 진입한다.
- `"EMPTY"`는 literal text로 유지된다.

- [ ] **Step 6: acceptance matrix 외 source 변경이 없는지 확인한다**

Run:

```bash
git status --short
git diff --stat b68e374..HEAD -- Sources Tests Makefile
```

Expected:

- Task 1 source/test 변경 외에 새 source 변경이 없다.
- 설계·계획 문서 커밋은 별도로 존재한다.

---

### Task 3: Upstream 이력 연결 전 전체 검증

**Files:**
- No source modification.
- Build output only: `build/Quill.app`

**Interfaces:**
- Consumes: Task 1의 fix commit과 Task 2 acceptance 결과
- Produces: history merge를 허용하는 fresh test/build evidence

- [ ] **Step 1: upstream ref와 clean working tree를 확인한다**

Run:

```bash
git fetch upstream main
git rev-parse upstream/main
git merge-base HEAD upstream/main
git status --short
```

Expected:

```text
1de2c2fec50cfa24bf988b670a7598138914a05f
```

- merge base는 `13e2788` 계열이다.
- `git status --short` 출력이 없다.
- upstream SHA가 달라졌으면 history merge를 중단하고 새 upstream delta를 별도로 검토한다.

- [ ] **Step 2: 전체 테스트를 실행한다**

Run:

```bash
make test
```

Expected:

- exit zero
- 모든 test executable이 `passed`를 출력한다.

- [ ] **Step 3: 깨끗한 전체 앱 빌드를 ad-hoc 서명으로 수행한다**

Run:

```bash
make clean && make CODESIGN_IDENTITY=-
```

Expected:

```text
Built build/Quill.app
```

- whisper.cpp와 Swift source가 처음부터 컴파일된다.
- 앱을 실행하지 않는다.

- [ ] **Step 4: 완성된 앱 번들의 서명 구조를 검증한다**

Run:

```bash
codesign --verify --deep --strict --verbose=2 build/Quill.app
```

Expected:

```text
build/Quill.app: valid on disk
build/Quill.app: satisfies its Designated Requirement
```

- [ ] **Step 5: diff와 working tree를 최종 확인한다**

Run:

```bash
git diff --check
git status --short
```

Expected:

- 두 명령 모두 출력이 없다.

---

### Task 4: Code-tree-preserving 2-parent upstream history merge 생성

**Files:**
- Modify through Git history only: repository commit graph
- No source tree change.

**Interfaces:**
- Consumes: verified Quill first-parent commit, `upstream/main@1de2c2f`
- Produces: first-parent tree와 동일한 2-parent merge commit

- [ ] **Step 1: merge 직전 first-parent commit과 tree를 기록한다**

Run:

```bash
first_parent=$(git rev-parse HEAD)
first_tree=$(git rev-parse HEAD^{tree})
printf 'first_parent=%s\nfirst_tree=%s\n' "$first_parent" "$first_tree"
```

Expected:

- `first_parent`는 Task 1 fix와 문서 커밋을 포함한 현재 Quill HEAD다.
- 출력값을 다음 step의 invariant 확인에 사용한다.

- [ ] **Step 2: upstream을 두 번째 부모로 하는 history merge를 만든다**

Run:

```bash
git merge --no-ff -s ours upstream/main \
  -m "Merge upstream main history" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

Expected:

- conflict 없이 2-parent merge commit이 생성된다.
- `-s ours`는 검증한 Quill tree를 유지하고 upstream ancestry만 연결한다.

- [ ] **Step 3: parent와 tree invariant를 검증한다**

Run:

```bash
git show -s --format='commit=%H%nparents=%P%nsubject=%s' HEAD
test "$(git rev-parse HEAD^{tree})" = "$(git rev-parse HEAD^1^{tree})"
git diff --quiet HEAD^1 HEAD
git merge-base --is-ancestor upstream/main HEAD
git diff --check HEAD^1 HEAD
git status --short
```

Expected:

- `parents=`에 정확히 두 SHA가 있다.
- 두 번째 부모는 `1de2c2f`다.
- merge commit tree와 첫 번째 부모 tree가 동일하다.
- `upstream/main`은 최종 HEAD의 조상이다.
- merge commit은 first parent 대비 source diff가 없다.
- working tree가 깨끗하다.

- [ ] **Step 4: merge 이후 전체 테스트를 다시 실행한다**

Run:

```bash
make test
```

Expected: exit zero.

- [ ] **Step 5: merge 이후 깨끗한 전체 빌드와 codesign 검증을 반복한다**

Run:

```bash
make clean && make CODESIGN_IDENTITY=-
codesign --verify --deep --strict --verbose=2 build/Quill.app
```

Expected:

- `Built build/Quill.app`
- `valid on disk`
- `satisfies its Designated Requirement`

---

### Task 5: PR #197 갱신, 리뷰 답변, 원격 상태 검증

**Files:**
- No local source modification.
- Update external artifact: `woosublee/quill#197`

**Interfaces:**
- Consumes: final verified HEAD, acceptance matrix, review dispositions
- Produces: pushed branch, accurate PR body, resolved review threads, Ready for review PR

- [ ] **Step 1: 최종 커밋과 branch 상태를 확인한다**

Run:

```bash
git status --short --branch
git log --graph --oneline --decorate -8
git merge-base --is-ancestor upstream/main HEAD
```

Expected:

- working tree가 깨끗하다.
- graph에 `Merge upstream main history`가 보인다.
- ancestry check가 exit zero다.

- [ ] **Step 2: branch를 origin에 push한다**

Run:

```bash
git push origin worktree-issue-196-freeflow-v1.2
```

Expected:

- force push 없이 새 fix/document/history commits가 원격 branch에 추가된다.

- [ ] **Step 3: PR 본문을 실제 선택 수용과 검증 결과로 교체한다**

Run:

```bash
gh pr edit 197 --repo woosublee/quill --body-file - <<'EOF'
## Summary

Selectively adopts the FreeFlow v1.2.0 changes tracked in #196 while preserving Quill's architecture and product behavior.

- Uses model-capability-based transcription response formats while preserving local transcription.
- Adds Qwen 3.6 context support, default migration, and think-tag sanitization.
- Honors caller request timeouts while retaining Quill's shared session for short requests.
- Adds provider-qualified `(baseURL, model)` cooldown and fallback routing.
- Adds Preserve Exact Wording as a post-processing sub-option with literal translation when Output Language is configured.
- Rejects literal-translation responses that become empty after quote sanitization.
- Connects `upstream/main@1de2c2f` as history without changing the reviewed Quill tree.

## Intentional Quill adaptations

- Cooldowns are isolated by normalized base URL and model, not model name alone.
- Requests of 20 seconds or less retain shared-session connection reuse; longer requests use a timeout-matched session.
- `Disable Post-Processing` continues to bypass both cleanup and translation.
- Preserve Exact Wording remains a separate option and is disabled while post-processing is disabled.
- Quill release metadata and changelog remain independent from FreeFlow v1.2.0.

## Testing

- `make test`
- `make clean && make CODESIGN_IDENTITY=-`
- `codesign --verify --deep --strict --verbose=2 build/Quill.app`
- `git diff --check`
- Verified the history merge tree equals its first-parent tree.
- Verified `git merge-base --is-ancestor upstream/main HEAD`.
- App launch and manual runtime testing were not repeated in this completion pass.

Closes #196.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
```

Expected:

- PR body가 selective adoption, intentional differences, history connection을 명시한다.
- 개인 로컬 signing identity 정보는 포함하지 않는다.

- [ ] **Step 4: CodeRabbit의 확인된 결함 스레드에 수정 결과를 답변한다**

Run:

```bash
gh api repos/woosublee/quill/pulls/197/comments/3591290504/replies \
  -f body='Fixed. Literal translation now validates the sanitized value and throws `PostProcessingError.emptyOutput` when quote removal leaves no text. Added regression coverage for quote-only output while preserving `"EMPTY"` as valid literal text.'
```

Expected:

- reply가 생성된다.

- [ ] **Step 5: 미반영 Gemini 리뷰에는 근거와 함께 reviewer를 멘션해 답변한다**

Run:

```bash
gh api repos/woosublee/quill/pulls/197/comments/3589105729/replies \
  -f body='@gemini-code-assist Not applying this suggestion. The persisted record represents a longer daily/provider limit and must not be shortened by a later memory-only cooldown. `isInCooldown` checks the memory expiry first and then the persisted expiry in the same call, so either active record continues to block requests.'

gh api repos/woosublee/quill/pulls/197/comments/3589105737/replies \
  -f body='@gemini-code-assist Not applying this suggestion. FreeFlow v1.2.0 itself configures `qwen/qwen3.6-27b` with `reasoning_effort: "none"`, and this PR intentionally adopts that provider-side reasoning disablement while retaining think-tag stripping as a defensive fallback.'

gh api repos/woosublee/quill/pulls/197/comments/3589105760/replies \
  -f body='@gemini-code-assist Not applying this suggestion. Quill explicitly sets the main context, post-processing, and API-transcription requests to 20 seconds, so those calls reuse the shared 20-second session. Only longer caller timeouts require a timeout-matched session; uploads intentionally use fresh sessions.'

gh api repos/woosublee/quill/pulls/197/comments/3589105768/replies \
  -f body='@gemini-code-assist Keeping the existing assertion because the corresponding implementation intentionally retains FreeFlow v1.2.0’s `reasoning_effort: "none"` configuration for Qwen 3.6.'
```

Expected:

- 네 reply가 생성된다.
- 미반영 답변은 모두 reviewer mention을 포함한다.

- [ ] **Step 6: 답변한 review thread를 resolve한다**

먼저 thread ID를 조회한다.

Run:

```bash
gh api graphql -f query='query { repository(owner:"woosublee", name:"quill") { pullRequest(number:197) { reviewThreads(first:50) { nodes { id isResolved comments(first:20) { nodes { databaseId } } } } } } }'
```

조회 결과에서 comment database ID `3591290504`, `3589105729`, `3589105737`, `3589105760`, `3589105768`을 포함하는 각 thread `id`에 대해 다음 mutation을 실행한다.

```bash
gh api graphql -f query='mutation($thread:ID!) { resolveReviewThread(input:{threadId:$thread}) { thread { id isResolved } } }' -f thread='<THREAD_ID>'
```

Expected:

```json
{"data":{"resolveReviewThread":{"thread":{"id":"...","isResolved":true}}}}
```

각 review thread에서 동일하게 `isResolved: true`를 확인한다.

- [ ] **Step 7: PR의 최종 상태와 원격 HEAD를 검증한다**

Run:

```bash
gh pr view 197 --repo woosublee/quill \
  --json url,isDraft,state,headRefOid,mergeStateStatus,statusCheckRollup
printf 'local_head=%s\n' "$(git rev-parse HEAD)"
```

Expected:

- `isDraft`는 `false`다.
- `state`는 `OPEN`이다.
- `headRefOid`와 local HEAD가 같다.
- `mergeStateStatus`가 conflict 상태가 아니다.
- 새 CI check가 pending이면 완료를 주장하지 않고 해당 상태를 보고한다.

---

## Review Finding Disposition

| Review point | Verdict | Action |
| --- | --- | --- |
| cooldown fallback이 cooling fallback을 재호출 | 현재 코드에서 재현되지 않음 | `retryModel != primaryModel` guard와 both-cooling `effectivePrimary == nil` 근거로 미반영 답변 |
| sanitize 후 literal translation이 빈 성공값 | 확인된 결함 | Task 1에서 수정하고 회귀 테스트 추가 |
| memory-only와 persisted cooldown 충돌 | 의도된 보수적 semantics | daily/provider cooldown을 짧은 memory cooldown이 지우지 않도록 유지 |
| Qwen `reasoning_effort: "none"` 호환성 | upstream v1.2.0과 동일한 의도적 수용 | 유지하고 defensive think-tag stripping 병행 |
| 20초 shared timeout이 pooling 우회 | 주요 call site가 명시적으로 20초를 사용하므로 해당 없음 | shared short-request reuse 유지 |

## Commit Sequence

1. `31ab493 Document FreeFlow v1.2 sync completion` — 이미 생성됨.
2. 이 구현 계획 문서 커밋.
3. `Fix empty literal translation handling` — code와 regression test만 포함.
4. `Merge upstream main history` — first parent 대비 tree 변경 없는 2-parent merge.
