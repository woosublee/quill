import Foundation
import QuillAITextCore

@main
struct TranscriptCleanupModeTests {
    static func main() throws {
        try expect(
            TranscriptCleanupMode.resolve(for: String(repeating: "가", count: 799)) == .short,
            "799 prose characters remain short"
        )
        try expect(
            TranscriptCleanupMode.resolve(for: String(repeating: "가", count: 800)) == .long,
            "800 prose characters select long"
        )
        try expect(
            TranscriptCleanupMode.resolve(
                for: "\(String(repeating: "가", count: 199))\n\n\(String(repeating: "나", count: 200))"
            ) == .short,
            "two paragraphs below 400 prose characters remain short"
        )
        try expect(
            TranscriptCleanupMode.resolve(
                for: "\(String(repeating: "가", count: 200))\n\n\(String(repeating: "나", count: 200))"
            ) == .long,
            "two paragraphs at 400 prose characters select long"
        )
        print("TranscriptCleanupModeTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TranscriptCleanupModeTestFailure(message) }
    }
}

private struct TranscriptCleanupModeTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
