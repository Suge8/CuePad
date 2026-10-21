#if os(macOS)
import CryptoKit
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 一台隔离的 OpenCode：HOME、XDG 与配置目录都在临时目录里，绝不碰真实的 ~/.config/opencode 与它的库。
/// 后台服务的缺省端口是固定的（0xc0de），会撞上本机真在跑的服务，所以先给它配一个空闲端口。
/// 像用过 OpenCode 的机器：先起一次服务、等它取到模型表（存进它的库）再停。从没取过表的头一次启动用随包的旧表，
/// 配置的默认模型不在旧表里时它改用表里第一个（README"已知边界"）。
final class OpenCodeSandbox {
    let root: URL
    let work: URL
    let environment: [String: String]
    let paths: AgentPaths

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
        ]
        paths = AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: root.appending(path: "s"), environment: [:]), environment: environment)
        for directory in [work, config, root.appending(path: "home")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let settings: [String: Any] = ["model": "\(openCodeTestModel.provider)/\(openCodeTestModel.id)"]
        try JSONSerialization.data(withJSONObject: settings).write(to: config.appending(path: "opencode.json"))
        try await run(["service", "set", "port", String(try Self.freePort())])
        try await run(["service", "start"])
        try await refreshed()
        let pid = try #require(service?.pid)
        try await run(["service", "stop"])
        try await eventually("OpenCode 服务退出") { kill(pid, 0) == -1 && errno == ESRCH && self.service == nil }
    }

    /// 让服务取到模型表：头一回有人要模型表时它才联网取（实测 0.6～2 秒），存进它库里的 `kv`（`models-dev:catalog`）后发
    /// `models-dev.refreshed`。先连上事件流再要一次模型表；连上时与之后每来一行（含每 15 秒的心跳）都看一眼库里存了没有。
    private func refreshed() async throws {
        let service = try #require(service)
        var request = URLRequest(url: URL(string: service.url + "/api/event")!)
        request.setValue("Basic " + Data("opencode:\(service.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let events = request
        request.url = URL(string: service.url + "/api/model")!
        let models = request
        let database = root.appending(path: "xd/opencode/opencode.db").path
        try await withDeadline(.seconds(60), orThrow: CancellationError()) {
            let (bytes, _) = try await URLSession.shared.bytes(for: events)
            var asked = false
            for try await _ in bytes.lines {
                if !asked {
                    _ = try await URLSession.shared.data(for: models)
                    asked = true
                }
                let stored = await ChildProcess.run(
                    URL(filePath: "/usr/bin/sqlite3"), ["-readonly", database, "SELECT count(*) FROM kv WHERE key = 'models-dev:catalog'"],
                    timeout: .seconds(10))
                if stored?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return }
            }
        }
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

    /// 停掉这台的后台服务（按登记文件里的确切 pid），删掉临时目录。
    func stop() async throws {
        if let pid = service?.pid {
            kill(pid, SIGTERM)
            try await eventually("OpenCode 服务退出") { kill(pid, 0) == -1 && errno == ESRCH }
        }
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
