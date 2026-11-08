import Foundation

/// The meeting summary field being edited, so focus can move between rows
/// the same way on the Mac and the iPhone (#697).
public enum NoteSummaryField: Hashable, Sendable {
    case overview
    case point(UUID)
    case task(UUID)
    case owner(UUID)
    case dueDate(UUID)

    /// The row this field belongs to; nil for the overview.
    public var rowID: UUID? {
        switch self {
        case .overview: nil
        case .point(let id), .task(let id), .owner(let id), .dueDate(let id): id
        }
    }
}
