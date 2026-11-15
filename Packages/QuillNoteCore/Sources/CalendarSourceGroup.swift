import CoreGraphics
import Foundation

/// One account's calendars as a calendar settings list shows them, alike on
/// the Mac and the iPhone (quill-universal-private#347): one group per
/// account (an event source such as iCloud or Exchange), in the order the
/// accounts first appear, and each group's calendars by title.
public struct CalendarSourceGroup<Item> {
    /// The account's identity. Two accounts with the same name stay apart.
    public let id: String
    /// The account's name. Empty when the calendar app gives none: each app
    /// then shows its "Other" copy (`otherTitleKey`).
    public let title: String
    public let calendars: [Item]

    /// The copy key a group with no account name shows instead.
    public static var otherTitleKey: String { "Other" }

    public init(id: String, title: String, calendars: [Item]) {
        self.id = id
        self.title = title
        self.calendars = calendars
    }

    /// Groups `calendars` by `account` (an identity, not the name), accounts
    /// in first-seen order and named by their first calendar's
    /// `accountTitle`. Each group's calendars go by `title` in Finder order
    /// (`localizedStandardCompare`), then by `id` when titles compare
    /// equal, so the order is the same on every refresh and on both apps.
    public static func grouping(
        _ calendars: [Item],
        account: (Item) -> String,
        accountTitle: (Item) -> String,
        title: (Item) -> String,
        id: (Item) -> String
    ) -> [CalendarSourceGroup] {
        var order: [String] = []
        var names: [String: String] = [:]
        var byAccount: [String: [Item]] = [:]
        for calendar in calendars {
            let key = account(calendar)
            if byAccount[key] == nil {
                order.append(key)
                names[key] = accountTitle(calendar)
            }
            byAccount[key, default: []].append(calendar)
        }
        return order.map { key in
            CalendarSourceGroup(
                id: key,
                title: names[key] ?? "",
                calendars: (byAccount[key] ?? []).sorted { lhs, rhs in
                    switch title(lhs).localizedStandardCompare(title(rhs)) {
                    case .orderedAscending: true
                    case .orderedDescending: false
                    case .orderedSame: id(lhs) < id(rhs)
                    }
                }
            )
        }
    }
}

extension CalendarSourceGroup: Equatable where Item: Equatable {}
extension CalendarSourceGroup: Sendable where Item: Sendable {}

/// A calendar's color as both apps keep it: `#RRGGBB` in sRGB.
public enum CalendarColorHex {
    /// The color as `#RRGGBB`, or nil when it can't be read in sRGB.
    public static func hex(_ color: CGColor) -> String? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3 else {
            return nil
        }
        return String(
            format: "#%02X%02X%02X",
            Int((components[0] * 255).rounded()),
            Int((components[1] * 255).rounded()),
            Int((components[2] * 255).rounded())
        )
    }

    /// The red, green, and blue parts (0...1) of a `#RRGGBB` color, or nil.
    public static func rgb(_ hex: String?) -> (red: Double, green: Double, blue: Double)? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}
