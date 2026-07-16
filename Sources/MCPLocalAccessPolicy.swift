import Foundation
import Network

enum MCPLocalAccessPolicy {
    static func listenerParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        parameters.requiredInterfaceType = .loopback
        return parameters
    }

    static func isLoopback(endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }

        switch host {
        case .ipv4(let address):
            return address == .loopback
        case .ipv6(let address):
            return address == .loopback
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    static func allowsRequest(headers: [String: String], port: UInt16) -> Bool {
        guard headers["origin"] == nil,
              let host = headers["host"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return false }

        return allowedHosts(port: port).contains(host)
    }

    private static func allowedHosts(port: UInt16) -> Set<String> {
        [
            "localhost:\(port)",
            "127.0.0.1:\(port)",
            "[::1]:\(port)"
        ]
    }
}
