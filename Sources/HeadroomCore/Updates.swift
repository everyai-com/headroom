import Foundation

/// Release check: the app reads a small JSON feed (`update.json`, written by scripts/release.sh)
/// and tells you when a newer version exists. It never downloads or installs on its own —
/// "Get the update" opens the notarized download in your browser.
public enum Updates {
    public struct Release: Codable, Sendable, Equatable {
        public var version: String
        /// The download page or the notarized .zip.
        public var url: URL
        public var notes: String?
        public var minimumSystem: String?

        public init(version: String, url: URL, notes: String? = nil, minimumSystem: String? = nil) {
            self.version = version
            self.url = url
            self.notes = notes
            self.minimumSystem = minimumSystem
        }
    }

    /// "0.10.0" > "0.9.3"; a leading "v" and a "-beta" style suffix are ignored.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: "-").first
                .map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        var a = parts(remote), b = parts(local)
        let n = max(a.count, b.count)
        a += Array(repeating: 0, count: n - a.count)
        b += Array(repeating: 0, count: n - b.count)
        return a.lexicographicallyPrecedes(b) == false && a != b
    }

    /// The feed baked into the app at build time (Info.plist `HeadroomUpdateFeed`); nil = updates off.
    public static var feedURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "HeadroomUpdateFeed") as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The newer release, if there is one this Mac can run.
    public static func check(feed: URL, current: String = currentVersion) async throws -> Release? {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Headroom/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard isNewer(release.version, than: current) else { return nil }
        if let min = release.minimumSystem {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            if isNewer(min, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") { return nil }
        }
        return release
    }
}
