import AppKit
import Darwin
import ClipboardCore
import CryptoKit

// Local stdio; named connections use revocable credentials, legacy clients approve each session.
enum MCPService {
    static let tokenEnvironmentKey = "CLIPSHELF_MCP_TOKEN"
    static func credentialID(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func credentialAuthorized(_ token: String, defaults: UserDefaults) -> Bool {
        !token.isEmpty && defaults.bool(forKey: "mcpEnabled") &&
            defaults.dictionary(forKey: "mcpClients")?[credentialID(token)] is String
    }
    static func response(_ request: [String: Any], history: History, authorized: Bool) -> [String: Any]? {
        guard let id = request["id"] else { return nil }
        func result(_ value: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        func failure(_ code: Int, _ message: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]] }
        guard authorized else { return failure(-32001, "Clipboard access was not approved or MCP is disabled") }
        switch request["method"] as? String {
        case "initialize":
            let offered = (request["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-03-26"
            let version = ["2024-11-05", "2025-03-26", "2025-06-18"].contains(offered) ? offered : "2025-03-26"
            return result(["protocolVersion": version, "capabilities": ["tools": [:]], "serverInfo": ["name": "ClipShelf", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.4"]])
        case "ping": return result([:])
        case "tools/list":
            return result(["tools": [
                ["name": "search_items", "description": "Search local clipboard text and source apps", "inputSchema": ["type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer", "minimum": 1, "maximum": 50]], "additionalProperties": false]],
                ["name": "get_item", "description": "Read one clipboard item by ID, without binary representations", "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"], "additionalProperties": false]],
                ["name": "list_pinboards", "description": "List local pinboards and their item IDs", "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]]
            ]])
        case "tools/call":
            guard let params = request["params"] as? [String: Any], let name = params["name"] as? String else { return failure(-32602, "Invalid tool call") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let payload: Any
            func item(_ clip: Clip) -> [String: Any] {
                ["id": clip.id.uuidString, "kind": clip.kind.rawValue, "text": clip.text, "source": clip.sourceName, "copiedAt": ISO8601DateFormatter().string(from: clip.copiedAt)]
            }
            switch name {
            case "search_items":
                guard args["query"] == nil || args["query"] is String,
                      args["limit"] == nil || args["limit"] is Int else { return failure(-32602, "Invalid search arguments") }
                let query = args["query"] as? String ?? ""
                let limit = args["limit"] as? Int ?? 20
                guard query.count <= 4096, (1...50).contains(limit) else { return failure(-32602, "Query or limit exceeds bounds") }
                payload = history.clips.filter { $0.matches(query) }.prefix(limit).map(item)
            case "get_item":
                guard let value = args["id"] as? String, let uuid = UUID(uuidString: value), let clip = history.clips.first(where: { $0.id == uuid }) else { return failure(-32602, "Item not found") }
                payload = item(clip)
            case "list_pinboards": payload = history.boards.map { ["id": $0.id.uuidString, "name": $0.name, "itemIDs": $0.clipIDs.map(\.uuidString)] as [String: Any] }
            default: return failure(-32601, "Unknown tool")
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return failure(-32603, "Unable to encode result") }
            return result(["content": [["type": "text", "text": text]]])
        default: return failure(-32601, "Unknown method")
        }
    }

    static func readChunk(from input: FileHandle) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(input.fileDescriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            return Data(buffer.prefix(count))
        }
    }

    @MainActor static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var authorized = false
        var sessionEpoch: String?
        var pending = Data()
        let token = ProcessInfo.processInfo.environment[tokenEnvironmentKey]
        func send(_ response: Any) {
            if let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipShelf/history.plist")
        // Read available pipe bytes without waiting for a full 4096-byte buffer.
        while let chunk = readChunk(from: .standardInput) {
            pending.append(chunk)
            guard pending.count <= 1_048_576 else { break }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard let decoded = try? JSONSerialization.jsonObject(with: line) else {
                    send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Invalid JSON"]]); continue
                }
                let batched = decoded is [Any]
                let requests: [[String: Any]]
                if let request = decoded as? [String: Any] { requests = [request] }
                else if let array = decoded as? [[String: Any]], !array.isEmpty { requests = array }
                else { send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid request"]]); continue }
                var responses: [[String: Any]] = []
                for request in requests {
                UserDefaults.standard.synchronize()
                let enabled = UserDefaults.standard.bool(forKey: "mcpEnabled")
                let epoch = UserDefaults.standard.string(forKey: "mcpSessionEpoch")
                if epoch != sessionEpoch || !enabled { authorized = false; sessionEpoch = epoch }
                if let token {
                    authorized = credentialAuthorized(token, defaults: .standard)
                }
                if token == nil, request["method"] as? String == "initialize", enabled, !authorized {
                    let info = (request["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
                    let rawName = info?["name"] as? String ?? "AI 客户端"
                    let name = String(String.UnicodeScalarView(rawName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).prefix(100)
                    let alert = NSAlert()
                    alert.messageText = L("允许“%@”读取剪贴板？", name)
                    alert.informativeText = L("此 MCP 会话可读取本机历史记录与分组，包括可能的敏感内容。授权只对当前会话有效。客户端名称由对方提供，请仅批准自己启动的客户端。")
                    alert.addButton(withTitle: L("允许本次会话"))
                    alert.addButton(withTitle: L("拒绝"))
                    app.activate(ignoringOtherApps: true)
                    authorized = alert.runModal() == .alertFirstButtonReturn
                }
                let allowed = enabled && authorized
                let history: History
                do { history = allowed ? try History.load(from: url) : History() }
                catch {
                    if let id = request["id"] { responses.append(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": "History archive cannot be read"]]) }
                    continue
                }
                if let response = response(request, history: history, authorized: allowed) { responses.append(response) }
                }
                if batched { if !responses.isEmpty { send(responses) } }
                else if let response = responses.first { send(response) }
            }
        }
    }
}
