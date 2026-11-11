#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 测试用的模型提供方：`fake`（`FakeModel`，两个模型，窗口不同、都有 low / high 两档强度）。`echo` 是缺省，`echo-b` 是就地换到的那个
let openCodeTestModel = ModelKey(provider: OpenCodeSandbox.fake, id: "echo")
let openCodeOtherModel = ModelKey(provider: OpenCodeSandbox.fake, id: "echo-b")

/// 一台隔离的 OpenCode：钉住版本的 v2（`PinnedAgent.opencode`），HOME、XDG 与配置目录都在临时目录里，绝不碰真实的 ~/.config/opencode 与它的库，
/// 也没有任何登录或密钥——提供方 `fake` 经配置里的 `baseURL` 指到本用例的假模型（`FakeModel`，Chat Completions）。
/// 后台服务的缺省端口是固定的（0xc0de），会撞上本机真在跑的服务，所以先给它配一个空闲端口。不联网取模型表（只用随包的那份）、
/// 不开免费模型、不盯文件（它从根目录起逐级盯到工作目录，机器忙时起服务要几十秒）、不自动更新。
/// 不带工具的请求（起标题、压缩上下文的摘要）回一句固定的话。
final class OpenCodeSandbox: Sendable {
    static let fake = "fake"
    static let pinned = PinnedAgent.opencode
    let root: URL
    let work: URL
    let environment: [String: String]
    let paths: AgentPaths
    let model: FakeModel

    /// - Parameter model: 剧本要在 OpenCode 起来之前写好时先建好交进来。
    init(model: FakeModel? = nil) async throws {
        try Self.pinned.require()
        let root = try makeTempDirectory()
        let config = root.appending(path: "xc/opencode", directoryHint: .isDirectory)
        self.root = root
        work = root.appending(path: "work", directoryHint: .isDirectory)
        environment = Self.pinned.environment(home: root.appending(path: "home"), [
            "XDG_CONFIG_HOME": root.appending(path: "xc").path, "XDG_DATA_HOME": root.appending(path: "xd").path,
            "XDG_STATE_HOME": root.appending(path: "xs").path, "XDG_CACHE_HOME": root.appending(path: "xk").path,
            "OPENCODE_CONFIG_DIR": config.path, "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_DISABLE_MODELS_FETCH": "1",
            "OPENCODE_DISABLE_FREE_MODELS": "1", "OPENCODE_DISABLE_FILEWATCHER": "1",
        ])
        paths = AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: root.appending(path: "s"), environment: [:]), environment: environment)
        for directory in [work, config, root.appending(path: "home")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let fake: FakeModel
        if let model { fake = model } else { fake = try await FakeModel() }
        fake.on({ $0.tools.isEmpty }) { _ in .say("Fake summary") }
        self.model = fake
        let settings: [String: Any] = ["model": AgentKind.opencode.modelRef(openCodeTestModel), "providers": [Self.fake: Self.provider(fake)]]
        try JSONSerialization.data(withJSONObject: settings).write(to: config.appending(path: "opencode.json"))
        try await run(["service", "set", "port", String(try Self.freePort())])
    }

    private static func provider(_ model: FakeModel) -> [String: Any] {
        func entry(_ window: Int) -> [String: Any] {
            ["capabilities": ["tools": true, "input": ["text", "image"], "output": ["text"]], "limit": ["context": window, "output": 4000],
             "variants": [["id": "low", "body": [:]], ["id": "high", "body": [:]]]]
        }
        return [
            "package": "@opencode/ai/providers/openai-compatible", "settings": ["baseURL": "\(model.baseURL)/v1", "apiKey": "fake"],
            "models": ["echo": entry(100_000), "echo-b": entry(50_000)],
        ]
    }

    @MainActor func runtime(_ bridge: Bridge, _ store: CueStore) -> OpenCodeRuntime {
        OpenCodeRuntime(bridge: bridge, paths: paths, store: store, hostID: "mac", opencode: { Self.pinned.executable }, locate: { Self.pinned.locator })
    }

    @discardableResult
    func run(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        let result = try #require(
            await ChildProcess.run(Self.pinned.executable, arguments, directory: directory ?? work, environment: environment, timeout: .seconds(180)),
            "opencode \(arguments) 没跑完")
        try #require(result.status == 0, "opencode \(arguments) 失败：\(result.output)")
        return result.output
    }

    struct Service: Decodable { var url: String; var pid: Int32; var password: String }

    var service: Service? {
        (try? Data(contentsOf: paths.openCodeService)).flatMap { try? JSONDecoder().decode(Service.self, from: $0) }
    }

    @discardableResult
    func api(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        let service = try #require(service)
        var request = URLRequest(url: URL(string: service.url + path)!)
        request.httpMethod = method
        request.setValue("Basic " + Data("opencode:\(service.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        try #require((response as! HTTPURLResponse).statusCode < 300, "\(method) \(path)：\(String(decoding: data, as: UTF8.self))")
        return data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    }

    /// 失败现场：服务里每个会话的消息与待答表单、桥上的会话，写进临时目录外的一个文件（临时目录随后删掉），路径记进测试结果。
    @MainActor func dump(_ bridge: Bridge) async {
        guard let sessions = try? await api("GET", "/api/session?limit=100")["data"] as? [[String: Any]] else { return }
        var dump: [String: Any] = ["sessions": sessions, "bridge": String(describing: bridge.sessions.filter { $0.agent == .opencode })]
        for id in sessions.compactMap({ $0["id"] as? String }) {
            dump[id] = (try? await api("GET", "/api/session/\(id)/message?limit=100&order=asc"))?["data"]
            dump[id + ".form"] = (try? await api("GET", "/api/session/\(id)/form"))?["data"]
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "cuepad-opencode-\(UUID().uuidString).json")
        guard (try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted]).write(to: file)) != nil else { return }
        Issue.record("OpenCode 现场：\(file.path)")
    }

    func stop() async throws {
        if let pid = service?.pid {
            kill(pid, SIGTERM)
            try await eventually("OpenCode 服务退出") { kill(pid, 0) == -1 && errno == ESRCH }
        }
        model.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard bind(fd, $0, length) == 0, getsockname(fd, $0, &length) == 0 else { throw POSIXError(.EADDRINUSE) }
            }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
#endif
