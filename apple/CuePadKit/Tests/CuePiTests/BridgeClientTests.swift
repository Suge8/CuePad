#if os(macOS)
import Foundation
import Observation
import Testing
import CueStore
@testable import CuePi

/// 客户端 ↔ 桥扩展的 socket 协议接缝：用假扩展（说同一字节协议）驱动 `PiBridge`。
@MainActor
struct BridgeClientTests {
    let dir: URL
    let bridge: PiBridge

    init() throws {
        dir = try makeSocketDirectory()
        bridge = PiBridge(socketDirectory: dir)
    }

    private func session(_ id: String) -> PiSession? { bridge.sessions.first { $0.id == id } }

    // MARK: 发现

    @Test func discoversSessionsRunningBeforeStartAndStartedLater() async throws {
        let early = FakeExtension(directory: dir)
        try early.start()
        try bridge.start()
        try await eventually("已运行的会话被发现") { session(early.id) != nil }

        let late = FakeExtension(directory: dir, options: .init(cwd: "/work/other", mode: "rpc", model: nil, sessionFile: nil, tty: nil, env: [:]))
        try late.start()
        try await eventually("启动后新增的会话被发现（FSEvents）") { session(late.id) != nil }

        let s = try #require(session(early.id))
        #expect(s.sessionID == early.sessionID)
        #expect(s.pid == getpid())
        #expect(s.cwd.path == "/work/project")
        #expect(s.model?.key.id == "test-model" && s.thinking == .known(.off))
        #expect(s.sessionFile?.path == "/work/session.jsonl")
        #expect(s.state == .settled)
        #expect(s.terminal == PiTerminal(tty: "ttys009", program: "ghostty", bundleID: "com.mitchellh.ghostty",
                                         tmuxPane: "%3", tmuxSocketPath: "/private/tmp/tmux-501/default"))
        #expect(s.extensionVersion == 1)

        let l = try #require(session(late.id))
        #expect(l.sessionFile == nil && l.model == nil && l.terminal == PiTerminal())
    }

    // MARK: 模型与思考强度

    private let sonnet = FakeExtension.WireModel(provider: "anthropic", id: "sonnet", name: "Sonnet", thinking: ["off", "low", "medium"])
    private let opus = FakeExtension.WireModel(provider: "anthropic", id: "opus", name: "Opus", thinking: ["off", "high", "max"])

    // MARK: 上下文余量与斜杠命令

    /// `info` 只带变了的几项：没带的项（模型表、命令清单、会话名……）保持原样，带了 null 的才清空。
    @Test func infoCarriesOnlyWhatChangedAndLeavesTheRest() async throws {
        let compactCommand = FakeExtension.WireCommand(name: "compact", description: "压缩", source: "builtin", hint: nil)
        let ext = FakeExtension(directory: dir, options: .init(model: sonnet, thinking: "low", models: [sonnet, opus], context: (tokens: 1, window: 100), commands: [compactCommand]))
        try ext.start()
        try bridge.start()
        try await eventually("hello 带全部") { session(ext.id)?.commands.count == 1 }

        ext.sendInfo(["context": ["tokens": 50, "window": 100]])
        try await eventually("只有上下文变了") { session(ext.id)?.context?.tokens == 50 }
        let kept = try #require(session(ext.id))
        #expect(kept.availableModels.count == 2 && kept.commands.count == 1 && kept.model?.key.id == "sonnet" && kept.thinking == .known(.low))

        ext.sendInfo(["name": "改名了"])
        try await eventually("会话名变了") { session(ext.id)?.name == "改名了" }
        #expect(session(ext.id)?.context?.tokens == 50 && session(ext.id)?.availableModels.count == 2)

        ext.sendInfo(["model": NSNull(), "thinking": NSNull()])
        try await eventually("带 null 的清空") { session(ext.id)?.model == nil && session(ext.id)?.thinking == nil }
        #expect(session(ext.id)?.availableModels.count == 2 && session(ext.id)?.commands.count == 1)
    }

    // MARK: 状态

    // MARK: 结束与残留清理

    /// /reload：同一进程的扩展先告别再在同一路径重新 listen。新 socket 的目录事件可能先于旧连接断开被处理（负载高时常见），
    /// 那次扫描看到的是还挂着的旧连接；旧连接断开后不会再有目录事件，会话也得重新连上。
    @Test func reloadWhoseNewSocketIsSeenBeforeTheOldConnectionDropsStillReconnects() async throws {
        let old = FakeExtension(directory: dir)
        try old.start()
        try bridge.start()
        let log = ChangeLog(bridge)
        try await eventually("appeared") { session(old.id) != nil }

        let reloaded = FakeExtension(directory: dir, sessionID: old.sessionID)
        try reloaded.start()
        // 再起一个会话当标记：它出现时，桥已在新 socket 存在、旧连接还在时扫描过一次
        let marker = FakeExtension(directory: dir)
        try marker.start()
        try await eventually("标记会话出现") { session(marker.id) != nil }

        old.sendRaw(#"{"t":"bye","reason":"reload"}"#)
        old.crash()
        try await eventually("旧连接以 reload 结束") { log.ended.contains { $0.0.id == old.id && $0.1 == .closed(reason: "reload") } }
        try await eventually("同一会话重新连上") { session(old.id) != nil && reloaded.connectionCount == 1 }
    }

    @Test func staleSocketFromDeadProcessIsRemovedAtStartWithoutBecomingASession() async throws {
        let stale = dir.appending(path: "\(UUID().uuidString.lowercased()).\(try deadPid()).sock")
        try FakeExtension.makeStaleSocket(at: stale)
        try bridge.start()
        try await eventually("启动扫描清掉残留") { fileGone(stale) }
        #expect(bridge.sessions.isEmpty)
    }

    @Test func unlistenedSocketOfLiveProcessIsKeptWhileDeadOnesAreRemoved() async throws {
        // 进程活着但还没 listen（刚 bind）：不能删，否则会破坏正在启动的会话
        let pending = dir.appending(path: "\(UUID().uuidString.lowercased()).\(getpid()).sock")
        let stale = dir.appending(path: "\(UUID().uuidString.lowercased()).\(try deadPid()).sock")
        try FakeExtension.makeStaleSocket(at: pending)
        try FakeExtension.makeStaleSocket(at: stale)
        try bridge.start()
        try await eventually("扫描已发生：属主已死的残留被删") { fileGone(stale) }
        try await Task.sleep(for: .milliseconds(600)) // 覆盖对存活属主的一次重试
        #expect(!fileGone(pending))
    }

    // MARK: 目录安全

    @Test func rejectsDirectoryThatOthersCouldWriteTo() throws {
        chmod(dir.path, 0o755)
        #expect(throws: PiBridgeError.self) { try bridge.start() }
        #expect(bridge.sessions.isEmpty)
    }

    @Test func rejectsDirectoryPathTooLongForSunPath() throws {
        let long = PiBridge(socketDirectory: URL(filePath: "/tmp/" + String(repeating: "d", count: 60)))
        #expect(throws: PiBridgeError.socketDirectoryTooLong) { try long.start() }
    }

    @Test func createsMissingDirectoryWithOwnerOnlyPermissions() throws {
        let fresh = dir.appending(path: "sub")
        try PiBridge(socketDirectory: fresh).start()
        var st = stat()
        #expect(lstat(fresh.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
        #expect(st.st_uid == getuid())
    }
    @Test func doesNotConnectToASocketOthersCouldWriteTo() async throws {
        let ext = FakeExtension(directory: dir, options: .init(socketMode: 0o666))
        try ext.start()
        try bridge.start()
        try await Task.sleep(for: .milliseconds(400))
        #expect(bridge.sessions.isEmpty && ext.connectionCount == 0)

        chmod(ext.socketURL.path, 0o600) // 收紧权限（属性变更触发重扫）后才会被接受
        try await eventually("权限收紧后被发现") { session(ext.id) != nil }
    }

    // MARK: 协议兼容

    /// 协议不同（升级前开的旧扩展）的会话没死：照常列出、状态是"需要 /reload"，命令一条都不发给它，失败带原因；进程退出才算结束。
    @Test(arguments: [3, 99]) func 协议不同的会话在线但不可用_命令失败带原因_退出才结束(protocolVersion: Int) async throws {
        let ext = FakeExtension(directory: dir, options: .init(protocolVersion: protocolVersion, cwd: "/work/legacy"))
        try ext.start()
        try bridge.start()
        try await eventually("appeared") { session(ext.id) != nil }
        let listed = try #require(session(ext.id))
        #expect(listed.state == .incompatible)
        #expect(listed.sessionID == ext.sessionID && listed.cwd.path == "/work/legacy")

        await #expect(throws: PiBridgeError.incompatibleExtension) { try await bridge.send(PiMessage(text: "hi"), to: ext.id) }
        await #expect(throws: PiBridgeError.incompatibleExtension) { try await bridge.abort(ext.id) }
        #expect(ext.commands.isEmpty)
        #expect(PiBridgeError.incompatibleExtension.errorDescription == "这个会话正在终端里运行旧版扩展，在终端里执行 /reload 后再发")

        ext.close(bye: "quit")
        try await eventually("ended") { session(ext.id) == nil }
    }

    @Test func corruptedMessageDropsConnectionAsIncompatible() async throws {
        let ext = FakeExtension(directory: dir)
        try ext.start()
        try bridge.start()
        let log = ChangeLog(bridge)
        try await eventually("appeared") { session(ext.id) != nil }
        ext.sendRaw(#"{"t":"state","state":{"kind":"warp-drive"}}"#)
        try await eventually("被判为不兼容并断开") {
            log.changes.contains { if case .incompatible = $0 { true } else { false } } && bridge.sessions.isEmpty
        }
    }

    /// 被判为不兼容的会话在终端里 /reload：扩展在同一路径重新 listen，新 socket 不再被当成那个坏掉的旧连接跳过。
    @Test func reloadAfterBeingJudgedIncompatibleConnectsTheNewSocket() async throws {
        let ext = FakeExtension(directory: dir)
        try ext.start()
        try bridge.start()
        try await eventually("appeared") { session(ext.id) != nil }
        ext.sendRaw(#"{"t":"state","state":{"kind":"warp-drive"}}"#)
        try await eventually("被判为不兼容并断开") { bridge.sessions.isEmpty }

        ext.crash()
        let reloaded = FakeExtension(directory: dir, sessionID: ext.sessionID)
        try reloaded.start()
        try await eventually("重载后的会话连上") { session(ext.id) != nil && reloaded.connectionCount == 1 }
    }

    // MARK: 命令

    @Test func sendEncodesProtocolBytesAndReturnsDelivery() async throws {
        let ext = FakeExtension(directory: dir)
        ext.onCommand = { _, _ in ["ok": true, "delivered": "steer"] }
        try ext.start()
        try bridge.start()
        try await eventually("appeared") { session(ext.id) != nil }

        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let delivery = try await bridge.send(PiMessage(text: "看图", images: [PiImage(mimeType: "image/png", data: png)], whenBusy: .steer), to: ext.id)
        #expect(delivery == .queued(.steer))

        let cmd = try #require(ext.commands.first?.json)
        #expect(cmd["t"] as? String == "send")
        #expect(cmd["text"] as? String == "看图")
        #expect(cmd["deliverAs"] as? String == "steer")
        let images = try #require(cmd["images"] as? [[String: Any]])
        #expect(images.count == 1)
        #expect(images[0]["mimeType"] as? String == "image/png")
        #expect(images[0]["data"] as? String == png.base64EncodedString())
        #expect((cmd["id"] as? String)?.isEmpty == false)
    }

    @Test func rejectionFromExtensionSurfacesAsError() async throws {
        let ext = FakeExtension(directory: dir)
        ext.onCommand = { _, _ in ["ok": false, "error": "no_editor"] }
        try ext.start()
        try bridge.start()
        try await eventually("appeared") { session(ext.id) != nil }
        await #expect(throws: PiBridgeError.rejected("no_editor")) { try await bridge.send(PiMessage(text: "x"), to: ext.id) }
    }

    @Test func pendingSendFailsWhenSessionEndsBeforeAck() async throws {
        let ext = FakeExtension(directory: dir)
        ext.onCommand = { _, _ in nil } // 收到不回
        try ext.start()
        try bridge.start()
        try await eventually("appeared") { session(ext.id) != nil }
        let pending = Task { try await bridge.send(PiMessage(text: "x"), to: ext.id) }
        try await eventually("命令到达") { !ext.commands.isEmpty }
        ext.crash()
        await #expect(throws: PiBridgeError.sessionEnded) { try await pending.value }
    }

    // MARK: 多客户端

    @Test func twoClientsOnOneSessionBothGetSnapshotAndStateAndOwnAcks() async throws {
        let ext = FakeExtension(directory: dir)
        // ack 回显命令文字：证明 ack 只回给发送方那条连接
        ext.onCommand = { _, cmd in ["ok": false, "error": "echo:\((cmd["text"] as? String) ?? "")"] }
        try ext.start()
        let other = PiBridge(socketDirectory: dir)
        try bridge.start()
        try other.start()
        try await eventually("两个客户端都连上") {
            session(ext.id) != nil && other.sessions.contains { $0.id == ext.id } && ext.connectionCount == 2
        }

        ext.setState(["kind": "thinking"])
        try await eventually("两个客户端都收到状态切换") {
            session(ext.id)?.state == .thinking && other.sessions.first?.state == .thinking
        }

        async let a: Void = { await #expect(throws: PiBridgeError.rejected("echo:from-A")) { try await self.bridge.send(PiMessage(text: "from-A"), to: ext.id) } }()
        async let b: Void = { await #expect(throws: PiBridgeError.rejected("echo:from-B")) { try await other.send(PiMessage(text: "from-B"), to: ext.id) } }()
        _ = await (a, b)
        #expect(ext.commands.count == 2)
    }
    // MARK: 分格观察

    /// 查某个会话只随这一个会话的变化通知：别的会话状态一变，读它的视图就要重算的话，Agent 多起来时每秒几十次整页重算。
    @Test func lookingUpOneSessionIsNotNotifiedByAnotherSessionsChanges() async throws {
        let first = FakeExtension(directory: dir)
        try first.start()
        try bridge.start()
        try await eventually("先出现的会话被发现") { session(first.id) != nil }
        let second = FakeExtension(directory: dir)
        try second.start()
        try await eventually("后出现的会话被发现") { session(second.id) != nil }

        let notified = Flag()
        withObservationTracking { _ = bridge.session(sessionID: second.sessionID) } onChange: { notified.value = true }

        first.setState(["kind": "thinking"])
        try await eventually("别的会话的状态到了桥上") { session(first.id)?.state == .thinking }
        #expect(!notified.value)

        second.setState(["kind": "thinking"])
        try await eventually("它自己的变化通知到读它的人") { notified.value }
    }
}

private final class Flag: @unchecked Sendable {
    nonisolated(unsafe) var value = false
}
#endif
