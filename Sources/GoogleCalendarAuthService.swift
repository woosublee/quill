#if canImport(AppKit)
import AppKit
#endif
import CryptoKit
import Foundation
import Network
import Security

struct GoogleCalendarTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

struct GoogleCalendarErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

struct GoogleCalendarAuthService {
    private static let formURLEncodedAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    struct PKCEPair: Equatable {
        let verifier: String
        let challenge: String
    }

    struct SecureRandomError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            "Secure random generation failed with status \(status)"
        }
    }

    typealias Transport = (URLRequest, Data?) async throws -> (Data, URLResponse)

    static let scopes = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly"
    ]

    static func makePKCEPair() -> PKCEPair {
        do {
            return try makePKCEPair(randomBytes: secureRandomBytes)
        } catch {
            preconditionFailure("Failed to generate secure random bytes for Google Calendar OAuth PKCE")
        }
    }

    static func makePKCEPair(randomBytes: (Int) throws -> Data) throws -> PKCEPair {
        let verifier = base64URLEncoded(try randomBytes(32))
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncoded(Data(digest))
    }

    static func authorizationURL(
        clientID: String,
        callbackURL: URL,
        codeChallenge: String,
        state: String
    ) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: callbackURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    #if canImport(AppKit)
    static func openAuthorizationPage(
        clientID: String,
        callbackURL: URL,
        codeChallenge: String,
        state: String
    ) {
        NSWorkspace.shared.open(
            authorizationURL(
                clientID: clientID,
                callbackURL: callbackURL,
                codeChallenge: codeChallenge,
                state: state
            )
        )
    }
    #endif

    final class LoopbackReceiver: @unchecked Sendable {
        private var listener: NWListener?
        private var codeContinuation: CheckedContinuation<String, Error>?
        private var callbackURLContinuation: CheckedContinuation<URL, Error>?
        private var pendingResult: Result<String, Error>?
        private var callbackURL: URL?
        private var timeoutWorkItem: DispatchWorkItem?
        private var isStarted = false
        private var didComplete = false
        private let state: String
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "GoogleCalendarAuthService.LoopbackReceiver")

        init(state: String) throws {
            self.state = state
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start(timeoutSeconds: TimeInterval = 120) {
            guard !isStarted else { return }
            isStarted = true
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = self.listener?.port, port.rawValue != 0 else {
                        self?.complete(.failure(OAuthError.requestFailed))
                        return
                    }
                    self.markReady(port: port)
                case .failed, .cancelled:
                    self?.complete(.failure(OAuthError.requestFailed))
                default:
                    break
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.complete(.failure(OAuthError.requestFailed))
            }
            self.timeoutWorkItem = timeoutWorkItem
            queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)
            listener?.start(queue: queue)
        }

        func waitForCallbackURL() async throws -> URL {
            try Task.checkCancellation()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    switch registerCallbackURL(continuation) {
                    case .success(let callbackURL):
                        continuation.resume(returning: callbackURL)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    case nil:
                        break
                    }
                }
            } onCancel: { [weak self] in
                self?.cancel()
            }
        }

        func waitForCode() async throws -> String {
            try Task.checkCancellation()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    switch registerCode(continuation) {
                    case .success(let code):
                        continuation.resume(returning: code)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    case nil:
                        break
                    }
                }
            } onCancel: { [weak self] in
                self?.cancel()
            }
        }

        func cancel() {
            let continuations: (CheckedContinuation<String, Error>?, CheckedContinuation<URL, Error>?) = lock.withLock {
                guard !didComplete else { return (nil, nil) }
                didComplete = true
                let codeContinuation = self.codeContinuation
                let callbackURLContinuation = self.callbackURLContinuation
                self.codeContinuation = nil
                self.callbackURLContinuation = nil
                pendingResult = nil
                return (codeContinuation, callbackURLContinuation)
            }
            cleanup()
            continuations.0?.resume(throwing: CancellationError())
            continuations.1?.resume(throwing: CancellationError())
        }

        private func registerCallbackURL(_ continuation: CheckedContinuation<URL, Error>) -> Result<URL, Error>? {
            lock.withLock {
                if let callbackURL {
                    return .success(callbackURL)
                }
                if didComplete {
                    return .failure(OAuthError.requestFailed)
                }
                callbackURLContinuation = continuation
                return nil
            }
        }

        private func registerCode(_ continuation: CheckedContinuation<String, Error>) -> Result<String, Error>? {
            lock.withLock {
                if let pendingResult {
                    self.pendingResult = nil
                    return pendingResult
                }
                if didComplete {
                    return .failure(OAuthError.requestFailed)
                }
                codeContinuation = continuation
                return nil
            }
        }

        private func markReady(port: NWEndpoint.Port) {
            let callbackURL = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth2callback")!
            let continuation: CheckedContinuation<URL, Error>? = lock.withLock {
                guard !didComplete else { return nil }
                self.callbackURL = callbackURL
                let continuation = callbackURLContinuation
                callbackURLContinuation = nil
                return continuation
            }
            continuation?.resume(returning: callbackURL)
        }

        private func handle(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
                guard let self else { return }
                guard let data,
                      let request = String(data: data, encoding: .utf8),
                      let firstLine = request.components(separatedBy: "\r\n").first,
                      let url = Self.url(from: firstLine),
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let queryItems = components.queryItems,
                      let code = Self.singleValue(named: "code", in: queryItems),
                      let callbackState = Self.singleValue(named: "state", in: queryItems),
                      callbackState == state,
                      !code.isEmpty else {
                    sendResponse("400 Bad Request", body: "Google Calendar sign-in failed.", on: connection)
                    complete(.failure(OAuthError.requestFailed))
                    return
                }
                sendResponse("200 OK", body: "You can return to Quill.", on: connection)
                complete(.success(code))
            }
        }

        private func complete(_ result: Result<String, Error>) {
            let continuations: (CheckedContinuation<String, Error>?, CheckedContinuation<URL, Error>?) = lock.withLock {
                guard !didComplete else { return (nil, nil) }
                didComplete = true
                let codeContinuation = self.codeContinuation
                let callbackURLContinuation = self.callbackURLContinuation
                self.codeContinuation = nil
                self.callbackURLContinuation = nil
                if codeContinuation == nil {
                    pendingResult = result
                }
                return (codeContinuation, callbackURLContinuation)
            }
            cleanup()
            if let callbackURLContinuation = continuations.1 {
                switch result {
                case .success:
                    callbackURLContinuation.resume(throwing: OAuthError.requestFailed)
                case .failure(let error):
                    callbackURLContinuation.resume(throwing: error)
                }
            }
            guard let codeContinuation = continuations.0 else { return }
            switch result {
            case .success(let code):
                codeContinuation.resume(returning: code)
            case .failure(let error):
                codeContinuation.resume(throwing: error)
            }
        }

        private func cleanup() {
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            listener?.cancel()
            listener = nil
        }

        private func sendResponse(_ status: String, body: String, on connection: NWConnection) {
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\n\r\n<html><body>\(body)</body></html>"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }

        private static func singleValue(named name: String, in items: [URLQueryItem]) -> String? {
            let values = items.filter { $0.name == name }
            guard values.count == 1 else { return nil }
            return values[0].value
        }

        private static func url(from requestLine: String) -> URL? {
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            return URL(string: "http://127.0.0.1\(parts[1])")
        }
    }

    static func token(from response: GoogleCalendarTokenResponse, existingRefreshToken: String? = nil) -> GoogleCalendarOAuthToken {
        GoogleCalendarOAuthToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? existingRefreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn),
            accountEmail: nil
        )
    }

    static func exchangeCode(
        clientID: String,
        clientSecret: String,
        code: String,
        codeVerifier: String,
        redirectURI: String,
        transport: @escaping Transport = defaultTransport
    ) async throws -> GoogleCalendarOAuthToken {
        var body = [
            "client_id": clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        addClientSecret(clientSecret, to: &body)
        let response = try await tokenRequest(body: body, transport: transport)
        return token(from: response)
    }

    static func refreshToken(
        clientID: String,
        clientSecret: String,
        token: GoogleCalendarOAuthToken,
        transport: @escaping Transport = defaultTransport
    ) async throws -> GoogleCalendarOAuthToken {
        guard let refreshToken = token.refreshToken else {
            throw OAuthError.missingRefreshToken
        }
        var body = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        addClientSecret(clientSecret, to: &body)
        let response = try await tokenRequest(body: body, transport: transport)
        var refreshed = self.token(from: response, existingRefreshToken: refreshToken)
        refreshed.accountEmail = token.accountEmail
        return refreshed
    }

    private static func addClientSecret(_ clientSecret: String, to body: inout [String: String]) {
        let trimmed = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        body["client_secret"] = trimmed
    }

    private static func tokenRequest(
        body: [String: String],
        transport: @escaping Transport
    ) async throws -> GoogleCalendarTokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyString = body.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }.joined(separator: "&")
        let (data, response) = try await transport(request, Data(bodyString.utf8))
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.requestFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            if let errorResponse = try? JSONDecoder().decode(GoogleCalendarErrorResponse.self, from: data) {
                throw OAuthError.response(errorResponse.error, errorResponse.errorDescription)
            }
            throw OAuthError.requestFailed
        }
        return try JSONDecoder().decode(GoogleCalendarTokenResponse.self, from: data)
    }

    private static func defaultTransport(_ request: URLRequest, _ body: Data?) async throws -> (Data, URLResponse) {
        var request = request
        request.httpBody = body
        return try await URLSession.shared.data(for: request)
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formURLEncodedAllowed) ?? value
    }

    enum OAuthError: LocalizedError {
        case missingRefreshToken
        case requestFailed
        case response(String, String?)

        var errorDescription: String? {
            switch self {
            case .missingRefreshToken:
                return "Google Calendar refresh token is missing."
            case .requestFailed:
                return "Google Calendar OAuth request failed."
            case .response(let error, let description):
                if error == "invalid_request", description == "client_secret is missing" {
                    return "Google Calendar OAuth failed: this client ID is being treated as a web OAuth client. Create a Google OAuth Desktop app client and paste that client ID, then reconnect."
                }
                guard let description, !description.isEmpty else {
                    return "Google Calendar OAuth failed: \(error)"
                }
                return "Google Calendar OAuth failed: \(error) — \(description)"
            }
        }
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SecureRandomError(status: status)
        }
        return Data(bytes)
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
