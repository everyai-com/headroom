import Foundation

/// Folders macOS guards with a permission prompt (Desktop, Documents, Downloads, other apps' data, Mail,
/// Messages…). Reading one before you've answered blocks the reading thread until you do — and with nobody at
/// the Mac (a login item, a locked screen), that is forever, so a whole scan would hang on it.
///
/// `Access.readable` looks first on a thread of its own and gives up after a few seconds: a folder still
/// waiting on its prompt is skipped this time (and named, so the app can say so) and checked again next scan.
/// Only one look per folder is ever waiting; it finishes by itself once the prompt is answered.
public enum Access {
    /// The folders that can prompt, under home. Anything else is never probed.
    static let guarded = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
                          "Library/Mobile Documents", "Library/Containers", "Library/Group Containers",
                          "Library/Mail", "Library/Messages", "Library/Safari", "Library/Calendars",
                          "Library/Reminders", "Library/Application Support/AddressBook", "Library/CloudStorage"]

    private static let lock = NSLock()
    /// Folders whose look is still blocked on a prompt.
    nonisolated(unsafe) private static var pending: Set<String> = []
    /// Folders known to open (no need to look again this run).
    nonisolated(unsafe) private static var open: Set<String> = []

    /// The guarded folder `url` is in, or nil when it's in none.
    static func guardedFolder(of url: URL, home: String) -> String? {
        let path = url.standardizedFileURL.path
        for g in guarded {
            let root = home + "/" + g
            if path == root || path.hasPrefix(root + "/") {
                // Other apps' data prompts per app: look at the app's own folder, not the whole Containers.
                if g == "Library/Containers" || g == "Library/Group Containers" {
                    let rest = path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init)
                    return rest.map { root + "/" + $0 } ?? root
                }
                return root
            }
        }
        return nil
    }

    /// Whether `url` can be read now without waiting on a permission prompt. Never blocks longer than `timeout`.
    public static func readable(_ url: URL, home: String = HeadroomPaths.home, timeout: TimeInterval = 4) -> Bool {
        guard let folder = guardedFolder(of: url, home: home) else { return true }
        lock.lock()
        if open.contains(folder) { lock.unlock(); return true }
        if pending.contains(folder) { lock.unlock(); return false }
        pending.insert(folder)
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = try? FileManager.default.contentsOfDirectory(atPath: folder)
            lock.lock(); pending.remove(folder); open.insert(folder); lock.unlock()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// The ones of `urls` that can be read now (looked at in parallel).
    public static func readable(_ urls: [URL], home: String = HeadroomPaths.home, timeout: TimeInterval = 4) -> [URL] {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var ok: Set<Int> = []
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            if readable(urls[i], home: home, timeout: timeout) { results.lock.lock(); results.ok.insert(i); results.lock.unlock() }
        }
        return urls.indices.filter { results.ok.contains($0) }.map { urls[$0] }
    }

    /// Guarded folders still waiting on a prompt, for the app to name ("Desktop", "WhatsApp's data").
    public static var waiting: [String] {
        lock.lock(); defer { lock.unlock() }
        return pending.sorted()
    }

    /// Forget what's known (tests).
    static func reset() {
        lock.lock(); open = []; lock.unlock()
    }
}
