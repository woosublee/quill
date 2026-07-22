# Task 3 Report — LocalAIModelStore

## 변경 파일

- `Sources/LocalAIModel.swift`: multi-artifact `LocalAIModelStore` 추가
- `Tests/LocalAIModelStoreTests.swift`: tiny fixture 기반 package lifecycle 테스트 추가
- `Makefile`: `LocalAIModelStoreTests`를 transcription test shard에 연결

## RED / GREEN 증거

- RED: `swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/LocalAIModel.swift Tests/LocalAIModelStoreTests.swift -o /tmp/LocalAIModelStoreTests && /tmp/LocalAIModelStoreTests`
  - 예상대로 `cannot find 'LocalAIModelStore' in scope`로 실패.
- GREEN: 동일 focused command가 `LocalAIModelStoreTests passed`로 통과.
- 전체 검증: `make check-test-wiring && make test-transcription` 통과. 새 `LocalAIModelStoreTests passed` 포함.

## Multi-artifact 상태 의미 검증

- quality의 공식 shard 1/2는 서로 다른 final 및 `.download` 경로로 mapping되며, `modelURL(for:)`는 shard 1 경로를 반환한다.
- 모든 shard final이 95% size floor, regular-file, SHA-256 검증을 통과할 때만 `.ready`다.
- 검증된 완료 shard만 있고 형제 shard가 없으면 완료 bytes를 포함한 `.partial`이다. 완료 shard와 다음 shard `.download`가 함께 있으면 양쪽 bytes를 합산한 `.partial`이다.
- checksum mismatch 및 너무 작은 artifact는 artifact filename과 원인이 포함된 `.corrupt`다.
- package 삭제는 선택한 model의 모든 final/partial artifact만 제거하며, 누락 파일 삭제도 성공한다.

## Self-review

- addendum의 required public interface와 package-level status semantics를 대조했다.
- 실제 다운로드나 real model artifact를 사용하지 않았고, 모든 test fixture는 tiny `Data`와 계산된 SHA-256이다.
- `git diff --check` 통과.

## Commit

- `Add LocalAIModelStore for multi-artifact lifecycle` (this report is included in the same commit).

## 우려

- `make test-transcription` 중 기존 `PipelineHistoryEntry` CoreData duplicate entity warning이 출력되지만 명령은 성공했고, 이 task의 변경과 무관하다.
