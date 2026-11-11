#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import ImageIO
import Testing
@testable import CueBridge

/// 测试连的 Codex：钉住的版本（`PinnedAgent.codex`），模型是本用例的假模型（`FakeModel`，Responses），零网络、不用任何登录。
let pinnedCodex = PinnedAgent.codex
let codexTestModel = "gpt-5.5"

/// 一张 64×64 的 sRGB 纯色 PNG（1×1 的图、设备色彩空间里的纯红，模型有时说成别的颜色）。
func solidPNG(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(try #require(CGColor(colorSpace: sRGB, components: [red, green, blue, 1])))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

/// 一个临时的 Codex 配置目录，与它配套的 CuePad socket 目录与工作目录。起的 codex 与接入用的环境把家目录、各家的配置目录、
/// XDG 目录、CuePad 的资料库与 socket 目录都指到这里，不读写真实的配置与资料库。
/// 模型提供方写在这个目录的 `config.toml` 里（Codex 只认 Responses；项目目录下的提供方配置会被忽略）。
struct CodexHome {
    let root: URL
    let model: FakeModel
    /// 会话用的模型：缺省 gpt-5.5（工具是普通的函数 `exec_command`），gpt-6-luna 一档走代码模式的 `exec`
    let modelName: String
    var home: URL { root.appending(path: "codex", directoryHint: .isDirectory) }
    var work: URL { root.appending(path: "work", directoryHint: .isDirectory) }
    var sockets: URL { root.appending(path: "s", directoryHint: .isDirectory) }
    var paths: AgentPaths {
        AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets), environment: environment)
    }
    var locator: ExecutableLocator { pinnedCodex.locator }
    var environment: [String: String] {
        func path(_ name: String) -> String { root.appending(path: name).path }
        return pinnedCodex.environment(home: root.appending(path: "user"), [
            "XDG_CONFIG_HOME": path("xdg/config"), "XDG_DATA_HOME": path("xdg/data"),
            "XDG_STATE_HOME": path("xdg/state"), "XDG_CACHE_HOME": path("xdg/cache"), "CLAUDE_CONFIG_DIR": path("claude"),
            "OPENCODE_CONFIG_DIR": path("opencode"), "PI_CODING_AGENT_DIR": path("pi"), "CUEPAD_LIBRARY_DIR": path("library"),
            "CODEX_HOME": home.path, "CUEPAD_PI_SOCKET_DIR": sockets.path, Self.keyVariable: "fake",
        ].merging(Self.deadProxy) { $1 })
    }
    /// 测试零网络：Codex 自己要连外网的都经指向本机没人监听的端口的代理挡住。假模型在 127.0.0.1，由 NO_PROXY 放行。
    static let deadProxy: [String: String] = {
        var proxy = ["NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"]
        for name in ["https_proxy", "http_proxy", "all_proxy"] {
            proxy[name] = "http://127.0.0.1:1"
            proxy[name.uppercased()] = "http://127.0.0.1:1"
        }
        return proxy
    }()
    static let keyVariable = "CUEPAD_FAKE_MODEL_KEY"

    init(model: FakeModel, modelName: String = codexTestModel) throws {
        try pinnedCodex.require()
        root = try makeTempDirectory()
        self.model = model
        self.modelName = modelName
        for directory in [home, work, root.appending(path: "user")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// 配置：假模型当提供方，最便宜的思考强度，信任工作目录，关掉更新检查与遥测。
    func signIn(approvals: String = "never") throws {
        let config = """
            model = "\(modelName)"
            model_reasoning_effort = "low"
            approval_policy = "\(approvals)"
            sandbox_mode = "workspace-write"
            check_for_update_on_startup = false

            [projects."\(work.realPath.path)"]
            trust_level = "trusted"

            """
        try Self.write(provider: model, config: config, into: home)
    }

    /// 把假模型写成这个配置目录的提供方（`model_providers` 只认这里，项目目录下同名的会被忽略）。
    /// 插件三项必须关：启动时会把官方插件仓库 git 克隆进 `$CODEX_HOME/.tmp/plugins-clone-*`，即联网（关了之后实测不再出现）；apps 等三项连应用连接器，也联网。
    static func write(provider model: FakeModel, config: String = "", into home: URL) throws {
        let text = """
            model_provider = "fake"
            \(config)
            [analytics]
            enabled = false

            [features]
            plugins = false
            apps = false
            browser_use = false
            computer_use = false
            remote_plugin = false
            plugin_discovery_prefetch = false

            [model_providers.fake]
            name = "fake"
            base_url = "\(model.baseURL)/v1"
            env_key = "\(keyVariable)"
            wire_api = "responses"

            """
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try text.write(to: home.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    }

    @concurrent func remove() async {
        model.stop()
        await TestProcesses.stop(under: [root])
        try? FileManager.default.removeItem(at: root)
    }

    func using(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await remove()
            throw error
        }
        await remove()
    }
}

@MainActor
func withCodexRig(
    approvals: String = "never", model: String = codexTestModel, readFault: CodexReadFault.Mode? = nil, timing: Timing = noDeadline,
    _ body: (CodexRig) async throws -> Void
) async throws {
    let rig = try await CodexRig(approvals: approvals, model: model, readFault: readFault, timing: timing)
    do {
        try await body(rig)
    } catch {
        await rig.stop()
        throw error
    }
    await rig.stop()
}

/// 要批准才能跑的命令。两档模型的命令工具不同：gpt-5.5 的函数 `exec_command`，gpt-6-luna 一档的代码模式 `exec`（一段 JS，里面调 `tools.exec_command`）；
/// CuePad 看到的一样（app-server 报同样的 `commandExecution` 项与审批请求）。
func codexEscalated(_ command: String, model: String = codexTestModel) -> FakeReply {
    let arguments: [String: any Sendable] = ["cmd": command, "sandbox_permissions": "require_escalated", "justification": "test"]
    let json = String(decoding: (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data(), as: UTF8.self)
    return model == codexTestModel
        ? .call("exec_command", arguments)
        : .custom("exec", "const r = await tools.exec_command(\(json)); text(JSON.stringify(r));")
}

@MainActor
final class CodexRig {
    let codex: CodexHome
    let bridge: Bridge
    let runtime: CodexRuntime
    /// 托管的 Codex 经它起时有（`readFault`）
    let readFault: CodexReadFault?
    var model: FakeModel { codex.model }

    /// - Parameter readFault: 托管的 Codex 经 `CodexReadFault` 起，子线程的 `thread/read` 先照这一档回。
    /// - Parameter timing: CuePad 自己的时限按它量（缺省永不到点，见 `noDeadline`）。
    init(
        approvals: String = "never", model: String = codexTestModel, readFault: CodexReadFault.Mode? = nil, timing: Timing = noDeadline
    ) async throws {
        let codex = try CodexHome(model: try await FakeModel(), modelName: model)
        let bridge = Bridge(socketDirectory: codex.sockets)
        let locator = codex.locator
        let fault = try readFault.map { try CodexReadFault(around: pinnedCodex.executable, in: codex.root, mode: $0) }
        let launch = fault?.executable
        let runtime = CodexRuntime(
            bridge: bridge, paths: codex.paths, codex: { [locator] in launch ?? locator.candidates("codex").first }, locate: { [locator] in locator },
            timing: timing)
        do {
            try codex.signIn(approvals: approvals)
            try bridge.start()
            try runtime.start()
        } catch {
            await runtime.stop()()
            bridge.stop()
            await codex.remove()
            throw error
        }
        (self.codex, self.bridge, self.runtime, self.readFault) = (codex, bridge, runtime, fault)
    }

    /// 关掉托管的进程，删掉临时目录（含凭据，`CodexHome.remove`）。
    func stop() async {
        await runtime.stop()()
        bridge.stop()
        await codex.remove()
    }

    var session: Session? { bridge.sessions.first { $0.agent == .codex } }

    func transcript(_ session: Session) throws -> HistoryUpdate {
        try History.index(file: try #require(session.sessionFile), agent: .codex, from: nil, files: scratchFiles)
    }

    func replies(_ session: Session) -> [String] {
        ((try? transcript(session))?.messages ?? []).filter { $0.role == .known(.pi) }.map(\.text)
    }

    func draftLanded(_ id: Session.ID) -> Bool {
        guard let draft = bridge.slots.first(where: { $0.id == id })?.draft else { return true }
        let session = bridge.session(id: id)
        let newest = session.flatMap { try? transcript($0) }?.messages.last { $0.role == .known(.pi) }
        return draft.landed(newestReply: newest?.at, record: newest?.id)
    }
}
#endif
