# Unify Transcript Post-Processing Flow

**Date:** 2026-05-29
**Issue:** #46

## Problem

세 가지 녹음 경로(방금 녹음, 재시도, 오디오 import)가 거의 동일한 포스트프로세싱 로직을 각각 별도 함수로 구현하고 있다.

- `processTranscript()` — 방금 녹음
- `processTranscriptForRetry()` — 재시도
- `processImportedTranscript()` — 오디오 import

로직 변경 시 3군데를 모두 수정해야 하고, 누락 시 경로별로 동작이 달라지는 버그가 생길 수 있다.

## Design

### 통합 함수 시그니처

```swift
private func processTranscript(
    _ rawTranscript: String,
    intent: SessionIntent,
    context: AppContext,
    postProcessingService: PostProcessingService,
    customVocabulary: String,
    customSystemPrompt: String,
    outputLanguage: String,
    postProcessingEnabled: Bool
) async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String)
```

기존 `processTranscript()`에 `postProcessingEnabled: Bool` 파라미터를 추가한다. 기존에 `self.disablePostProcessing`을 직접 읽던 방식을 제거하고 호출부가 명시적으로 넘기도록 변경한다.

### 호출부 변경

| 경로 | intent | postProcessingEnabled |
|---|---|---|
| 방금 녹음 | 기존 그대로 | `capturedPostProcessingEnabled` (이미 캡처됨) |
| 재시도 | `snapshot.restoredIntent` | `snapshot.postProcessingEnabled` |
| 오디오 import | `.dictation` | `capturedPostProcessingEnabled` |

import 경로는 `intent: .dictation`을 넘겨 Edit Mode 분기를 자연스럽게 건너뛴다.

### 제거 대상

- `processTranscriptForRetry()` 함수 전체
- `processImportedTranscript()` 함수 전체

### 내부 로직

현재 `processTranscript()` 로직을 그대로 유지한다. 변경은 파라미터 추가와 `self.disablePostProcessing` 참조 제거뿐이다.

## 변경 범위

- `Sources/AppState.swift` 한 파일만 수정
- 행동 변화 없음 — 순수 리팩터링
