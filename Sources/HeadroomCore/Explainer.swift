import Foundation

/// What a file or folder is, what it's for, and what happens if you delete it — in plain words,
/// so you can decide from the map without opening Finder.
public struct Explanation: Sendable, Equatable {
    /// "Slack's cache", "Node.js packages", "A video".
    public var what: String
    /// What it holds and who uses it.
    public var detail: String
    /// What deleting it means.
    public var ifDeleted: String
    /// How safe deleting it is: safe = comes back on its own, review = think first, keep = your data.
    public var verdict: Safety
    /// The app it belongs to, when Headroom can tell.
    public var ownerBundleID: String?
    /// True when nothing matched and this is a generic description.
    public var isGuess = false

    public init(what: String, detail: String, ifDeleted: String, verdict: Safety, ownerBundleID: String? = nil, isGuess: Bool = false) {
        self.what = what
        self.detail = detail
        self.ifDeleted = ifDeleted
        self.verdict = verdict
        self.ownerBundleID = ownerBundleID
        self.isGuess = isGuess
    }
}

public enum Explainer {
    /// Explain `url`. `appName` turns a bundle ID into an app's name ("com.tinyspeck.slackmacgap" → "Slack").
    public static func explain(_ url: URL, home: URL = URL(fileURLWithPath: HeadroomPaths.home),
                               appName: (String) -> String? = { _ in nil }) -> Explanation {
        let path = url.standardizedFileURL.path
        let h = home.standardizedFileURL.path
        let name = url.lastPathComponent
        let lower = name.lowercased()
        let ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)

        func owner(_ entry: String) -> (id: String, name: String)? {
            let stem = entry.replacingOccurrences(of: ".plist", with: "").replacingOccurrences(of: ".savedState", with: "")
            // Try the full ID, then shorter ones: com.vendor.app.ShipIt → com.vendor.app.
            var parts = stem.split(separator: ".").map(String.init)
            while parts.count >= 2 {
                let id = parts.joined(separator: ".")
                if let n = appName(id) { return (id, n) }
                parts.removeLast()
            }
            return nil
        }
        func appLabel(_ entry: String) -> String { owner(entry).map { $0.name } ?? entry }

        // Apps first: deleting part of an app breaks it.
        if ext == "app" {
            let display = url.deletingPathExtension().lastPathComponent
            return Explanation(what: "The \(display) app",
                               detail: "The program itself. Its settings, caches and data live separately in your Library.",
                               ifDeleted: "Use Uninstall: it removes the app together with all its data, caches and settings — recoverable from the Trash.",
                               verdict: .review, ownerBundleID: Bundle(url: url)?.bundleIdentifier)
        }

        // Your Library: matched by place, named after the app that owns it.
        let library = h + "/Library/"
        if path.hasPrefix(library) {
            let rest = String(path.dropFirst(library.count))
            let parts = rest.split(separator: "/").map(String.init)
            if parts.count >= 2 {
                let place = parts[0], entry = parts[1]
                let who = owner(entry)
                let app = who?.name ?? entry
                let deep = parts.count > 2
                switch place {
                case "Caches":
                    return Explanation(what: deep ? "Part of \(app)'s cache" : "\(app)'s cache",
                                       detail: "Temporary copies \(who == nil ? "an app" : app) keeps so it loads faster — downloaded images, compiled code, update files.",
                                       ifDeleted: "\(who == nil ? "The app" : app) rebuilds it as needed. Nothing personal is lost; quit the app first for the best result.",
                                       verdict: .safe, ownerBundleID: who?.id)
                case "Application Support":
                    return Explanation(what: deep ? "Part of \(app)'s data" : "\(app)'s data",
                                       detail: "Where \(who == nil ? "an app" : app) keeps its working data: accounts, local databases, downloaded models, offline files, plugins.",
                                       ifDeleted: "\(who == nil ? "The app" : app) starts as if newly installed — you may lose sign-ins, local history or files it stored only here. To remove an app completely, uninstall it instead.",
                                       verdict: .keep, ownerBundleID: who?.id)
                case "Containers":
                    return Explanation(what: "\(app)'s sandbox",
                                       detail: "Everything a sandboxed app (usually from the App Store) stores: documents, settings, caches — all in one place.",
                                       ifDeleted: "\(who == nil ? "The app" : app) loses all its data and settings. Uninstall the app instead to remove it cleanly.",
                                       verdict: .keep, ownerBundleID: who?.id)
                case "Group Containers":
                    let shared = owner(entry.split(separator: ".").dropFirst().joined(separator: "."))?.name ?? app
                    return Explanation(what: "\(shared)'s shared data",
                                       detail: "Data shared between an app and its widgets, extensions or sibling apps — often chats, media and databases (WhatsApp keeps its media here).",
                                       ifDeleted: "The app and its extensions lose that data. Clear it from inside the app, or uninstall the app.",
                                       verdict: .keep, ownerBundleID: who?.id)
                case "Preferences":
                    return Explanation(what: "\(app)'s settings",
                                       detail: "A small file with the app's preferences and window positions.",
                                       ifDeleted: "The app goes back to its default settings. Tiny — rarely worth it for space.",
                                       verdict: .review, ownerBundleID: who?.id)
                case "Logs":
                    return Explanation(what: "\(app)'s logs", detail: "Diagnostic records the app writes as it runs.",
                                       ifDeleted: "Nothing changes for you; the app starts new logs.", verdict: .safe, ownerBundleID: who?.id)
                case "Saved Application State":
                    return Explanation(what: "\(app)'s saved windows", detail: "What windows were open, so the app can restore them.",
                                       ifDeleted: "The app opens fresh, without restoring windows.", verdict: .safe, ownerBundleID: who?.id)
                case "HTTPStorages", "WebKit", "Cookies":
                    return Explanation(what: "\(app)'s web data", detail: "Cookies and web storage from pages the app shows.",
                                       ifDeleted: "You may be signed out of things inside the app.", verdict: .review, ownerBundleID: who?.id)
                case "Mail", "Messages", "Mobile Documents", "Keychains", "Photos":
                    return protected(name)
                default: break
                }
            }
        }

