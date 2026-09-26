import Darwin
import Foundation

enum LocalAIServerProcessError: LocalizedError, Equatable {
    case runnerNotFound(String)
    case modelNotFound(String)
    case portReservationFailed(String)
    case projectorNotFound(String)

    var errorDescription: String? {
        switch self {
        case .runnerNotFound:
            return "Local AI runtime is not available in this app build."
        case .modelNotFound:
            return "Local AI model is not installed yet."
        case .portReservationFailed:
            return "Could not reserve a local network port for the local AI runtime."
        case .projectorNotFound:
            return "The local AI vision projector artifact is unavailable."
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
    func recentDiagnostics() -> LocalAIDiagnostics
    func terminate()
    func forceTerminate()
    func setTerminationHandler(_ handler: @escaping () -> Void)
}

extension LocalAIServerProcess {
    func recentDiagnostics() -> LocalAIDiagnostics {
        LocalAIDiagnostics(category: .none, trailingLines: [])
    }
}

final class RealLocalAIServerProcess: LocalAIServerProcess {
    private let process: Process
    private let terminationRelay: TerminationRelay
    private let diagnostics: LocalAIDiagnosticsBuffer
    let launchArguments: [String]

    init(
        runnerURL: URL,
        model: LocalAIModel,
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

        var arguments = [
            "--host", "127.0.0.1",
            "--port", String(port),
            "--model", modelURL.path,
            "--ctx-size", String(contextSize),
            // One slot keeps the whole context for each request; newer
            // llama.cpp otherwise picks several slots and a RAM prompt cache
            // of up to 8 GiB on top of the model.
            "--parallel", "1",
            "--cache-ram", "0",
            "--no-webui"
        ]
        switch model.runtime {
        case .textChat:
            break
        case let .visionChat(projectorArtifactFileName):
            guard model.artifacts.contains(where: {
                $0.expectedFileName == projectorArtifactFileName
            }) else {
                throw LocalAIServerProcessError.projectorNotFound(projectorArtifactFileName)
            }
            let projectorURL = modelURL
                .deletingLastPathComponent()
                .appendingPathComponent(projectorArtifactFileName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: projectorURL.path) else {
                throw LocalAIServerProcessError.projectorNotFound(projectorArtifactFileName)
            }
            arguments.append(contentsOf: ["--mmproj", projectorURL.path])
        }
        arguments.append(contentsOf: model.serverArguments)
        self.launchArguments = arguments

        let diagnostics = LocalAIDiagnosticsBuffer()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let process = Process()
        process.executableURL = runnerURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path
        ]
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            diagnostics.append(handle.availableData, from: .standardOutput)
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            diagnostics.append(handle.availableData, from: .standardError)
        }
        let terminationRelay = TerminationRelay()
        process.terminationHandler = { _ in
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            diagnostics.append(
                standardOutput.fileHandleForReading.readDataToEndOfFile(),
                from: .standardOutput
            )
            diagnostics.append(
                standardError.fileHandleForReading.readDataToEndOfFile(),
                from: .standardError
            )
            diagnostics.finish()
            terminationRelay.signal()
        }
        self.process = process
        self.terminationRelay = terminationRelay
        self.diagnostics = diagnostics
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func recentDiagnostics() -> LocalAIDiagnostics {
        diagnostics.snapshot()
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func forceTerminate() {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func setTerminationHandler(_ handler: @escaping () -> Void) {
        terminationRelay.register(handler)
    }

    static func defaultRunnerURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "llama-server", withExtension: nil, subdirectory: "llama")
    }
}

private final class TerminationRelay {
    private let lock = NSLock()
    private var hasTerminated = false
    private var handler: (() -> Void)?

    func signal() {
        let callback: (() -> Void)?
        lock.lock()
        if hasTerminated {
            callback = nil
        } else {
            hasTerminated = true
            callback = handler
            handler = nil
        }
        lock.unlock()
        callback?()
    }

    func register(_ handler: @escaping () -> Void) {
        let callback: (() -> Void)?
        lock.lock()
        if hasTerminated {
            callback = handler
        } else {
            self.handler = handler
            callback = nil
        }
        lock.unlock()
        callback?()
    }
}
