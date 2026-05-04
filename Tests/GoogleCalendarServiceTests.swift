import CryptoKit
import Foundation

@main
struct GoogleCalendarServiceTests {
    static func main() async throws {
        testPKCEVerifierAndChallengeAreURLSafe()
        try testPKCEPairPropagatesRandomProviderFailure()
        testAuthorizationURLContainsReadOnlyScopesAndPKCEChallenge()
        try await testLoopbackReceiverUsesAssignedPort()
        try await testTokenExchangeSurfacesGoogleErrorResponse()
        testClientSecretMissingMessageExplainsClientTypeMismatch()
        testOAuthConfigurationUsesCustomCredentialsFirst()
        testOAuthConfigurationFallsBackToBuiltInCredentials()
        testOAuthConfigurationReportsMissingClientID()
        try await testTokenExchangeOmitsClientSecret()
        try await testTokenExchangeIncludesClientSecretWhenProvided()
        try await testRefreshTokenOmitsClientSecret()
        try await testRefreshTokenIncludesClientSecretWhenProvided()
        try await testCalendarListDecodesSelectableCalendars()
        testCalendarsSortPrimaryOwnedThenSharedByDisplayName()
        testCalendarsGroupMyCalendarsBeforeSharedCalendars()
        testConnectionControlsShowCancelDuringOAuthConnection()
        testConnectionControlsAllowForcedRefreshForStoredToken()
        testSettingsTabsPlaceCalendarAfterAppearance()
        try await testEventsDecodeMinimalFieldsAndExcludeAllDayLaterInMatcher()
        try await testFetchEventsEncodesCalendarIDAsSinglePathSegment()
        try await testEventsDecodeFractionalSecondDateTimes()
        try await testFetchEventsSkipsFailedCalendars()
        print("GoogleCalendarServiceTests passed")
    }

    private static func testPKCEVerifierAndChallengeAreURLSafe() {
        let pair = GoogleCalendarAuthService.makePKCEPair()

        assert(pair.verifier.count >= 43)
        assert(pair.challenge.count >= 43)
        assert(!pair.verifier.contains("+"))
        assert(!pair.verifier.contains("/"))
        assert(!pair.verifier.contains("="))
        assert(!pair.challenge.contains("+"))
        assert(!pair.challenge.contains("/"))
        assert(!pair.challenge.contains("="))
        assert(pair.challenge == expectedChallenge(for: pair.verifier))
    }

    private static func testPKCEPairPropagatesRandomProviderFailure() throws {
        struct RandomFailure: Error {}

        do {
            _ = try GoogleCalendarAuthService.makePKCEPair { _ in throw RandomFailure() }
            assertionFailure("Expected random provider failure")
        } catch is RandomFailure {
        }
    }

