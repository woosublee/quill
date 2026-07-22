import Foundation
import Network

@main
struct MCPLocalAccessPolicyTests {
    static func main() throws {
        testAcceptsExpectedLocalHosts()
        testRejectsMissingAndUnexpectedHosts()
        testRejectsEveryBrowserOrigin()
        testAcceptsOnlyNumericLoopbackPeers()
        testListenerIsRestrictedToLoopback()
        try testMCPServerUsesPolicyAndDoesNotEmitCORSHeaders()
        try testMCPStopRecordingCopySupportsRecordOnly()
        print("MCPLocalAccessPolicyTests passed")
    }

    private static func testAcceptsExpectedLocalHosts() {
        for host in ["localhost:3457", "127.0.0.1:3457", "[::1]:3457"] {
            assertTrue(
                MCPLocalAccessPolicy.allowsRequest(headers: ["host": host], port: 3457),
                "Expected Host \(host) to be accepted"
            )
        }

        assertTrue(
            MCPLocalAccessPolicy.allowsRequest(headers: ["host": " LOCALHOST:3457 "], port: 3457),
            "Expected Host matching to ignore case and surrounding whitespace"
        )
    }

    private static func testRejectsMissingAndUnexpectedHosts() {
        for headers in [
            [String: String](),
            ["host": "localhost"],
            ["host": "localhost:9999"],
            ["host": "192.168.1.20:3457"],
            ["host": "evil.example:3457"]
        ] {
            assertFalse(
                MCPLocalAccessPolicy.allowsRequest(headers: headers, port: 3457),
                "Expected headers \(headers) to be rejected"
            )
        }
    }

    private static func testRejectsEveryBrowserOrigin() {
        for origin in ["https://evil.example", "http://localhost:3000", "null", ""] {
            assertFalse(
                MCPLocalAccessPolicy.allowsRequest(
                    headers: ["host": "localhost:3457", "origin": origin],
                    port: 3457
                ),
                "Expected Origin \(origin) to be rejected"
            )
        }
    }

    private static func testAcceptsOnlyNumericLoopbackPeers() {
        assertTrue(
            MCPLocalAccessPolicy.isLoopback(endpoint: .hostPort(host: .ipv4(.loopback), port: 50000)),
            "Expected IPv4 loopback peer to be accepted"
        )
        assertTrue(
            MCPLocalAccessPolicy.isLoopback(endpoint: .hostPort(host: .ipv6(.loopback), port: 50000)),
            "Expected IPv6 loopback peer to be accepted"
        )
        assertFalse(
            MCPLocalAccessPolicy.isLoopback(endpoint: .hostPort(host: "192.168.1.20", port: 50000)),
            "Expected LAN peer to be rejected"
        )
        assertFalse(
            MCPLocalAccessPolicy.isLoopback(endpoint: .hostPort(host: "localhost", port: 50000)),
            "Expected unresolved peer names to be rejected"
        )
    }

    private static func testListenerIsRestrictedToLoopback() {
        let parameters = MCPLocalAccessPolicy.listenerParameters()
        assertEqual(parameters.requiredInterfaceType, .loopback)
        assertTrue(parameters.acceptLocalOnly, "Expected listener to accept local connections only")
        assertTrue(parameters.allowLocalEndpointReuse, "Expected listener to preserve local endpoint reuse")
    }

    private static func testMCPServerUsesPolicyAndDoesNotEmitCORSHeaders() throws {
        let source = try String(contentsOfFile: "Sources/MCPServer.swift", encoding: .utf8)

        assertContains(source, "MCPLocalAccessPolicy.listenerParameters()")
        assertContains(source, "MCPLocalAccessPolicy.isLoopback(endpoint: connection.endpoint)")
        assertContains(source, "MCPLocalAccessPolicy.allowsRequest(headers: request.headers, port: Self.port)")
        assertDoesNotContain(source, "Access-Control-Allow-Origin")
        assertDoesNotContain(source, "corsHeaders()")
    }

    private static func testMCPStopRecordingCopySupportsRecordOnly() throws {
        let source = try String(contentsOfFile: "Sources/MCPServer.swift", encoding: .utf8)
        assertContains(source, "appState.transcriptionEnabled")
        assertContains(source, "Recording stopped. Audio note is being saved.")
    }

    private static func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("Assertion failed: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func assertFalse(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertTrue(!condition(), message)
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T) {
        assertTrue(actual == expected, "Expected \(expected), got \(actual)")
    }

    private static func assertContains(_ text: String, _ expected: String) {
        assertTrue(text.contains(expected), "Expected source to contain: \(expected)")
    }

    private static func assertDoesNotContain(_ text: String, _ unexpected: String) {
        assertFalse(text.contains(unexpected), "Expected source not to contain: \(unexpected)")
    }
}
