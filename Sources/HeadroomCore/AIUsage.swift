import Foundation

/// What your AI tools hold on disk (models, caches, history), what of them is running, and which
/// local servers they have open. Removal goes through `Cleaner` like everything else: models are
/// `.review` and go to the Trash (or the tool's own `ollama rm`), caches are `.safe`, history is `.keep`.
public struct AITool: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var symbol: String
    public var items: [Finding]
    public var processes: [ProcessInfoSnapshot]
    public var servers: [AIServer]
    public var bytes: Int64 { items.reduce(0) { $0 + $1.size.allocated } }
    public var isRunning: Bool { !processes.isEmpty }
}

/// A local server listening on a TCP port.
public struct AIServer: Sendable, Hashable, Identifiable {
    public var id: String { "\(pid):\(port)" }
    public var pid: Int32
    public var process: String
    public var port: Int
    /// Bound to every interface (reachable from your network), not just this Mac.
    public var exposed: Bool
}

public enum AIUsage {
    struct Tool {
        var id: String, name: String, symbol: String
        /// Process names (exact) or executable path fragments that mean this tool is running.
        var processNames: [String] = []
        var pathFragments: [String] = []
        var ports: [Int] = []
        /// Folders measured as one item each: (home-relative path, title, role).
        var folders: [(String, String, Role)] = []
    }

    enum Role { case cache, history, appData }

    static let tools: [Tool] = [
        Tool(id: "ollama", name: "Ollama", symbol: "cube.fill", processNames: ["ollama", "Ollama"], pathFragments: ["/Ollama.app/"],
             ports: [11434]),
        Tool(id: "lmstudio", name: "LM Studio", symbol: "cpu.fill", processNames: ["LM Studio", "lms"], pathFragments: ["/LM Studio.app/"],
             ports: [1234], folders: [("Library/Application Support/LM Studio/Cache", "LM Studio cache", .cache)]),
        Tool(id: "huggingface", name: "Hugging Face", symbol: "face.smiling.inverse",
             folders: [(".cache/huggingface/xet", "Download cache", .cache)]),
        Tool(id: "claude", name: "Claude", symbol: "sparkles", processNames: ["claude", "Claude"], pathFragments: ["/Claude.app/"],
             folders: [(".claude/projects", "Claude Code session history", .history),
                       ("Library/Application Support/Claude/Cache", "Claude app cache", .cache),
                       ("Library/Application Support/Claude/Code Cache", "Claude app code cache", .cache),
                       ("Library/Application Support/Claude/GPUCache", "Claude app GPU cache", .cache),
                       ("Library/Application Support/Claude/claude-code-vm", "Claude Code sandbox VM", .appData),
                       ("Library/Application Support/Claude/claude-code", "Claude Code (bundled)", .appData)]),
        Tool(id: "codex", name: "Codex", symbol: "terminal.fill", processNames: ["codex"], pathFragments: ["/Codex.app/"],
             folders: [(".codex/sessions", "Codex session history", .history)]),
        Tool(id: "chatgpt", name: "ChatGPT", symbol: "bubble.left.fill", processNames: ["ChatGPT"], pathFragments: ["/ChatGPT.app/"],
             folders: [("Library/Caches/com.openai.chat", "ChatGPT cache", .cache),
                       ("Library/Application Support/com.openai.chat", "ChatGPT app data", .appData)]),
        Tool(id: "cursor", name: "Cursor", symbol: "cursorarrow.rays", processNames: ["Cursor"], pathFragments: ["/Cursor.app/"],
             folders: [("Library/Application Support/Cursor/Cache", "Cursor cache", .cache),
                       ("Library/Application Support/Cursor/CachedData", "Cursor cached data", .cache),
                       ("Library/Application Support/Cursor/Code Cache", "Cursor code cache", .cache),
                       ("Library/Application Support/Cursor/GPUCache", "Cursor GPU cache", .cache),
                       ("Library/Application Support/Cursor/User/workspaceStorage", "Cursor workspace history", .history)]),
        Tool(id: "windsurf", name: "Windsurf", symbol: "wind", processNames: ["Windsurf"], pathFragments: ["/Windsurf.app/"],
             folders: [("Library/Application Support/Windsurf/Cache", "Windsurf cache", .cache),
                       ("Library/Application Support/Windsurf/CachedData", "Windsurf cached data", .cache),
                       (".codeium", "Codeium data", .appData)]),
        Tool(id: "gpt4all", name: "GPT4All", symbol: "brain", processNames: ["GPT4All", "chat"], pathFragments: ["/GPT4All.app/", "/gpt4all/"],
             ports: [4891]),
        Tool(id: "jan", name: "Jan", symbol: "circle.hexagongrid.fill", processNames: ["Jan"], pathFragments: ["/Jan.app/"], ports: [1337]),
        Tool(id: "gemini", name: "Gemini CLI", symbol: "diamond.fill", processNames: ["gemini"], folders: [(".gemini", "Gemini CLI data", .appData)]),
        Tool(id: "llamacpp", name: "llama.cpp", symbol: "terminal", processNames: ["llama-server", "llama-cli"], ports: [8080]),
        Tool(id: "comfyui", name: "ComfyUI", symbol: "paintbrush.pointed.fill", pathFragments: ["ComfyUI"], ports: [8188]),
        Tool(id: "whisper", name: "Whisper", symbol: "waveform", folders: [(".cache/whisper", "Whisper models", .appData)]),
    ]

