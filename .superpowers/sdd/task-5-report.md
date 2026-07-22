# Task 5: AppContextService backend routing

## Scope

Base commit: `961daeeaab2734dc7983b44615665e6872ba7d58`

Implemented `AppContextService` routing through `AIProcessingBackendExecutor` while preserving metadata fallback behavior for inference failures.

## RED

1. Created `Tests/AppContextBackendTests.swift` first and added it to the grouped transcription test source list and runner.
2. Ran `make test-transcription` before production changes.
3. The expected compile-time RED state was observed: the test could not construct `AppContextService(backendExecutor:...)`, could not supply `transport`, and could not call the internal inference seam because the compatibility-only initializer was still present. The first compile also identified a test-only throwing expression inside a non-throwing autoclosure; that assertion was corrected before production code was written.

## GREEN

1. Made `AppContextService` immutable request configuration `@unchecked Sendable` and added sendable `Transport` and private `IssueSink` seams.
2. Preserved the compatibility initializer, which creates a cloud executor, and added the executor initializer for local or cloud routing.
3. Replaced API-key gating in `collectContext()` with `backendExecutor.isConfigured`.
4. Routed inference through one `withEndpoint` operation:
   - Cloud retains screenshot-first then text-only retry behavior.
   - Local uses exactly one text-only attempt, with no authorization header or screenshot payload.
   - Request base URL, authorization, request model ID, and selected-model configuration are derived from `AIProcessingEndpoint`.
5. Let transport/process errors escape the inner request method. The outer inference method records only a private issue and returns `nil`, retaining metadata fallback behavior. A process exit received from `LocalAIServerManager` maps to `.localAIProcessExited`.

## Tests

`AppContextBackendTests` covers:

- Local request uses loopback, has no authorization header, contains selected text, omits `image_url` and screenshot data, and makes one request.
- Cloud request retries after a failed screenshot request and omits the screenshot on its second request.
- A local transport failure returns `nil` and reaches the private issue sink as `.postProcessingFailed`.
- A simulated local process exit during transport returns `nil` and reaches the private issue sink as `.localAIProcessExited`.

Commands run:

```text
make test-transcription
# RED: expected missing executor initializer / transport seam / internal inference API

make test-transcription
# GREEN: passed

make check-test-wiring && make test-transcription
# passed
```

The final full grouped run passed. It emitted pre-existing CoreData duplicate entity-description warnings only; no new compiler warnings were emitted after the request URL cleanup.

## Files

- `Sources/AppContextService.swift`
- `Tests/AppContextBackendTests.swift`
- `Tests/FullSourceTranscriptionTestRunner.swift`
- `Makefile`

## Self-review

- Confirmed local requests derive endpoint configuration, omit cloud authorization, and never attach screenshots.
- Confirmed local transport failures remain visible to `LocalAIServerManager` so a dead process is classified before metadata fallback.
- Confirmed cloud screenshot retry remains two attempts and remains text-only on retry.
- Confirmed no captured mutable variables are used in `@Sendable` test closures; request and issue collection use `NSLock`-backed `@unchecked Sendable` recorders.
- Confirmed `git diff --check` passes.