        // Well-known folders by name.
        if isDir.boolValue {
            if let e = folders[lower] { return e }
            if path.hasPrefix(h + "/Library/Developer/Xcode/DerivedData") {
                return Explanation(what: "Xcode build files", detail: "Intermediate build output and indexes for your Xcode projects.",
                                   ifDeleted: "Rebuilt the next time you build. Safe.", verdict: .safe)
            }
            if path.hasPrefix(h + "/Library/Developer/CoreSimulator/Devices") {
                return Explanation(what: "iOS Simulator devices", detail: "Each simulator's installed apps and data.",
                                   ifDeleted: "Those simulators are reset or removed. Prefer Xcode → Devices and Simulators.", verdict: .review)
            }
            if path.contains("/.cache/huggingface") {
                return Explanation(what: "Downloaded AI models (Hugging Face)", detail: "Model weights downloaded by Python tools, MLX, Whisper and similar.",
                                   ifDeleted: "They download again the next time a tool needs them — can be many GB.", verdict: .review)
            }
            if path.hasPrefix(h + "/.claude/projects") {
                return Explanation(what: "Claude Code conversation history", detail: "Transcripts of past Claude Code sessions, one folder per project.",
                                   ifDeleted: "You lose the ability to resume or search those sessions. Your code is untouched.", verdict: .review)
            }
            if path.hasPrefix(h + "/.codex/sessions") {
                return Explanation(what: "Codex session history", detail: "Transcripts of past Codex sessions.",
                                   ifDeleted: "Past sessions can't be resumed. Your code is untouched.", verdict: .review)
            }
            if lower.hasSuffix(".photoslibrary") { return protected(name) }
            if FileManager.default.fileExists(atPath: path + "/.git") {
                return Explanation(what: "A code project (git repository)", detail: "Source code with its history. Build output inside it (node_modules, .next, target…) is safe to remove; the project itself is your work.",
                                   ifDeleted: "Your code and its history are gone unless it's pushed somewhere. Look inside and remove just the build folders.",
                                   verdict: .keep)
            }
        }

        // Files by kind.
        if !isDir.boolValue, let e = fileKinds(ext: ext, name: lower, path: path, home: h) { return e }

        // Top-level home folders.
        if url.deletingLastPathComponent().standardizedFileURL.path == h, let e = homeFolders[name] { return e }

