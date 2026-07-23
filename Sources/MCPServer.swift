import Foundation
import Network
import Combine

// MCP server over HTTP (localhost:3457)
// Claude Code MCP config:
//   { "mcpServers": { "quill": { "url": "http://localhost:3457" } } }

final class MCPServer {
    static let port: UInt16 = 3457

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.quill.mcp", qos: .utility)
    private var sseClients: [SSEClient] = []
    private let sseClientsLock = NSLock()

    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
    }

    func start() throws {
        let params = MCPLocalAccessPolicy.listenerParameters()
        let nwPort = NWEndpoint.Port(rawValue: Self.port)!
        listener = try NWListener(using: params, on: nwPort)

        listener?.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[MCP] Server ready on port \(Self.port)")
            case .failed(let error):
                print("[MCP] Server failed: \(error)")
            default:
                break
            }
        }
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        sseClientsLock.lock()
        sseClients.forEach { $0.connection.cancel() }
        sseClients.removeAll()
        sseClientsLock.unlock()
    }

    // Called by AppState when transcription completes
    func notifyRecordingCompleted(transcript: String, context: String) {
        let payload: [String: Any] = [
            "transcript": transcript,
            "context": context,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        sendSSEEvent(event: "recording/completed", data: payload)
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        guard MCPLocalAccessPolicy.isLoopback(endpoint: connection.endpoint) else {
            connection.cancel()
            return
        }

        connection.start(queue: queue)
        receiveRequest(connection: connection, buffer: Data())
    }

    private func receiveRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data { accumulated.append(data) }

            // Wait until we have the full HTTP request (headers + body)
            if let request = HTTPRequest(data: accumulated) {
                self.route(request: request, connection: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveRequest(connection: connection, buffer: accumulated)
            }
        }
    }

    private func route(request: HTTPRequest, connection: NWConnection) {
        guard MCPLocalAccessPolicy.allowsRequest(headers: request.headers, port: Self.port) else {
            sendResponse(connection: connection, status: 403, body: "Forbidden")
            return
        }

        switch (request.method, request.path) {
        case ("POST", "/"), ("POST", "/mcp"):
            handleMCPPost(request: request, connection: connection)
        case ("GET", "/sse"), ("GET", "/mcp/sse"):
            handleSSE(connection: connection)
        default:
            sendResponse(connection: connection, status: 404, body: "Not Found")
        }
    }

    // MARK: - MCP JSON-RPC

    private func handleMCPPost(request: HTTPRequest, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            sendResponse(connection: connection, status: 400, body: "Invalid JSON")
            return
        }

        let method = json["method"] as? String ?? ""
        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let result = self.dispatch(method: method, params: params)

            let response: [String: Any]
            if let error = result["error"] {
                response = ["jsonrpc": "2.0", "id": id as Any, "error": error]
            } else {
                response = ["jsonrpc": "2.0", "id": id as Any, "result": result["result"] as Any]
            }

            if let data = try? JSONSerialization.data(withJSONObject: response),
               let body = String(data: data, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200,
                                  headers: [("Content-Type", "application/json")],
                                  body: body)
            }
        }
    }

    @MainActor
    private func dispatch(method: String, params: [String: Any]) -> [String: Any] {
        switch method {
        case "initialize":
            return ["result": [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:], "notifications": [:]],
                "serverInfo": ["name": "quill", "version": "1.0.0"]
            ]]

        case "notifications/initialized":
            return ["result": [:] as [String: Any]]

        case "tools/list":
            return ["result": ["tools": toolDefinitions()]]

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return ["result": callTool(name: name, args: args)]

        default:
            return ["error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    // MARK: - Tool definitions

    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "start_recording",
                "description": "Start a Quill recording session. Call this to begin recording audio.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "context": [
                            "type": "string",
                            "description": "Initial context: meeting name, participants, Notion URL, topic, etc."
                        ]
                    ]
                ]
            ],
            [
                "name": "add_context",
                "description": "Add context to the current recording session while it is in progress.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": [
                            "type": "string",
                            "description": "Context to append (e.g. participant info, Notion URL, agenda)"
                        ]
                    ],
                    "required": ["text"]
                ]
            ],
            [
                "name": "stop_recording",
                "description": "Stop the current recording; transcribe it if transcription was enabled when recording began, otherwise save an audio-only note.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "get_status",
                "description": "Get the current recording/transcription status and accumulated context.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "list_transcripts",
                "description": "List recent transcription history entries with id, timestamp, and a short preview.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of entries to return (default: 10, max: 50)"
                        ]
                    ]
                ]
            ],
            [
                "name": "get_transcript",
                "description": "Get the full content of a specific transcription entry by id.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "UUID of the transcript entry from list_transcripts"
                        ]
                    ],
                    "required": ["id"]
                ]
            ],
            [
                "name": "get_meeting_source",
                "description": "Get structured meeting source data (title, timestamps, calendar match, attendees, audio path, transcript) for a transcript id as JSON. Use this for meeting-note generation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "UUID of the transcript entry from list_transcripts"
                        ]
                    ],
                    "required": ["id"]
                ]
            ]
        ]
    }

    // MARK: - Tool calls (must run on main thread)

    @MainActor
    private func callTool(name: String, args: [String: Any]) -> [String: Any] {
        guard let appState else {
            return textContent("Error: Quill is not ready", isError: true)
        }

        switch name {
        case "start_recording":
            if appState.isRecording {
                return textContent("Already recording.")
            }
            if let context = args["context"] as? String, !context.isEmpty {
                appState.mcpAdditionalContext = context
            }
            appState.startRecordingFromMCP()
            let ctx = appState.mcpAdditionalContext
            return textContent("Recording started.\(ctx.isEmpty ? "" : " Context: \(ctx)")")

        case "add_context":
            guard let text = args["text"] as? String, !text.isEmpty else {
                return textContent("Error: 'text' is required.", isError: true)
            }
            if appState.mcpAdditionalContext.isEmpty {
                appState.mcpAdditionalContext = text
            } else {
                appState.mcpAdditionalContext += "\n" + text
            }
            return textContent("Context added: \(text)")

        case "stop_recording":
            switch appState.stopRecordingFromMCP() {
            case .notRecording:
                return textContent("Not currently recording.")
            case .transcribing:
                return textContent(
                    "Recording stopped. Transcription in progress — listen for recording/completed event."
                )
            case .savingAudioOnly:
                return textContent("Recording stopped. Audio note is being saved.")
            }

        case "get_status":
            let status: String
            if appState.isRecording {
                status = "recording"
            } else if appState.isTranscribing {
                status = "transcribing"
            } else {
                status = "idle"
            }
            let ctx = appState.mcpAdditionalContext
            let failed = appState.mcpLastRecordingFailed
            let lastEntry = appState.pipelineHistory.first
            let lastTranscript = lastEntry?.postProcessedTranscript ?? lastEntry?.rawTranscript ?? ""
            let transcriptValue = failed ? "(transcription failed)" : lastTranscript.isEmpty ? "(none)" : lastTranscript
            return textContent("""
                status: \(status)
                context: \(ctx.isEmpty ? "(none)" : ctx)
                last_transcript: \(transcriptValue)
                """)

        case "list_transcripts":
            let limit = max(0, min(args["limit"] as? Int ?? 10, 50))
            let entries = Array(appState.pipelineHistory.prefix(limit))
            if entries.isEmpty {
                return textContent("No transcripts found.")
            }
            let formatter = ISO8601DateFormatter()
            let lines = entries.map { item -> String in
                let preview = item.postProcessedTranscript.isEmpty ? item.rawTranscript : item.postProcessedTranscript
                let truncated = preview.count > 80 ? String(preview.prefix(80)) + "…" : preview
                return "[\(formatter.string(from: item.timestamp))] \(item.id.uuidString)\n  \(truncated)"
            }
            return textContent(lines.joined(separator: "\n\n"))

        case "get_transcript":
            guard let idString = args["id"] as? String, let uuid = UUID(uuidString: idString) else {
                return textContent("Error: valid 'id' is required.", isError: true)
            }
            guard let item = appState.pipelineHistory.first(where: { $0.id == uuid }) else {
                return textContent("Error: transcript not found.", isError: true)
            }
            let formatter = ISO8601DateFormatter()
            var lines = ["id: \(item.id.uuidString)", "timestamp: \(formatter.string(from: item.timestamp))"]
            if !item.postProcessedTranscript.isEmpty {
                lines.append("transcript: \(item.postProcessedTranscript)")
            }
            if !item.rawTranscript.isEmpty {
                lines.append("raw_transcript: \(item.rawTranscript)")
            }
            if !item.contextSummary.isEmpty {
                lines.append("context: \(item.contextSummary)")
            }
            return textContent(lines.joined(separator: "\n"))

        case "get_meeting_source":
            guard let idString = args["id"] as? String, let uuid = UUID(uuidString: idString) else {
                return textContent("Error: valid 'id' is required.", isError: true)
            }
            guard let item = appState.pipelineHistory.first(where: { $0.id == uuid }) else {
                return textContent("Error: transcript not found.", isError: true)
            }
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime]
            isoFormatter.timeZone = TimeZone.current
            let payload = MeetingSourcePayload.make(
                item: item,
                audioDirectory: AppState.audioStorageDirectory(),
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                formatter: isoFormatter
            )
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]),
                  let json = String(data: data, encoding: .utf8) else {
                return textContent("Error: failed to encode meeting source.", isError: true)
            }
            return textContent(json)

        default:
            return textContent("Unknown tool: \(name)", isError: true)
        }
    }

    private func textContent(_ text: String, isError: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError { result["isError"] = true }
        return result
    }

    // MARK: - SSE

    private func handleSSE(connection: NWConnection) {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
        ]
        let headerBlock = headers.joined(separator: "\r\n") + "\r\n\r\n"

        connection.send(content: headerBlock.data(using: .utf8), completion: .contentProcessed({ _ in }))

        let client = SSEClient(connection: connection)
        sseClientsLock.lock()
        sseClients.append(client)
        sseClientsLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.sseClientsLock.lock()
                self?.sseClients.removeAll { $0.id == client.id }
                self?.sseClientsLock.unlock()
            }
        }

        // Keep-alive ping every 15s
        schedulePing(client: client)
    }

    private func schedulePing(client: SSEClient) {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            self.sseClientsLock.lock()
            let alive = self.sseClients.contains { $0.id == client.id }
            self.sseClientsLock.unlock()
            guard alive else { return }

            client.connection.send(
                content: ": ping\n\n".data(using: .utf8),
                completion: .contentProcessed({ [weak self] error in
                    if error == nil { self?.schedulePing(client: client) }
                })
            )
        }
    }

    private func sendSSEEvent(event: String, data: [String: Any]) {
        guard let dataJSON = try? JSONSerialization.data(withJSONObject: data),
              let dataString = String(data: dataJSON, encoding: .utf8) else { return }

        let message = "event: \(event)\ndata: \(dataString)\n\n"
        let messageData = message.data(using: .utf8)!

        sseClientsLock.lock()
        let clients = sseClients
        sseClientsLock.unlock()

        for client in clients {
            client.connection.send(content: messageData, completion: .contentProcessed({ _ in }))
        }
    }

    // MARK: - HTTP helpers

    private func sendResponse(
        connection: NWConnection,
        status: Int,
        headers: [(String, String)] = [],
        body: String
    ) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        default: statusText = "Unknown"
        }

        var headerLines = ["HTTP/1.1 \(status) \(statusText)"]
        var allHeaders = headers
        if !allHeaders.contains(where: { $0.0 == "Content-Type" }) {
            allHeaders.append(("Content-Type", "text/plain; charset=utf-8"))
        }
        allHeaders.append(("Content-Length", "\(body.utf8.count)"))
        allHeaders.append(("Connection", "close"))
        headerLines += allHeaders.map { "\($0.0): \($0.1)" }

        let response = headerLines.joined(separator: "\r\n") + "\r\n\r\n" + body
        connection.send(
            content: response.data(using: .utf8),
            completion: .contentProcessed({ _ in connection.cancel() })
        )
    }
}

