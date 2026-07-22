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

## Follow-up: cancellation and endpoint identity fixes

### RED

Added focused regressions to `AppContextBackendTests` and ran `make test-transcription` before changing production code. The grouped run failed as expected at `cancelled context returns nil`: a cancelled task whose transport ignored cancellation and returned a successful response could still return inferred context.

### GREEN

- Cancellation is now recognized for `CancellationError`, `URLError.cancelled`, `NSURLErrorCancelled`, and a cancelled task.
- A cancellation stops the cloud attempt loop immediately, skips text-only retry, returns `nil`, and does not call the private issue sink.
- Added cancellation checks before each endpoint attempt, before returning inferred output, after the endpoint operation, and when applying inference to `collectContext()`.
- Retained cloud retry after a non-cancellation thrown transport error.
- Removed the unused stored `contextModel` property without changing either initializer signature.

### New regression coverage

- Cloud thrown transport error on the screenshot attempt retries once text-only and succeeds.
- A cancelled cloud task whose transport later succeeds makes one request, returns `nil`, and produces no issue-sink entry.
- A local endpoint whose `requestModelID` is `local` and whose selected catalog model differs uses `local` in the payload while retaining the selected model in prompt identity; it also omits authorization and image payloads.

### Commands and results

```text
make test-transcription
# RED: failed at "cancelled context returns nil"

make test-transcription
# GREEN: passed

make check-test-wiring && make test-transcription
# passed
```

## Follow-up: AppState Context capture publication cancellation guard

### RED

Added a focused `AppContextBackendTests` source-contract regression for `AppState.startContextCapture()`. It requires an outer `guard !Task.isCancelled else { return nil }` after `collectContext()` and an inner `guard !Task.isCancelled else { return }` inside `MainActor.run` before `capturedContext` is mutated. `make test-transcription` failed as expected because the outer guard was missing.

### GREEN

Added both guards without refactoring the capture path. The outer guard prevents a cancelled task from scheduling a MainActor publication, while the inner guard closes the cancellation window between scheduling and executing the MainActor closure. The inner guard is immediately followed by synchronous state mutations, with no suspension point between them.

### Commands and results

```text
make test-transcription
# RED: failed at missing guard !Task.isCancelled else { return nil }

make test-transcription
# GREEN: passed

make check-test-wiring && make test-transcription
# passed
```
