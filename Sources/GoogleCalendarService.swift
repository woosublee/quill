import Foundation

struct GoogleCalendarService {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport
    private let baseURL = URL(string: "https://www.googleapis.com/calendar/v3")!
    private static let calendarIDPathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    private let decoder: JSONDecoder
    private let encoderDateFormatter: ISO8601DateFormatter

    init(transport: @escaping Transport = { request in try await URLSession.shared.data(for: request) }) {
        self.transport = transport
        decoder = JSONDecoder()
        encoderDateFormatter = ISO8601DateFormatter()
        encoderDateFormatter.formatOptions = [.withInternetDateTime]
    }

    func fetchCalendars(accessToken: String) async throws -> [GoogleCalendarInfo] {
        var components = URLComponents(url: baseURL.appendingPathComponent("users/me/calendarList"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "fields", value: "items(id,summary,summaryOverride,primary,accessRole)")
        ]
        let response: CalendarListResponse = try await send(url: components.url!, accessToken: accessToken)
        return response.calendars
    }

    func fetchEvents(
        accessToken: String,
        calendarID: String,
        timeMin: Date,
        timeMax: Date
    ) async throws -> [GoogleCalendarEvent] {
        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: Self.calendarIDPathAllowed) ?? calendarID
        var components = URLComponents(string: "\(baseURL.absoluteString)/calendars/\(encodedCalendarID)/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: encoderDateFormatter.string(from: timeMin)),
            URLQueryItem(name: "timeMax", value: encoderDateFormatter.string(from: timeMax)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "fields", value: "items(id,summary,start,end,attendees(displayName,email,responseStatus,optional,self))")
        ]
        let response: EventsResponse = try await send(url: components.url!, accessToken: accessToken)
        return response.items.compactMap { $0.event(calendarID: calendarID) }
    }

    func fetchEventsSkippingFailures(
        accessToken: String,
        calendarIDs: [String],
        timeMin: Date,
        timeMax: Date
    ) async -> [GoogleCalendarEvent] {
        var events: [GoogleCalendarEvent] = []
        for calendarID in calendarIDs {
            do {
                let calendarEvents = try await fetchEvents(
                    accessToken: accessToken,
                    calendarID: calendarID,
                    timeMin: timeMin,
                    timeMax: timeMax
                )
                events.append(contentsOf: calendarEvents)
            } catch {
                continue
            }
        }
        return events
    }

    private func send<Response: Decodable>(url: URL, accessToken: String) async throws -> Response {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CalendarAPIError.requestFailed
        }
        return try decoder.decode(Response.self, from: data)
    }

    enum CalendarAPIError: Error {
        case requestFailed
    }

    private struct CalendarListResponse: Decodable {
        let items: [CalendarInfoResponse]

        var calendars: [GoogleCalendarInfo] {
            items.map(\.calendar)
        }
    }

    private struct CalendarInfoResponse: Decodable {
        let id: String
        let summary: String
        let summaryOverride: String?
        let primary: Bool?
        let accessRole: String?

        var calendar: GoogleCalendarInfo {
            GoogleCalendarInfo(
                id: id,
                summary: summary,
                summaryOverride: summaryOverride,
                primary: primary ?? false,
                accessRole: accessRole
            )
        }
    }

    private struct EventsResponse: Decodable {
        let items: [EventResponse]
    }

    private struct EventResponse: Decodable {
        let id: String
        let summary: String?
        let start: EventDateTime
        let end: EventDateTime
        let attendees: [AttendeeResponse]?

        func event(calendarID: String) -> GoogleCalendarEvent? {
            guard let startDate = start.resolvedDate,
                  let endDate = end.resolvedDate else {
                return nil
            }
            return GoogleCalendarEvent(
                id: id,
                calendarID: calendarID,
                title: summary ?? "",
                start: startDate,
                end: endDate,
                isAllDay: start.date != nil || end.date != nil,
                attendees: attendees?.map { $0.attendee } ?? []
            )
        }
    }

    private struct EventDateTime: Decodable {
        private static let dateTimeFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        private static let fractionalDateTimeFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        private static let allDayDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }()

        let date: String?
        let dateTime: String?

        var resolvedDate: Date? {
            if let dateTime {
                return Self.dateTimeFormatter.date(from: dateTime) ?? Self.fractionalDateTimeFormatter.date(from: dateTime)
            }
            if let date {
                return Self.allDayDateFormatter.date(from: date)
            }
            return nil
        }
    }

    private struct AttendeeResponse: Decodable {
        let displayName: String?
        let email: String?
        let responseStatus: String?
        let optional: Bool?
        let selfValue: Bool?

        private enum CodingKeys: String, CodingKey {
            case displayName
            case email
            case responseStatus
            case optional
            case selfValue = "self"
        }

        var attendee: CalendarEventAttendee {
            CalendarEventAttendee(
                displayName: displayName,
                email: email,
                responseStatus: responseStatus,
                isOptional: optional ?? false,
                isSelf: selfValue ?? false
            )
        }
    }
}
