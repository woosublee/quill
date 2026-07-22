import Darwin
import Foundation

@main
struct LocalAIServerProcessTests {
    static func main() throws {
        try testReservedPortIsWithinEphemeralRange()
        try testReservedPortCanBeRebound()
        try testRealProcessBuildsExpectedArguments()
        try testLateTerminationHandlerRunsExactlyOnceAfterFakeExits()
        try testRealProcessInitThrowsWhenRunnerMissing()
        print("LocalAIServerProcessTests passed")
    }

    private static func testReservedPortIsWithinEphemeralRange() throws {
        let port = try reserveEphemeralLoopbackPort()
        assert(port >= 1024)
    }

    private static func testReservedPortCanBeRebound() throws {
        for _ in 0..<10 {
            let port = try reserveEphemeralLoopbackPort()
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(socketFD) }
            guard socketFD >= 0 else { throw TestFailure("could not create test socket") }
            var reuse: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult == 0 { return }
        }
        throw TestFailure("could not rebind any reserved loopback port")
    }

    private static func testRealProcessBuildsExpectedArguments() throws {
        let runnerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runnerDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runnerDirectory) }
        let runnerURL = runnerDirectory.appendingPathComponent("fake-llama-server")
        try "#!/bin/sh\nexit 0\n".write(to: runnerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnerURL.path)
        let modelURL = runnerDirectory.appendingPathComponent("model.gguf")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data([1]))

        let process = try RealLocalAIServerProcess(
            runnerURL: runnerURL,
            modelURL: modelURL,
            port: 51_234,
            contextSize: 4096
        )
        let arguments = process.launchArguments

        assert(arguments.contains("--host"))
        assert(arguments[arguments.firstIndex(of: "--host")! + 1] == "127.0.0.1")
        assert(arguments.contains("--port"))
        assert(arguments[arguments.firstIndex(of: "--port")! + 1] == "51234")
        assert(arguments.contains("--model"))
        assert(arguments[arguments.firstIndex(of: "--model")! + 1] == modelURL.path)
        assert(arguments.contains("--ctx-size"))
        assert(arguments[arguments.firstIndex(of: "--ctx-size")! + 1] == "4096")
        try waitForProcessExit(process)
    }

    private static func testLateTerminationHandlerRunsExactlyOnceAfterFakeExits() throws {
        let runnerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runnerDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runnerDirectory) }
        let runnerURL = runnerDirectory.appendingPathComponent("fake-llama-server")
        try "#!/bin/sh\nexit 0\n".write(to: runnerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnerURL.path)
        let modelURL = runnerDirectory.appendingPathComponent("model.gguf")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data([1]))

        let process = try RealLocalAIServerProcess(runnerURL: runnerURL, modelURL: modelURL, port: 51_236, contextSize: 4096)
        try waitForProcessExit(process)

        let callback = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var callbackCount = 0
        process.setTerminationHandler {
            lock.lock()
            callbackCount += 1
            lock.unlock()
            callback.signal()
        }
        guard callback.wait(timeout: .now() + 1) == .success else {
            throw TestFailure("late termination handler was not called")
        }
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock()
        let finalCallbackCount = callbackCount
        lock.unlock()
        assert(finalCallbackCount == 1)
    }

    private static func waitForProcessExit(_ process: RealLocalAIServerProcess) throws {
        for _ in 0..<100 where process.isRunning {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else {
            process.terminate()
            throw TestFailure("fake llama-server did not exit")
        }
    }

    private static func testRealProcessInitThrowsWhenRunnerMissing() throws {
        let missingRunner = URL(fileURLWithPath: "/__missing_llama_server__")
        let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("model.gguf")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data([1]))
        defer { try? FileManager.default.removeItem(at: modelURL) }

        do {
            _ = try RealLocalAIServerProcess(runnerURL: missingRunner, modelURL: modelURL, port: 51_235, contextSize: 4096)
            assertionFailure("Expected init to throw for a missing runner")
        } catch is LocalAIServerProcessError {
            // expected
        }
    }
}

private struct TestFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
