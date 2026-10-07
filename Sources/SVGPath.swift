import CoreGraphics
import Foundation

/// Builds a `CGPath` from SVG path data. Supports the commands used by small
/// brand marks: M, L, H, V, C, S, Z, in absolute and relative forms.
enum SVGPath {
    static func cgPath(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Tokens(data)
        var command: Character = "M"
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?

        while let next = scanner.nextCommandOrNil(defaultCommand: command) {
            command = next
            let relative = command.isLowercase
            let base = relative ? current : .zero
            switch command.uppercased() {
            case "M":
                guard let point = scanner.point(offset: base) else { return path }
                path.move(to: point)
                current = point
                subpathStart = point
                lastControl = nil
                // Extra pairs after a move are implicit line-tos.
                command = relative ? "l" : "L"
            case "L":
                guard let point = scanner.point(offset: base) else { return path }
                path.addLine(to: point)
                current = point
                lastControl = nil
            case "H":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case "V":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current)
                lastControl = nil
            case "C":
                guard let c1 = scanner.point(offset: base),
                      let c2 = scanner.point(offset: base),
                      let end = scanner.point(offset: base) else { return path }
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastControl = c2
            case "S":
                guard let c2 = scanner.point(offset: base),
                      let end = scanner.point(offset: base) else { return path }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastControl = c2
            case "Z":
                path.closeSubpath()
                current = subpathStart
                lastControl = nil
            default:
                return path
            }
        }
        return path
    }

    private struct Tokens {
        private let characters: [Character]
        private var index = 0

        init(_ data: String) {
            characters = Array(data)
        }

        private mutating func skipSeparators() {
            while index < characters.count, characters[index] == " " || characters[index] == "," || characters[index].isNewline {
                index += 1
            }
        }

        /// The next explicit command letter, or the previous command repeated
        /// when more numbers follow. `nil` at the end of the data.
        mutating func nextCommandOrNil(defaultCommand: Character) -> Character? {
            skipSeparators()
            guard index < characters.count else { return nil }
            let character = characters[index]
            if character.isLetter {
                index += 1
                return character
            }
            return defaultCommand.uppercased() == "Z" ? nil : defaultCommand
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var text = ""
            var sawDot = false
            var sawExponent = false
            while index < characters.count {
                let character = characters[index]
                if character == "-" || character == "+" {
                    let previous = text.last
                    guard text.isEmpty || previous == "e" || previous == "E" else { break }
                } else if character == "." {
                    if sawDot || sawExponent { break }
                    sawDot = true
                } else if character == "e" || character == "E" {
                    if sawExponent || text.isEmpty { break }
                    sawExponent = true
                } else if !character.isNumber {
                    break
                }
                text.append(character)
                index += 1
            }
            return Double(text).map { CGFloat($0) }
        }

        mutating func point(offset: CGPoint) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: offset.x + x, y: offset.y + y)
        }
    }
}
