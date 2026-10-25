import Foundation
import QuillAITextCore

struct SummarySourceData: Codable, Equatable, Sendable {
    let transcript: String
    let calendar: MeetingSummaryCalendarContext?
}