    /// Scan disk, processes and listening ports. Tools with nothing on disk and nothing running are left out.
    public static func scan(home: URL = URL(fileURLWithPath: HeadroomPaths.home),
                            processes: [ProcessInfoSnapshot]? = nil,
                            servers: [AIServer]? = nil) async -> [AITool] {
        let procs = processes ?? ProcessScanner.snapshot(includeArguments: false)
        let listening = servers ?? listeningServers()
        return await withTaskGroup(of: AITool?.self) { group in
            for tool in tools {
                group.addTask {
                    var items = folderItems(tool, home: home)
                    switch tool.id {
                    case "ollama": items += ollamaModels(home: home)
                    case "lmstudio": items += lmStudioModels(home: home)
                    case "huggingface": items += huggingFaceModels(home: home)
                    case "gpt4all": items += folderModels(home.appendingPathComponent("Library/Application Support/nomic.ai/GPT4All"), tool: tool, extensions: ["gguf", "bin"])
                    case "jan": items += folderModels(home.appendingPathComponent("jan/models"), tool: tool, extensions: nil)
                    default: break
                    }
                    let running = procs.filter { matches($0, tool) }
                    let pids = Set(running.map(\.pid))
                    let open = listening.filter { pids.contains($0.pid) || (tool.ports.contains($0.port) && running.isEmpty == false) }
                    guard !items.isEmpty || !running.isEmpty else { return nil }
                    return AITool(id: tool.id, name: tool.name, symbol: tool.symbol,
                                  items: items.sorted { $0.size.allocated > $1.size.allocated }, processes: running, servers: open)
                }
            }
            var out: [AITool] = []
            for await t in group { if let t { out.append(t) } }
            return out.sorted { $0.bytes > $1.bytes }
        }
    }

    static func matches(_ p: ProcessInfoSnapshot, _ tool: Tool) -> Bool {
        if tool.processNames.contains(p.name) {
            // "chat" alone is too generic — only count it inside GPT4All's own folder.
            if p.name == "chat" { return p.path?.contains("gpt4all") == true || p.path?.contains("GPT4All") == true }
            return true
        }
        guard let path = p.path else { return false }
        return tool.pathFragments.contains { path.contains($0) }
    }

    // MARK: Disk

    static func folderItems(_ tool: Tool, home: URL) -> [Finding] {
        tool.folders.compactMap { rel, title, role in
            let url = home.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = DiskWalker.measure(url)
            guard size.allocated > 0 else { return nil }
            let (safety, method, detail): (Safety, CleanupMethod, String) = switch role {
            case .cache: (.safe, .deleteContents, "\(tool.name) rebuilds its cache as you use it.")
            case .history: (.keep, .none, "Your past conversations — kept so you can resume them. Remove from \(tool.name) itself.")
            case .appData: (.review, .trash, "\(tool.name)'s own files. Goes to the Trash; \(tool.name) may need to set up again.")
            }
            return Finding(id: "ai:\(tool.id):\(rel)", title: title, subtitle: url.tildePath, detail: detail, category: .aiAgents,
                           safety: safety, paths: [url], size: size, lastUsed: size.newestModification, method: method, symbol: tool.symbol)
        }
    }

    static func model(_ tool: Tool, title: String, url: URL, size: DirectorySize, method: CleanupMethod, detail: String) -> Finding {
        Finding(id: "ai:\(tool.id):model:\(url.path)", title: title, subtitle: url.tildePath, detail: detail, category: .aiAgents,
                safety: .review, paths: [url], size: size, lastUsed: size.newestModification, method: method, symbol: "cube.box.fill")
    }

