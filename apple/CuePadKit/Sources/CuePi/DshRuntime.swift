#if os(macOS)
import CueStore
import Foundation

/// dsh（DeepSeek Harness，`@deepseek-ai/dsh`）的接入：会话只有 CuePad 托管的，托管会话与 Cue 的大脑都是通用 ACP 驱动（`ACPSession`）
/// 起的 `dsh --profile acp`（`DshLaunch`），与标准不同的只在 `DshDialect`；dsh-acp 缺的标准部分由随包插件补上（`dsh-cuepad.mjs` 头注释）。
///
/// - 会话放哪：用户自己的 DSH_HOME（登录、`acp` profile 里的设置与缺省模型照用），存储根却是 CuePad 在它下面的 `cuepad/sessions`，明文。
///   dsh 的存储是内部格式——按代际迁移、默认每批追加一个 zstd 帧、一个根只认一种编码（混进别的编码它整根拒读），同一根里的明文与压缩
///   不能并存。CuePad 跟读、补写对话要逐行读，所以托管会话进自己的明文根，代价是它们不出现在 dsh 的 web、桌面版的历史里；
///   在 CuePad 的历史里照常接着说。
/// - 不跟读用户在 web、桌面版里的会话：zstd 要另加解压依赖，旧会话还停在 v0–v3 各代的格式（每代各一份解码），读出来也只能看不能控
///   （那些会话的进程不是 CuePad 起的，没有通道）。为只读的历史不值。
/// - 托管的进程是 CuePad 起的，一个进程一个会话（歇满 `PiBridge.hostedIdle` 由桥请它退出），撑不过 App 退出。
/// - 开会话时要的模型在起进程时就给（插件的 `CUEPAD_MODEL`）：dsh-acp 握手时按它判定收不收图，之后换到能看图的模型也一样。
/// - 不接 dsh 的 `ask_user_question`（不插这个工具）：驱动只有权限确认这一种提问，它要你回答的问题在 CuePad 里答不了，会话会一直挂着。
@MainActor
public final class DshRuntime: AgentRuntime {
    private let bridge: PiBridge
    private let paths: AgentPaths
    /// 这家的可执行文件（检测时挑中的那个，`AgentStatus.executable`）；没有为 nil
    private let dsh: @Sendable () async -> URL?
    private let locate: @Sendable () async -> ExecutableLocator
    /// 会话 id → 托管它的进程上的会话
    private var hosted: [String: ACPSession] = [:]

