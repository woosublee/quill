import Foundation

// Status colors in the Mac app come from the shared tokens (#736 Q2):
// `QuillColor.statusDone`, `statusProcessing`, `statusRecording`,
// `issueWarning`, and `issueError`. A bare `.green`, `.orange`, or `.red`
// skips the light-mode contrast values and drifts from the iPhone.
@main
struct StatusColorTokenSourceTests {
    /// Reviewed uses that aren't a status: a destructive action's color.
    static let allowed: Set<String> = [
        "Sources/NoteBrowserView.swift|.foregroundStyle(Color.red.opacity(count == 0 ? 0.4 : 0.9))",
        "Packages/QuillNoteUI/Sources/NoteFloatingToolbar.swift|public init(retry: Color = QuillColor.issueWarning, copied: Color = .accentColor, delete: Color = Color.red.opacity(0.8)) {",
    ]
    static let roots = ["Sources", "Packages/QuillNoteUI/Sources"]

    static func main() throws {
        let pattern = try NSRegularExpression(
            pattern: #"(?<![A-Za-z])(Color)?\.(green|orange|red)\b(?!:)|\bsystem(Red|Orange|Green)\b"#
        )
        // String literals are blanked first, so a "//" inside one doesn't hide
        // the code after it, and a status word inside one isn't flagged.
        let strings = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#)
        var offenders: [String] = []
        var seenAllowed: Set<String> = []
        for root in roots {
          guard let enumerator = FileManager.default.enumerator(atPath: root) else {
              preconditionFailure("\(root) not found")
          }
          for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            let path = root + "/" + relative
            let source = try String(contentsOfFile: path, encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let blanked = strings.stringByReplacingMatches(
                    in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "\"\""
                )
                let code = blanked.components(separatedBy: "//").first ?? blanked
                let original = line.components(separatedBy: "//").first ?? line
                let range = NSRange(code.startIndex..., in: code)
                guard pattern.firstMatch(in: code, range: range) != nil else { continue }
                let key = path + "|" + original.trimmingCharacters(in: .whitespaces)
                if allowed.contains(key) {
                    seenAllowed.insert(key)
                } else {
                    offenders.append("\(path):\(index + 1): \(original.trimmingCharacters(in: .whitespaces))")
                }
            }
          }
        }
        precondition(
            pattern.firstMatch(in: "x.foregroundStyle(.red)", range: NSRange(location: 0, length: 23)) != nil,
            "the pattern must catch a bare status literal"
        )
        let urlLine = #"Link("Docs", destination: URL(string: "https://x")!).foregroundStyle(.red)"#
        let urlBlanked = strings.stringByReplacingMatches(in: urlLine, range: NSRange(urlLine.startIndex..., in: urlLine), withTemplate: "\"\"")
        precondition(
            pattern.firstMatch(in: urlBlanked, range: NSRange(urlBlanked.startIndex..., in: urlBlanked)) != nil,
            "a \"//\" inside a string must not hide a literal after it"
        )
        precondition(offenders.isEmpty, "use the QuillColor status tokens instead of:\n" + offenders.joined(separator: "\n"))
        precondition(seenAllowed == allowed, "stale allow-list entries: \(allowed.subtracting(seenAllowed))")
        print("StatusColorTokenSourceTests passed")
    }
}