    private static func testAuthorizationURLContainsReadOnlyScopesAndPKCEChallenge() {
        let callbackURL = URL(string: "http://127.0.0.1:49152/oauth2callback")!
        let url = GoogleCalendarAuthService.authorizationURL(
            clientID: "client-id.apps.googleusercontent.com",
            callbackURL: callbackURL,
            codeChallenge: "challenge-value",
            state: "state-value"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        assert(components.scheme == "https")
        assert(components.host == "accounts.google.com")
        assert(components.path == "/o/oauth2/v2/auth")
        assert(query["client_id"] == "client-id.apps.googleusercontent.com")
        assert(query["redirect_uri"] == callbackURL.absoluteString)
        assert(query["response_type"] == "code")
        assert(query["code_challenge"] == "challenge-value")
        assert(query["code_challenge_method"] == "S256")
        assert(query["access_type"] == "offline")
        assert(query["prompt"] == "consent")
        assert(query["state"] == "state-value")
        assert(query["scope"]?.contains("https://www.googleapis.com/auth/calendar.calendarlist.readonly") == true)
        assert(query["scope"]?.contains("https://www.googleapis.com/auth/calendar.events.readonly") == true)
    }

    private static func testLoopbackReceiverUsesAssignedPort() async throws {
        let receiver = try GoogleCalendarAuthService.LoopbackReceiver(state: "state-value")
        defer { receiver.cancel() }
        receiver.start()

        let callbackURL = try await receiver.waitForCallbackURL()

        assert(callbackURL.host == "127.0.0.1")
        assert(callbackURL.port != nil)
        assert(callbackURL.port != 0)
    }

    private static func testTokenExchangeSurfacesGoogleErrorResponse() async throws {
        do {
            _ = try await GoogleCalendarAuthService.exchangeCode(
                clientID: "client-id.apps.googleusercontent.com",
                clientSecret: "",
                code: "bad-code",
                codeVerifier: "verifier",
                redirectURI: "http://127.0.0.1:49152/oauth2callback"
            ) { request, body in
                assert(request.httpMethod == "POST")
                assert(String(data: body ?? Data(), encoding: .utf8)?.contains("grant_type=authorization_code") == true)
                let data = Data("""
                {
                  "error": "invalid_grant",
                  "error_description": "Bad Request"
                }
                """.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
            }
            assertionFailure("Expected token exchange to surface Google error")
        } catch let error as GoogleCalendarAuthService.OAuthError {
            assert(error.localizedDescription.contains("invalid_grant"))
            assert(error.localizedDescription.contains("Bad Request"))
        }
    }

    private static func testClientSecretMissingMessageExplainsClientTypeMismatch() {
        let error = GoogleCalendarAuthService.OAuthError.response("invalid_request", "client_secret is missing")

        assert(error.localizedDescription.contains("web OAuth client"))
        assert(error.localizedDescription.contains("Desktop app client"))
    }

    private static func testOAuthConfigurationUsesCustomCredentialsFirst() {
        let configuration = GoogleCalendarOAuthConfiguration(
            builtInClientID: "built-in.apps.googleusercontent.com",
            builtInClientSecret: "built-in-secret",
            customClientID: " custom.apps.googleusercontent.com ",
            customClientSecret: " secret-value "
        )

        assert(configuration.clientID == "custom.apps.googleusercontent.com")
        assert(configuration.clientSecret == "secret-value")
        assert(configuration.usesCustomCredentials)
        assert(configuration.isConfigured)
    }

    private static func testOAuthConfigurationFallsBackToBuiltInCredentials() {
        let configuration = GoogleCalendarOAuthConfiguration(
            builtInClientID: " built-in.apps.googleusercontent.com ",
            builtInClientSecret: " built-in-secret ",
            customClientID: " ",
            customClientSecret: " secret-value "
        )

        assert(configuration.clientID == "built-in.apps.googleusercontent.com")
        assert(configuration.clientSecret == "built-in-secret")
        assert(!configuration.usesCustomCredentials)
        assert(configuration.isConfigured)
    }

    private static func testOAuthConfigurationReportsMissingClientID() {
        let configuration = GoogleCalendarOAuthConfiguration(
            builtInClientID: " ",
            builtInClientSecret: " built-in-secret ",
            customClientID: " ",
            customClientSecret: " secret-value "
        )

        assert(configuration.clientID.isEmpty)
        assert(configuration.clientSecret == "")
        assert(!configuration.usesCustomCredentials)
        assert(!configuration.isConfigured)
    }

    private static func testTokenExchangeOmitsClientSecret() async throws {
        let token = try await GoogleCalendarAuthService.exchangeCode(
            clientID: "client-id.apps.googleusercontent.com",
            clientSecret: "",
            code: "code-value",
            codeVerifier: "verifier",
            redirectURI: "http://127.0.0.1:49152/oauth2callback"
        ) { request, body in
            let bodyString = String(data: body ?? Data(), encoding: .utf8) ?? ""
            assert(bodyString.contains("client_id=client-id.apps.googleusercontent.com"))
            assert(!bodyString.contains("client_secret"))
            assert(bodyString.contains("grant_type=authorization_code"))
            return (Data(tokenJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        assert(token.accessToken == "access-token")
        assert(token.refreshToken == "refresh-token")
    }

    private static func testTokenExchangeIncludesClientSecretWhenProvided() async throws {
        _ = try await GoogleCalendarAuthService.exchangeCode(
            clientID: "client-id.apps.googleusercontent.com",
            clientSecret: "client-secret",
            code: "code-value",
            codeVerifier: "verifier",
            redirectURI: "http://127.0.0.1:49152/oauth2callback"
        ) { request, body in
            let bodyString = String(data: body ?? Data(), encoding: .utf8) ?? ""
            assert(bodyString.contains("client_secret=client-secret"))
            return (Data(tokenJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static func testRefreshTokenOmitsClientSecret() async throws {
        let existingToken = GoogleCalendarOAuthToken(
            accessToken: "old-access-token",
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSince1970: 0),
            accountEmail: "ada@example.com"
        )

        let token = try await GoogleCalendarAuthService.refreshToken(
            clientID: "client-id.apps.googleusercontent.com",
            clientSecret: "",
            token: existingToken
        ) { request, body in
            let bodyString = String(data: body ?? Data(), encoding: .utf8) ?? ""
            assert(bodyString.contains("client_id=client-id.apps.googleusercontent.com"))
            assert(!bodyString.contains("client_secret"))
            assert(bodyString.contains("refresh_token=refresh-token"))
            assert(bodyString.contains("grant_type=refresh_token"))
            return (Data(refreshedTokenJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        assert(token.accessToken == "new-access-token")
        assert(token.refreshToken == "refresh-token")
        assert(token.accountEmail == "ada@example.com")
    }

    private static func testRefreshTokenIncludesClientSecretWhenProvided() async throws {
        let existingToken = GoogleCalendarOAuthToken(
            accessToken: "old-access-token",
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSince1970: 0),
            accountEmail: "ada@example.com"
        )

        _ = try await GoogleCalendarAuthService.refreshToken(
            clientID: "client-id.apps.googleusercontent.com",
            clientSecret: "client-secret",
            token: existingToken
        ) { request, body in
            let bodyString = String(data: body ?? Data(), encoding: .utf8) ?? ""
            assert(bodyString.contains("client_secret=client-secret"))
            return (Data(refreshedTokenJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static func testCalendarListDecodesSelectableCalendars() async throws {
        let service = GoogleCalendarService { request in
            assert(request.url?.absoluteString.contains("/users/me/calendarList") == true)
            return (Data(calendarListJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let calendars = try await service.fetchCalendars(accessToken: "token")

        assert(calendars.count == 2)
        assert(calendars[0].id == "primary")
        assert(calendars[0].displayName == "Work")
        assert(calendars[0].primary)
        assert(calendars[1].displayName == "Team")
        assert(!calendars[1].primary)
    }

    private static func testCalendarsSortPrimaryOwnedThenSharedByDisplayName() {
        let calendars = [
            GoogleCalendarInfo(id: "team", summary: "Team", summaryOverride: nil, primary: false, accessRole: "reader"),
            GoogleCalendarInfo(id: "owned-z", summary: "Zebra", summaryOverride: nil, primary: false, accessRole: "owner"),
            GoogleCalendarInfo(id: "primary", summary: "Personal", summaryOverride: nil, primary: true, accessRole: "owner"),
            GoogleCalendarInfo(id: "owned-a", summary: "Alpha", summaryOverride: nil, primary: false, accessRole: "writer"),
            GoogleCalendarInfo(id: "shared-a", summary: "Alpha Shared", summaryOverride: nil, primary: false, accessRole: "reader")
        ]

        let sorted = calendars.sortedForQuillDisplay()

        assert(sorted.map(\.id) == ["primary", "owned-a", "owned-z", "shared-a", "team"])
    }

    private static func testCalendarsGroupMyCalendarsBeforeSharedCalendars() {
        let calendars = [
            GoogleCalendarInfo(id: "team", summary: "Team", summaryOverride: nil, primary: false, accessRole: "reader"),
            GoogleCalendarInfo(id: "owned", summary: "Work", summaryOverride: nil, primary: false, accessRole: "owner"),
            GoogleCalendarInfo(id: "primary", summary: "Personal", summaryOverride: nil, primary: true, accessRole: "owner")
        ]

        let groups = calendars.groupedForQuillDisplay()

        assert(groups.count == 2)
        assert(groups[0].title == "My calendars")
        assert(groups[0].calendars.map(\.id) == ["primary", "owned"])
        assert(groups[1].title == "Shared calendars")
        assert(groups[1].calendars.map(\.id) == ["team"])
    }

    private static func testConnectionControlsShowCancelDuringOAuthConnection() {
        let controls = GoogleCalendarConnectionControls(
            isConnected: false,
            isBusy: true,
            hasPendingOAuthConnection: true
        )

        assert(controls.primaryActionTitle == "Cancel")
        assert(controls.allowsPrimaryAction)
        assert(!controls.allowsRefresh)
        assert(!controls.allowsDisconnect)
    }

    private static func testConnectionControlsAllowForcedRefreshForStoredToken() {
        let controls = GoogleCalendarConnectionControls(
            isConnected: true,
            isBusy: false,
            hasPendingOAuthConnection: false
        )

        assert(controls.primaryActionTitle == "Reconnect")
        assert(controls.allowsPrimaryAction)
        assert(controls.allowsRefresh)
        assert(controls.allowsDisconnect)
    }

    private static func testSettingsTabsPlaceCalendarAfterAppearance() {
        assert(SettingsTab.orderedCases.prefix(3) == [.general, .appearance, .calendar])
    }

    private static func testEventsDecodeMinimalFieldsAndExcludeAllDayLaterInMatcher() async throws {
        let service = GoogleCalendarService { request in
            assert(request.url?.absoluteString.contains("singleEvents=true") == true)
            return (Data(eventsJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let events = try await service.fetchEvents(
            accessToken: "token",
            calendarID: "calendar-id",
            timeMin: Date(timeIntervalSince1970: 1_000),
            timeMax: Date(timeIntervalSince1970: 2_000)
        )

        assert(events.count == 2)
        assert(events[0].id == "timed")
        assert(events[0].calendarID == "calendar-id")
        assert(events[0].title == "Timed Meeting")
        assert(events[0].attendees.first?.email == "ada@example.com")
        assert(events[0].isAllDay == false)
        assert(events[1].id == "all-day")
        assert(events[1].isAllDay == true)
    }

    private static func testFetchEventsEncodesCalendarIDAsSinglePathSegment() async throws {
        let service = GoogleCalendarService { request in
            assert(request.url?.absoluteString.contains("/calendars/team%2Fcalendar/events") == true)
            return (Data(eventsJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        _ = try await service.fetchEvents(
            accessToken: "token",
            calendarID: "team/calendar",
            timeMin: Date(timeIntervalSince1970: 1_000),
            timeMax: Date(timeIntervalSince1970: 2_000)
        )
    }

    private static func testEventsDecodeFractionalSecondDateTimes() async throws {
        let service = GoogleCalendarService { request in
            return (Data(fractionalEventsJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let events = try await service.fetchEvents(
            accessToken: "token",
            calendarID: "calendar-id",
            timeMin: Date(timeIntervalSince1970: 1_000),
            timeMax: Date(timeIntervalSince1970: 2_000)
        )

        assert(events.count == 1)
        assert(events[0].start == Date(timeIntervalSince1970: 1_800_000_000))
        assert(events[0].end == Date(timeIntervalSince1970: 1_800_003_600))
    }

    private static func testFetchEventsSkipsFailedCalendars() async throws {
        let service = GoogleCalendarService { request in
            let url = request.url!.absoluteString
            if url.contains("bad-calendar") {
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(eventsJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let events = await service.fetchEventsSkippingFailures(
            accessToken: "token",
            calendarIDs: ["bad-calendar", "good-calendar"],
            timeMin: Date(timeIntervalSince1970: 1_000),
            timeMax: Date(timeIntervalSince1970: 2_000)
        )

        assert(events.count == 2)
        assert(events.allSatisfy { $0.calendarID == "good-calendar" })
    }

    private static func expectedChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let tokenJSON = """
    {
      "access_token": "access-token",
      "refresh_token": "refresh-token",
      "expires_in": 3600
    }
    """

    private static let refreshedTokenJSON = """
    {
      "access_token": "new-access-token",
      "expires_in": 3600
    }
    """

    private static let calendarListJSON = """
    {
      "items": [
        { "id": "primary", "summary": "Personal", "summaryOverride": "Work", "primary": true, "accessRole": "owner" },
        { "id": "team@example.com", "summary": "Team", "accessRole": "reader" }
      ]
    }
    """

    private static let eventsJSON = """
    {
      "items": [
        {
          "id": "timed",
          "summary": "Timed Meeting",
          "start": { "dateTime": "1970-01-01T00:16:40Z" },
          "end": { "dateTime": "1970-01-01T00:33:20Z" },
          "attendees": [
            { "displayName": "Ada", "email": "ada@example.com", "responseStatus": "accepted", "optional": false, "self": false }
          ]
        },
        {
          "id": "all-day",
          "summary": "Holiday",
          "start": { "date": "1970-01-01" },
          "end": { "date": "1970-01-02" }
        }
      ]
    }
    """

    private static let fractionalEventsJSON = """
    {
      "items": [
        {
          "id": "fractional",
          "summary": "Fractional Meeting",
          "start": { "dateTime": "2027-01-15T08:00:00.000Z" },
          "end": { "dateTime": "2027-01-15T09:00:00.000Z" }
        }
      ]
    }
    """
}