    public init(
        bridge: PiBridge, paths: AgentPaths, dsh: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }
    ) {
        self.bridge = bridge
        self.paths = paths
        self.dsh = dsh
        self.locate = locate
    }

    public func start() throws {}

    public var hostedSessionsOutliveApp: Bool { false }

    public func stop() -> @concurrent @Sendable () async -> Void {
        let processes = hosted.values.compactMap { $0.connection?.process }
        return { for process in processes { await process.stop() } }
    }

    public func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> PiSession.ID {
        // 模型在起进程时给，不再经 `configure` 换：dsh-acp 握手时按开会话的模型判定收不收图
        let id = try await host(in: directory, model: model.map(AgentKind.dsh.modelRef), launchToken: launchToken) { try await $0.open(in: directory) }
        return try await configure(opened: id, name: name, model: nil, thinking: thinking, on: bridge)
    }

    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        if let running = hosted[session.id]?.id { return running }
        let directory = URL(filePath: session.cwd, directoryHint: .isDirectory)
        return try await host(in: directory, model: nil, launchToken: nil) { try await $0.load(session.id, in: directory) }
    }

    /// 起进程、握手、开好会话（`open`）、上桥；中途失败停掉进程再抛。进程退出时从 `hosted` 里拿掉。
    private func host(
        in directory: URL, model: String?, launchToken: String?, open: (ACPSession) async throws -> Void
    ) async throws -> PiSession.ID {
        guard let executable = await dsh() else { throw AgentRuntimeError.notInstalled(.dsh) }
        try DshLaunch.prepare(.hosted)
        let environment = await locate().environment(
            launching: executable, overrides: paths.environment.merging(DshLaunch.environment(paths, model: model)) { $1 })
        let session = ACPSession(dialect: DshDialect(patch: .hosted), bridge: bridge)
        try await session.launch(executable, environment: environment, directory: directory)
        do {
            try await open(session)
            return try attach(session, in: directory, launchToken: launchToken)
        } catch {
            await session.connection?.shutdown()
            throw error
        }
    }

    private func attach(_ session: ACPSession, in directory: URL, launchToken: String?) throws -> PiSession.ID {
        guard let sessionID = session.sessionID, let process = session.connection?.process else { throw PiBridgeError.sessionEnded }
        var state = PiSession(
            id: "\(sessionID).\(process.pid)", sessionID: sessionID, agent: .dsh, sessionFile: Self.sessionFile(home: Self.home(paths), cwd: directory, id: sessionID),
            pid: process.pid, cwd: directory, terminal: PiTerminal(), state: .settled, stateSince: .now)
        state.hosted = true
        state.launchToken = launchToken
        session.attach(state)
        hosted[sessionID] = session
        Task { [weak self] in
            _ = await process.exited()
            if self?.hosted[sessionID] === session { self?.hosted[sessionID] = nil }
        }
        return state.id
    }

    /// 会话文件：`<存储根>/<工作目录的键>/<会话 id>/session.v4.jsonl`，键照 dsh 的 `projectKey`（分隔符成 `-`，其余不安全的字成 `~XXXX`，
    /// 按 UTF-16 码元，至多 251 个，前后各加 `--`）。
    nonisolated static func sessionFile(home: URL, cwd: URL, id: String) -> URL {
        var readable = "", separated = false
        for unit in cwd.path.utf16 {
            let scalar = Unicode.Scalar(unit)
            if unit == 0x2F || unit == 0x5C || unit == 0x3A {
                if !separated { readable += "-" }
                separated = true
                continue
            }
            separated = false
            if let scalar, scalar.isASCII, scalar == "." || scalar == "_" || scalar == "-" || scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
                readable.unicodeScalars.append(scalar)
            } else {
                readable += "~" + String(format: "%04X", unit)
            }
        }
        let trimmed = String(readable.drop { $0 == "-" })
        let key = "--" + String((trimmed.isEmpty ? "root" : trimmed).prefix(251)) + "--"
        return home.appending(path: sessions, directoryHint: .isDirectory).appending(path: key).appending(path: id).appending(path: DshHistory.fileName)
    }
}

/// dsh 与 ACP 标准不同的地方（`ACPDialect`）：插话与改名经插件的扩展方法，投送请求 id 放在 `session/prompt` 的 `_meta` 里；
/// 大脑的系统提示、只读工具与临时存储都在启动参数指的补丁与环境里（`DshLaunch`），`session/new` 照标准。
struct DshDialect: ACPDialect {
    var patch: DshLaunch.Patch = .brain
    /// 插件回"歇着，走 session/prompt"的错误码（`dsh-cuepad.mjs` 的 `steer`）
    static let idle = -32001

    var agent: AgentKind { .dsh }
    var arguments: [String] { DshLaunch.arguments(patch) }

    func brain(_ config: CueBrainConfig, directory: URL) throws -> ACPBrainSetup {
        try DshLaunch.prepare(.brain)
        return ACPBrainSetup(environment: try DshLaunch.brainEnvironment(in: directory, prompt: config.systemPrompt, model: config.model), meta: nil)
    }

    @MainActor func steer(_ text: String, images: [PiImage], session: String, on connection: ACPConnection) async throws -> Bool {
        let images: [JSONValue] = images.map { ["mimeType": .string($0.mimeType), "data": .string($0.data.base64EncodedString())] }
        do {
            try await connection.call("_cuepad/steer", ["sessionId": .string(session), "text": .string(text), "images": .array(images)])
            return true
        } catch ACPError.server(Self.idle, _) {
            return false
        }
    }

    @MainActor func rename(_ name: String, session: String, cwd: URL, on connection: ACPConnection) async throws -> Bool {
        try await connection.call("_cuepad/rename", ["sessionId": .string(session), "name": .string(name)])
        return true
    }

    func promptMeta(deliveryID: String?) -> JSONValue? { deliveryID.map { ["cuepadDelivery": .string($0)] } }
}
#endif