        return Explanation(what: isDir.boolValue ? "A folder" : (ext.isEmpty ? "A file" : "A .\(ext) file"),
                           detail: "Headroom doesn't recognise this one. Look inside or open it before deciding.",
                           ifDeleted: "Move it to the Trash rather than deleting permanently, so you can put it back if something needed it.",
                           verdict: .review, isGuess: true)
    }

    static func protected(_ name: String) -> Explanation {
        Explanation(what: name, detail: "Managed by macOS or a core app (Mail, Messages, iCloud, Photos, passwords).",
                    ifDeleted: "Headroom never deletes this. Manage it from the app that owns it.", verdict: .keep)
    }

    static let folders: [String: Explanation] = {
        func regen(_ what: String, _ detail: String, _ rebuild: String) -> Explanation {
            Explanation(what: what, detail: detail, ifDeleted: "Comes back with `\(rebuild)` when you next work on it.", verdict: .safe)
        }
        return [
            "node_modules": regen("JavaScript packages", "Libraries a Node.js project downloaded.", "npm install / pnpm install"),
            ".next": regen("Next.js build output", "Compiled pages and build cache.", "next build / next dev"),
            ".nuxt": regen("Nuxt build output", "Compiled app and cache.", "nuxt dev"),
            ".turbo": regen("Turborepo cache", "Cached task outputs.", "turbo run"),
            ".parcel-cache": regen("Parcel cache", "Bundler cache.", "parcel"),
            ".svelte-kit": regen("SvelteKit build output", "Generated files.", "vite dev"),
            "dist": regen("Build output", "Files a build step produced.", "your build command"),
            "target": regen("Rust / Java build output", "Compiled binaries and intermediates.", "cargo build / mvn package"),
            ".build": regen("Swift build output", "Compiled Swift packages.", "swift build"),
            "__pycache__": regen("Python bytecode", "Compiled .pyc files.", "running the code"),
            ".venv": Explanation(what: "Python virtual environment", detail: "This project's installed Python packages.",
                                 ifDeleted: "Recreate it with `python -m venv .venv` and reinstall packages (uv sync / pip install).", verdict: .review),
            "venv": Explanation(what: "Python virtual environment", detail: "This project's installed Python packages.",
                                ifDeleted: "Recreate it and reinstall packages.", verdict: .review),
            "pods": regen("CocoaPods dependencies", "iOS libraries.", "pod install"),
            ".gradle": regen("Gradle cache", "Android/Java build cache.", "gradle build"),
            ".npm": regen("npm cache", "Every package npm ever downloaded.", "npm install"),
            ".pnpm-store": regen("pnpm store", "Shared packages for all pnpm projects.", "pnpm install"),
            ".yarn": regen("Yarn cache", "Downloaded packages.", "yarn install"),
            ".bun": regen("Bun install cache", "Downloaded packages and Bun itself.", "bun install"),
            ".cache": Explanation(what: "Tool caches", detail: "Downloads and caches many command-line tools share (pip, Hugging Face, puppeteer…).",
                                  ifDeleted: "Tools re-download what they need. Look inside: AI models here can be large and slow to fetch again.", verdict: .review),
            ".cargo": Explanation(what: "Rust toolchain & crates", detail: "Cargo's downloaded crates and installed tools.",
                                  ifDeleted: "Crates re-download on the next build; tools you installed with cargo are gone.", verdict: .review),
            ".rustup": Explanation(what: "Rust toolchains", detail: "Installed Rust compilers.",
                                   ifDeleted: "Rust stops working until you reinstall with rustup.", verdict: .review),
            ".ollama": Explanation(what: "Ollama models", detail: "Local AI models downloaded with Ollama.",
                                   ifDeleted: "Run `ollama rm <model>` instead to pick which go; deleted models download again on use.", verdict: .review),
            ".docker": Explanation(what: "Docker settings & data", detail: "Docker's configuration and, for some setups, its disk.",
                                   ifDeleted: "Use `docker system prune` instead — deleting this can wipe every image and container.", verdict: .keep),
            ".colima": Explanation(what: "Colima virtual machine", detail: "The Linux VM that runs your containers.",
                                   ifDeleted: "Every container and image is gone. Clean it with `docker system prune`.", verdict: .keep),
            ".orbstack": Explanation(what: "OrbStack virtual machine", detail: "The Linux VM that runs your containers.",
                                     ifDeleted: "Every container and image is gone. Clean it from OrbStack.", verdict: .keep),
            ".git": Explanation(what: "Git history", detail: "Every past version of this project.",
                                ifDeleted: "Headroom never deletes this — use git (gc, shallow clone) to slim a repo.", verdict: .keep),
            ".trash": Explanation(what: "Your Trash", detail: "Things you deleted that can still be put back.",
                                  ifDeleted: "Empty it from Finder, or delete Headroom's own items for good from Activity.", verdict: .review),
            "deriveddata": Explanation(what: "Xcode build files", detail: "Intermediate build output and indexes.",
                                       ifDeleted: "Rebuilt the next time you build.", verdict: .safe),
            "ios devicesupport": Explanation(what: "iPhone debugging symbols", detail: "Copied from each iOS version you connected for debugging.",
                                             ifDeleted: "Copied again next time you plug that device in. Safe.", verdict: .safe),
            "archives": Explanation(what: "Xcode archives", detail: "Builds you archived for the App Store or TestFlight.",
                                    ifDeleted: "You can't symbolicate crash reports for those builds any more. Keep recent ones.", verdict: .review),
            "backup": Explanation(what: "Backups", detail: "Backups — for MobileSync, these are iPhone and iPad backups.",
                                  ifDeleted: "Manage device backups in Finder → your device → Manage Backups.", verdict: .keep),
        ]
    }()

    static let homeFolders: [String: Explanation] = {
        func yours(_ what: String, _ detail: String) -> Explanation {
            Explanation(what: what, detail: detail, ifDeleted: "Never delete the folder itself — look inside and remove what you no longer need.", verdict: .keep)
        }
        return [
            "Desktop": yours("Your Desktop", "Everything on your desktop, often projects and screenshots."),
            "Documents": yours("Your Documents", "Your files and, often, code projects."),
            "Downloads": Explanation(what: "Your Downloads", detail: "Everything you downloaded — installers and zips are usually safe to remove once used.",
                                     ifDeleted: "Look inside: sort by size and trash old installers (.dmg, .pkg) and archives.", verdict: .review),
            "Movies": yours("Your Movies", "Videos and screen recordings."),
            "Pictures": yours("Your Pictures", "Photos and images, including the Photos library."),
            "Music": yours("Your Music", "Music and audio files."),
            "Library": Explanation(what: "Your Library", detail: "Where apps keep their settings, caches and data.",
                                   ifDeleted: "Never delete the folder. Caches inside are safe; uninstall apps to remove their data.", verdict: .keep),
            "Applications": yours("Your own Applications folder", "Apps installed just for you."),
        ]
    }()

    static func fileKinds(ext: String, name: String, path: String, home: String) -> Explanation? {
        switch ext {
        case "dmg", "pkg", "mpkg", "xip":
            return Explanation(what: "An installer", detail: "A disk image or package you downloaded to install something.",
                               ifDeleted: "Once the app is installed, you don't need this. Safe to remove.", verdict: .safe)
        case "iso", "img":
            return Explanation(what: "A disk image", detail: "A copy of a whole disk — an OS installer or a backup.",
                               ifDeleted: "Gone unless you can download it again.", verdict: .review)
        case "zip", "tar", "gz", "tgz", "7z", "rar", "xz", "bz2":
            return Explanation(what: "An archive", detail: "Compressed files — often something already unpacked elsewhere.",
                               ifDeleted: "If you've unpacked it (or can re-download it), safe to remove.", verdict: .review)
        case "mov", "mp4", "m4v", "mkv", "avi", "webm":
            return Explanation(what: "A video", detail: "A video or screen recording.",
                               ifDeleted: "Gone for good once the Trash is emptied — keep a copy elsewhere if it matters.", verdict: .keep)
        case "gguf", "safetensors", "pt", "pth", "onnx", "ckpt", "mlmodel":
            return Explanation(what: "An AI model", detail: "Model weights used by a local AI tool.",
                               ifDeleted: "The tool downloads it again when it next needs it.", verdict: .review)
        case "bin" where path.contains("whisper") || path.contains("model") || path.contains("huggingface"):
            return Explanation(what: "An AI model", detail: "Model weights (e.g. Whisper speech recognition).",
                               ifDeleted: "The tool downloads it again when it next needs it.", verdict: .review)
        case "log":
            return Explanation(what: "A log file", detail: "Text a program wrote while running — often grows forever when something keeps failing.",
                               ifDeleted: "Nothing breaks; the program starts a new log.", verdict: .safe)
        case "jsonl" where path.contains("/.claude/") || path.contains("/.codex/"):
            return Explanation(what: "An AI agent session transcript", detail: "The full record of one coding-agent conversation.",
                               ifDeleted: "That session can't be resumed or searched. Your code is untouched.", verdict: .review)
        case "sqlite", "db", "sqlite3", "realm":
            return Explanation(what: "A database", detail: "Data an app stores — history, messages, indexes.",
                               ifDeleted: "The app that owns it may lose data or break. Clear it from the app instead.", verdict: .keep)
        case "vmdk", "vdi", "qcow2", "raw", "hdd", "utm":
            return Explanation(what: "A virtual machine disk", detail: "Everything inside a VM or container runtime.",
                               ifDeleted: "The whole virtual machine is gone. Remove it from the VM app instead.", verdict: .keep)
        case "ipa":
            return Explanation(what: "An iOS app package", detail: "A built iPhone app.", ifDeleted: "Rebuild or re-download it if needed.", verdict: .safe)
        case "wav", "aif", "aiff", "flac", "mp3", "m4a":
            return Explanation(what: "An audio file", detail: "Music or a recording.", ifDeleted: "Gone once the Trash is emptied.", verdict: .keep)
        case "psd", "sketch", "fig", "key", "pages", "numbers", "pdf", "docx", "xlsx", "pptx":
            return Explanation(what: "A document", detail: "Something you or someone else made.", ifDeleted: "Gone once the Trash is emptied.", verdict: .keep)
        default:
            return nil
        }
    }
}
