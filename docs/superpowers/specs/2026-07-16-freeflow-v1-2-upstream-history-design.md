# FreeFlow v1.2 선택 수용 및 upstream 이력 연결 설계

## 목적

PR #197의 기존 구현을 보존하면서 FreeFlow v1.2.0의 5개 기능군이 이슈 #196의 결정대로 Quill에 수용됐는지 다시 대조한다. 누락 또는 결함만 최소한으로 수정하고, 검증 완료 후 `upstream/main@1de2c2f`를 코드 변경 없는 두 번째 부모로 연결한다.

## 기준

- Quill 기준 커밋: `origin/main@d48b7e3`
- 현재 구현 커밋: `b68e374`
- upstream 기준 커밋: `upstream/main@1de2c2f` (`v1.2.0`)
- 공통 조상: `13e2788`
- 작업 PR: `woosublee/quill#197`

## 수용 원칙

1. upstream 기능의 의도와 사용자 동작을 기본적으로 수용한다.
2. Quill에 이미 더 적합한 구조가 있으면 동작은 수용하되 구현은 Quill 구조를 유지한다.
3. 의도적으로 다르게 수용한 부분은 이슈 #196과 이전 구현 세션의 결정에 맞는지 확인한다.
4. upstream release metadata와 `CHANGELOG.md`는 Quill release history에 복사하지 않는다.
5. 모든 기능군이 수용됐음을 검증하기 전에는 upstream 이력 연결 merge를 만들지 않는다.

## 검토 대상

| Upstream 영역 | Quill 수용 원칙 |
| --- | --- |
| #218 transcription response format | 모델 능력에 따라 `verbose_json`과 `json`을 선택하고 Quill의 local transcription 경로를 보존한다. |
| #262 context sanitization / Qwen 3.6 | context 결과에서 think tag를 제거하고 Qwen 3.6 지원을 반영하되 기존 사용자 모델 선택과 Quill 모델 설정을 보존한다. |
| #250 request timeout | caller timeout을 request/session resource 단계에서 존중하되 Quill의 shared-session 재사용 최적화를 유지한다. |
| #246 cooldown / fallback | 429 cooldown과 fallback routing을 수용하되 상태를 `(baseURL, model)` 기준으로 격리한다. |
| #248 preserve exact wording | 기존 `Disable Post-Processing` 의미를 유지하고, post-processing이 활성화된 경우에만 exact-wording/literal-translation을 별도 옵션으로 제공한다. |

## 리뷰 처리

PR #197의 자동 리뷰 지적을 현재 코드에서 다시 검증한다. 실제 결함만 최소 수정한다.

- cooldown 중인 fallback 재호출 여부
- sanitize 후 빈 literal translation 성공 처리 여부
- memory-only cooldown과 persisted cooldown 충돌 여부
- Qwen `reasoning_effort` 값의 provider 호환성
- timeout session 선택이 shared connection reuse를 과도하게 우회하는지 여부

## 검증

앱 실행과 수동 UI 테스트는 이번 정리 범위에서 제외한다. 다음을 수행한다.

1. 관련 단위 테스트 보강 및 전체 `make test`
2. 깨끗한 전체 빌드 (`make clean && make CODESIGN_IDENTITY=-`)
3. `codesign --verify --deep --strict build/Quill.app`
4. `git diff --check`
5. 작업 트리 청결 상태 확인

## 이력 연결

기능 대조와 검증이 완료되면 현재 Quill tree를 유지하면서 `upstream/main@1de2c2f`를 두 번째 부모로 갖는 merge commit을 만든다. 과거 `270b193 Merge upstream main history`와 같은 구조다.

완료 조건:

- merge commit tree가 첫 번째 부모 tree와 동일하다.
- `git merge-base --is-ancestor upstream/main HEAD`가 성공한다.
- merge 이후 전체 테스트와 빌드 검증이 통과한다.
- PR 본문이 선택 수용, 의도적인 Quill 차이, 검증 결과를 정확히 설명한다.