    /// Hugging Face hub: one item per downloaded repo (`models--org--name`, also datasets/spaces).
    static func huggingFaceModels(home: URL) -> [Finding] {
        let tool = tools.first { $0.id == "huggingface" }!
        let hub = home.appendingPathComponent(".cache/huggingface/hub")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: hub.path)) ?? []
        return names.compactMap { name -> Finding? in
            let parts = name.components(separatedBy: "--")
            guard parts.count >= 3, ["models", "datasets", "spaces"].contains(parts[0]) else { return nil }
            let url = hub.appendingPathComponent(name)
            let size = DiskWalker.measure(url)
            guard size.allocated > 0 else { return nil }
            let repo = parts.dropFirst().joined(separator: "/")
            let kind = parts[0] == "models" ? "model" : String(parts[0].dropLast())
            return model(tool, title: repo, url: url, size: size, method: .trash,
                         detail: "Hugging Face \(kind). Goes to the Trash; downloads again the next time code asks for it.")
        }
    }

    /// LM Studio: `~/.lmstudio/models/<publisher>/<model>` (and the older ~/.cache/lm-studio/models).
    static func lmStudioModels(home: URL) -> [Finding] {
        let tool = tools.first { $0.id == "lmstudio" }!
        let fm = FileManager.default
        var out: [Finding] = []
        for root in [".lmstudio/models", ".cache/lm-studio/models"].map(home.appendingPathComponent) {
            for publisher in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !publisher.hasPrefix(".") {
                let dir = root.appendingPathComponent(publisher)
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
                    let url = dir.appendingPathComponent(name)
                    let size = DiskWalker.measure(url)
                    guard size.allocated > 0 else { continue }
                    out.append(model(tool, title: "\(publisher)/\(name)", url: url, size: size, method: .trash,
                                     detail: "LM Studio model. Goes to the Trash; download it again from LM Studio's Discover tab."))
                }
            }
        }
        return out
    }

    /// Model files in a flat folder (GPT4All, Jan).
    static func folderModels(_ dir: URL, tool: Tool, extensions: Set<String>?) -> [Finding] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let url = dir.appendingPathComponent(name)
            if let extensions, !extensions.contains(url.pathExtension.lowercased()) { return nil }
            let size = DiskWalker.measure(url)
            guard size.allocated > 50_000_000 else { return nil }
            return model(tool, title: name, url: url, size: size, method: .trash,
                         detail: "\(tool.name) model. Goes to the Trash; download it again from \(tool.name).")
        }
    }

    /// Ollama: one item per model tag, sized by the blobs its manifest names. Removed with `ollama rm`
    /// (blobs are shared between tags — only Ollama knows which are still in use).
    static func ollamaModels(home: URL, ollama: String? = Shell.which("ollama")) -> [Finding] {
        let tool = tools.first { $0.id == "ollama" }!
        let models = home.appendingPathComponent(".ollama/models")
        let manifests = models.appendingPathComponent("manifests")
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [Finding] = []
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // manifests/<registry>/<namespace>/<model>/<tag>
            let parts = file.path.dropFirst(manifests.path.count + 1).split(separator: "/").map(String.init)
            guard parts.count >= 4 else { continue }
            let (namespace, name, tag) = (parts[parts.count - 3], parts[parts.count - 2], parts[parts.count - 1])
            let ref = (namespace == "library" ? name : "\(namespace)/\(name)") + ":" + tag
            let layers = ((json["layers"] as? [[String: Any]]) ?? []) + [(json["config"] as? [String: Any]) ?? [:]]
            let blobs = layers.compactMap { $0["digest"] as? String }
                .map { models.appendingPathComponent("blobs/" + $0.replacingOccurrences(of: ":", with: "-")) }
                .filter { fm.fileExists(atPath: $0.path) }
            let size = DiskWalker.measure(blobs)
            let method: CleanupMethod = ollama.map { .command(executable: $0, arguments: ["rm", ref]) } ?? .none
            out.append(model(tool, title: ref, url: file, size: size, method: method,
                             detail: ollama == nil
                                 ? "Ollama model. Install the ollama command to remove it with `ollama rm \(ref)`."
                                 : "Ollama model. Removed with `ollama rm \(ref)`; `ollama pull \(ref)` brings it back."))
        }
        return out
    }

    // MARK: Servers

    /// Your processes listening on TCP ports, from `lsof`.
    public static func listeningServers() -> [AIServer] {
        guard let out = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], timeout: 10) else { return [] }
        return parseLsof(out)
    }

    /// `lsof -F pcn` output: `p<pid>`, `c<command>`, then one `n<addr>:<port>` per socket.
    static func parseLsof(_ text: String) -> [AIServer] {
        var pid: Int32 = 0, command = ""
        var seen = Set<String>(), out: [AIServer] = []
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let host = String(value[..<colon])
                let server = AIServer(pid: pid, process: command, port: port, exposed: host == "*" || host == "0.0.0.0" || host == "[::]")
                if seen.insert(server.id).inserted { out.append(server) }
            default: break
            }
        }
        return out
    }
}
