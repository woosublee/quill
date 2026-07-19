import Foundation
import os

enum RecordingFrameOffset {
    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000

    static func frames(
        firstFrameMonotonicNanoseconds: UInt64,
        monotonicAnchorNanoseconds: UInt64,
        sampleRate: UInt32
    ) -> UInt64 {
        guard firstFrameMonotonicNanoseconds > monotonicAnchorNanoseconds else {
            return 0
        }
        let delta = firstFrameMonotonicNanoseconds - monotonicAnchorNanoseconds
        let seconds = delta / nanosecondsPerSecond
        let remainder = delta % nanosecondsPerSecond
        let rate = UInt64(sampleRate)

        let (wholeFrames, wholeOverflow) = seconds.multipliedReportingOverflow(
            by: rate
        )
        guard !wholeOverflow else { return UInt64.max }

        let (partialNumerator, partialOverflow) = remainder.multipliedReportingOverflow(
            by: rate
        )
        guard !partialOverflow else { return UInt64.max }
        let (roundedNumerator, roundingOverflow) = partialNumerator.addingReportingOverflow(
            nanosecondsPerSecond / 2
        )
        guard !roundingOverflow else { return UInt64.max }
        let partialFrames = roundedNumerator / nanosecondsPerSecond
        let (result, resultOverflow) = wholeFrames.addingReportingOverflow(partialFrames)
        return resultOverflow ? UInt64.max : result
    }
}

final class RecordingJournalSourceSink: NormalizedPCM16Sink {
    private let writer: RecordingPCMJournalWriter
    private let monotonicAnchorNanoseconds: UInt64
    private let firstFrameOffsetLock = OSAllocatedUnfairLock<UInt64?>(initialState: nil)

    init(
        writer: RecordingPCMJournalWriter,
        monotonicAnchorNanoseconds: UInt64
    ) {
        self.writer = writer
        self.monotonicAnchorNanoseconds = monotonicAnchorNanoseconds
    }

    func enqueue(_ copiedPCM16LE: Data) {
        guard !copiedPCM16LE.isEmpty else { return }
        writer.enqueue(
            copiedPCM16LE,
            firstCommittedFrameOffset: selectFirstOffset(0)
        )
    }

    func enqueue(
        _ copiedPCM16LE: Data,
        firstFrameMonotonicNanoseconds: UInt64
    ) {
        guard !copiedPCM16LE.isEmpty else { return }
        let candidate = RecordingFrameOffset.frames(
            firstFrameMonotonicNanoseconds: firstFrameMonotonicNanoseconds,
            monotonicAnchorNanoseconds: monotonicAnchorNanoseconds,
            sampleRate: RecordingPCMFormat.canonical.sampleRate
        )
        writer.enqueue(
            copiedPCM16LE,
            firstCommittedFrameOffset: selectFirstOffset(candidate)
        )
    }

    private func selectFirstOffset(_ candidate: UInt64) -> UInt64 {
        firstFrameOffsetLock.withLock { offset in
            if let existing = offset { return existing }
            offset = candidate
            return candidate
        }
    }
}
