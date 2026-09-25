import Foundation

@main
struct LiveTranscriptSegmentsTests {
    static func main() throws {
        try testJoinedSkipsBlankParts()
        try testFinalTranscriptJoinsEverySegment()
        try testFinalTranscriptFallsBackWhenAnySegmentFailed()
        try testFinalTranscriptFallsBackWhenIncomplete()
        try testFeedDeliversCoalescedPartials()
        try testFeedFinishKeepsLatestPartialAndStopsDelivery()
        print("LiveTranscriptSegmentsTests passed")
    }

    private static func testJoinedSkipsBlankParts() throws {
        try expect(
            LiveTranscriptSegments.joined(["", "  first part ", "\n", "second part"])
                == "first part\nsecond part",
            "blank parts are skipped and the rest are trimmed and joined"
        )
        try expect(LiveTranscriptSegments.joined(["", " "]) == "", "only blank parts join to empty")
    }

    private static func testFinalTranscriptJoinsEverySegment() throws {
        try expect(
            LiveTranscriptSegments.finalTranscript(
                segments: ["before switch", "", "after switch"],
                isIncomplete: false
            ) == "before switch\nafter switch",
            "every finished segment is kept in order"
        )
    }

    private static func testFinalTranscriptFallsBackWhenAnySegmentFailed() throws {
        try expect(
            LiveTranscriptSegments.finalTranscript(
                segments: ["before switch", nil],
                isIncomplete: false
            ) == nil,
            "a failed segment falls back to file transcription"
        )
    }

    private static func testFinalTranscriptFallsBackWhenIncomplete() throws {
        try expect(
            LiveTranscriptSegments.finalTranscript(
                segments: ["before switch", "after switch"],
                isIncomplete: true
            ) == nil,
            "audio without live transcription falls back to file transcription"
        )
    }

    private static func testFeedDeliversCoalescedPartials() throws {
        let scheduler = ManualScheduler()
        let deliveries = Deliveries()
        let feed = LiveTranscriptSegmentFeed(
            interval: 0.25,
            schedule: scheduler.schedule,
            deliver: { deliveries.append($0) }
        )

        feed.submit("one")
        feed.submit("one two")
        feed.submit("one two three")
        scheduler.runAll()

        try expect(deliveries.values == ["one", "one two three"], "partials are coalesced to the latest")
    }

    private static func testFeedFinishKeepsLatestPartialAndStopsDelivery() throws {
        let scheduler = ManualScheduler()
        let deliveries = Deliveries()
        let feed = LiveTranscriptSegmentFeed(
            interval: 0.25,
            schedule: scheduler.schedule,
            deliver: { deliveries.append($0) }
        )

        feed.submit("one")
        scheduler.runAll()
        feed.submit("one two")

        try expect(feed.finish() == "one two", "finish returns the latest partial even if undelivered")
        scheduler.runAll()
        feed.submit("late")
        scheduler.runAll()
        try expect(deliveries.values == ["one"], "no delivery after finish")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw TestFailure(message)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []

    var schedule: LatestValueProgressCoalescer<String>.Schedule {
        { [self] _, operation in
            lock.withLock { operations.append(operation) }
        }
    }

    func runAll() {
        while let operation = lock.withLock({ operations.isEmpty ? nil : operations.removeFirst() }) {
            operation()
        }
    }
}

private final class Deliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
