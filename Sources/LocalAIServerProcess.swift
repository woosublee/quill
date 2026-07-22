import Darwin
import Foundation

enum LocalAIServerProcessError: LocalizedError, Equatable {
    case runnerNotFound(String)
    case modelNotFound(String)
    case portReservationFailed(String)

    var errorDescription: String? {
        switch self {
        case .runnerNotFound:
            return "Local AI runtime is not available in this app build."
        case .modelNotFound:
            return "Local AI model is not installed yet."
        case .portReservationFailed:
            return "Could not reserve a local network port for the local AI runtime."
        }
    }
}

/// Reserves a free TCP port on the loopback interface by binding to port 0 and
/// immediately reading back the OS-assigned port, then closing the socket so
/// the caller can bind it again. A separate process can claim the port in the
/// narrow interval before the caller binds it.
func reserveEphemeralLoopbackPort() throws -> UInt16 {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
        throw LocalAIServerProcessError.portReservationFailed("socket() failed")
    }
    defer { close(socketFD) }

    var reuse: Int32 = 1
    setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw LocalAIServerProcessError.portReservationFailed("bind() failed")
    }

    var boundAddress = sockaddr_in()
    var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let getNameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            getsockname(socketFD, sockaddrPointer, &boundAddressLength)
        }
    }
    guard getNameResult == 0 else {
        throw LocalAIServerProcessError.portReservationFailed("getsockname() failed")
    }

    return boundAddress.sin_port.bigEndian
}

protocol LocalAIServerProcess: AnyObject {
    var isRunning: Bool { get }
    func terminate()
    func setTerminationHandler(_ handler: @escaping () -> Void)
}

final class RealLocalAIServerProcess: LocalAIServerProcess {
    private let process: Process
    let launchArguments: [String]

    init(
        runnerURL: URL,
        modelURL: URL,
        port: UInt16,
        contextSize: Int
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: runnerURL.path) else {
            throw LocalAIServerProcessError.runnerNotFound(runnerURL.path)
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalAIServerProcessError.modelNotFound(modelURL.path)
        }

        let arguments = [
            "--host", "127.0.0.1",
            "--port", String(port),
            "--model", modelURL.path,
            "--ctx-size", String(contextSize),
            "--no-webui"
        ]
        self.launchArguments = arguments

        let process = Process()
        process.executableURL = runnerURL
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path
        ]
        self.process = process
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func setTerminationHandler(_ handler: @escaping () -> Void) {
        process.terminationHandler = { _ in handler() }
    }

    static func defaultRunnerURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "llama-server", withExtension: nil, subdirectory: "llama")
    }
}
