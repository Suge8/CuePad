#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

private let environment = ProcessInfo.processInfo.environment
/// 测试用的 OpenCode v2：`CUEPAD_OPENCODE` 给的可执行文件，没给就是本机装的里头第一个 v2（v1 的接口不同）
let realOpenCodeURL = environment["CUEPAD_OPENCODE"].map { URL(filePath: $0) }
    ?? ExecutableLocator.standard.candidates("opencode").first { (version(of: $0)?.major ?? 0) >= 2 }
/// 测试用的模型：缺省是假模型（`Fixtures/fake-openai.mjs`，提供方 `fake`，零网络、结果确定）；`CUEPAD_AGENT_TESTS` 列出 opencode 时
/// 换成真提供方 `CUEPAD_OPENCODE_MODEL`（`提供方/模型`，密钥只经环境给，如 `DEEPSEEK_API_KEY`），`CUEPAD_OPENCODE_OTHER_MODEL`
/// 是就地换到的那个（要有 high 强度），缺省同一个
let openCodeRealModel = environment["CUEPAD_OPENCODE_MODEL"].flatMap(AgentKind.opencode.modelKey)
/// 列出 opencode 却没给（或写错）真提供方的模型时套件跳过（`RealAgents.missing`），用不到这里
let openCodeTestModel = RealAgents.recording.contains(.opencode) ? openCodeRealModel! : PiModelKey(provider: OpenCodeSandbox.fake, id: "echo")

/// `opencode --version` 报的版本；跑不起来或读不懂为 nil
private func version(of executable: URL) -> AgentVersion? {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--version"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return AgentVersion(parsing: text)
}
let openCodeOtherModel = openCodeTestModel.provider == OpenCodeSandbox.fake ? PiModelKey(provider: OpenCodeSandbox.fake, id: "echo-b")
    : environment["CUEPAD_OPENCODE_OTHER_MODEL"].flatMap(AgentKind.opencode.modelKey) ?? openCodeTestModel

/// 一台隔离的 OpenCode：HOME、XDG 与配置目录都在临时目录里，绝不碰真实的 ~/.config/opencode 与它的库。
/// 后台服务的缺省端口是固定的（0xc0de），会撞上本机真在跑的服务，所以先给它配一个空闲端口。不联网取模型表（只用随包的那份）、
/// 不开免费模型、不盯文件（它从根目录起逐级盯到工作目录，机器忙时起服务要几十秒）。
/// - 假模型：起一个 `Fixtures/fake-openai.mjs`，配成提供方 `fake`（两个模型，窗口不同、都有 low / high 两档强度）；
/// - 真模型：提供方的密钥（测试进程环境里 `*_API_KEY` 的）交给它，模型要在随包的模型表里。
final class OpenCodeSandbox: Sendable {
    static let fake = "fake"
    let root: URL
    let work: URL
    let environment: [String: String]
    let paths: AgentPaths
    private let model: ChildProcess?

    init() async throws {
        let root = try makeTempDirectory()
        let config = root.appending(path: "xc/opencode", directoryHint: .isDirectory)
        self.root = root
        work = root.appending(path: "work", directoryHint: .isDirectory)
        environment = [
            "HOME": root.appending(path: "home").path, "XDG_CONFIG_HOME": root.appending(path: "xc").path,
            "XDG_DATA_HOME": root.appending(path: "xd").path, "XDG_STATE_HOME": root.appending(path: "xs").path,
            "XDG_CACHE_HOME": root.appending(path: "xk").path, "OPENCODE_CONFIG_DIR": config.path, "OPENCODE_DISABLE_AUTOUPDATE": "1",
            "PATH": [realOpenCodeURL!.deletingLastPathComponent().path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
            "OPENCODE_DISABLE_MODELS_FETCH": "1", "OPENCODE_DISABLE_FREE_MODELS": "1", "OPENCODE_DISABLE_FILEWATCHER": "1",
        ].merging(ProcessInfo.processInfo.environment.filter { $0.key.hasSuffix("_API_KEY") }) { $1 }
        paths = AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: root.appending(path: "s"), environment: [:]), environment: environment)
        for directory in [work, config, root.appending(path: "home")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var settings: [String: Any] = ["model": AgentKind.opencode.modelRef(openCodeTestModel)]
        model = openCodeTestModel.provider == Self.fake ? try await Self.fakeModel() : nil
        if let model { settings["providers"] = [Self.fake: try await Self.provider(model)] }
        try JSONSerialization.data(withJSONObject: settings).write(to: config.appending(path: "opencode.json"))
        try await run(["service", "set", "port", String(try Self.freePort())])
    }

    private static func fakeModel() async throws -> ChildProcess {
        let node = try #require(ExecutableLocator.standard.candidates("node").first)
        let script = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake-openai.mjs")
        return try await ChildProcess(node, [script.path], placement: .group, input: .pipe, output: .lines)
    }

    /// 假模型的提供方配置（OpenCode v2 的 `providers`）：地址是它报出的端口
    private static func provider(_ model: ChildProcess) async throws -> [String: Any] {
        struct Ready: Decodable { var port: Int }
        let line = try #require(await model.output.first { _ in true }, "假模型没报端口")
        let port = try JSONDecoder().decode(Ready.self, from: line).port
        func entry(_ window: Int) -> [String: Any] {
            ["capabilities": ["tools": true, "input": ["text", "image"], "output": ["text"]], "limit": ["context": window, "output": 4000],
             "variants": [["id": "low", "body": [:]], ["id": "high", "body": [:]]]]
        }
        return [
            "package": "@opencode/ai/providers/openai-compatible", "settings": ["baseURL": "http://127.0.0.1:\(port)/v1", "apiKey": "fake"],
            "models": ["echo": entry(100_000), "echo-b": entry(50_000)],
        ]
    }

    /// 连这台服务的接入
    @MainActor func runtime(_ bridge: PiBridge, _ store: CueStore) -> OpenCodeRuntime {
        OpenCodeRuntime(bridge: bridge, paths: paths, store: store, hostID: "mac", opencode: { realOpenCodeURL })
    }

    /// 跑一条 opencode 命令（在 `directory` 里），要它成功。
    @discardableResult
    func run(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        let opencode = try #require(realOpenCodeURL)
        let result = try #require(
            await ChildProcess.run(opencode, arguments, directory: directory ?? work, environment: environment, timeout: .seconds(180)),
            "opencode \(arguments) 没跑完")
        try #require(result.status == 0, "opencode \(arguments) 失败：\(result.output)")
        return result.output
    }

    struct Service: Decodable { var url: String; var pid: Int32; var password: String }

    var service: Service? {
        (try? Data(contentsOf: paths.openCodeService)).flatMap { try? JSONDecoder().decode(Service.self, from: $0) }
    }

    /// 像终端里的另一个客户端那样直接调服务的接口。
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
    @MainActor func dump(_ bridge: PiBridge) async {
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

    /// 停掉这台的后台服务（按登记文件里的确切 pid）与假模型，删掉临时目录。
    func stop() async throws {
        if let pid = service?.pid {
            kill(pid, SIGTERM)
            try await eventually("OpenCode 服务退出") { kill(pid, 0) == -1 && errno == ESRCH }
        }
        await model?.stop()
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