// MARK: - SSEClient

private final class SSEClient {
    let id = UUID()
    let connection: NWConnection
    init(connection: NWConnection) { self.connection = connection }
}

// MARK: - HTTPRequest parser

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(data: Data) {
        // Find header/body separator in raw bytes (\r\n\r\n = 0x0d 0x0a 0x0d 0x0a)
        // NOTE: Must use byte-based search. Swift text.distance() counts \r\n as one
        // grapheme cluster, so it undercounts bytes and produces wrong body offsets.
        let separatorBytes = Data([0x0d, 0x0a, 0x0d, 0x0a])
        guard let separatorByteRange = data.range(of: separatorBytes) else { return nil }

        let headerData = data[data.startIndex..<separatorByteRange.lowerBound]
        let bodyStart = separatorByteRange.upperBound

        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        method = parts[0]
        path = String(parts[1].split(separator: "?").first ?? Substring(parts[1]))

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.components(separatedBy: ": ")
            if kv.count >= 2 {
                parsedHeaders[kv[0].lowercased()] = kv.dropFirst().joined(separator: ": ")
            }
        }
        headers = parsedHeaders

        // Verify Content-Length matches before returning
        let bodyData = data[bodyStart...]
        if let contentLengthStr = parsedHeaders["content-length"],
           let contentLength = Int(contentLengthStr) {
            guard bodyData.count >= contentLength else { return nil }
            body = bodyData.prefix(contentLength)
        } else {
            body = bodyData
        }
    }
}
