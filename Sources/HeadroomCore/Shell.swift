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
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        // Read while waiting so a chatty tool can't fill the pipe and stall.
        var data = Data()
        let handle = out.fileHandleForReading
        while process.isRunning {
            data.append(handle.availableData)
            if Date() > deadline { process.terminate(); return nil }
        }
        data.append(handle.readDataToEndOfFile())
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
