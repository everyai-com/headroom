import Foundation

/// Minimal process runner for the few developer tools Headroom calls.
public enum Shell {
    /// GUI apps launch with a bare PATH; developer tools live in these places.
    static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                             NSHomeDirectory() + "/Library/pnpm", NSHomeDirectory() + "/.bun/bin",
                             NSHomeDirectory() + "/.npm-global/bin", NSHomeDirectory() + "/.cargo/bin"]

    public static func which(_ tool: String) -> String? {
        for dir in searchPath {
            let path = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Run and return stdout, or nil on failure. Bounded by `timeout` seconds.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        // Never read: a pipe nobody drains fills up and stalls a chatty tool.
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        // Read on another thread so a silent, hung tool can't block the timeout.
        let collected = Collected()
        let reader = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collected.data = out.fileHandleForReading.readDataToEndOfFile()
            reader.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        // A child the tool left behind can keep the pipe open; don't wait on it forever.
        guard reader.wait(timeout: .now() + 5) == .success, process.terminationStatus == 0 else { return nil }
        return String(data: collected.data, encoding: .utf8)
    }

    private final class Collected: @unchecked Sendable {
        var data = Data()
    }
}
