#if os(macOS)
import CueTestSupport
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
        dir = try makeTempDirectory()
        bridge = PiBridge(socketDirectory: dir)
    }

    private func session(_ id: String) -> PiSession? { bridge.sessions.first { $0.id == id } }

    // MARK: 增量更新

    private let sonnet = FakeExtension.WireModel(provider: "anthropic", id: "sonnet", name: "Sonnet", thinking: ["off", "low", "medium"])
    private let opus = FakeExtension.WireModel(provider: "anthropic", id: "opus", name: "Opus", thinking: ["off", "high", "max"])

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

    /// 启动扫描：属主已死的残留 socket 删掉、不成会话；属主活着但还没 listen（刚 bind）的不能删，否则会破坏正在启动的会话。
    @Test func staleSocketsOfDeadProcessesAreRemovedWhileUnlistenedOnesOfLiveProcessesAreKept() async throws {
        let pending = dir.appending(path: "\(UUID().uuidString.lowercased()).\(getpid()).sock")
        let stale = dir.appending(path: "\(UUID().uuidString.lowercased()).\(try await deadPid()).sock")
        try FakeExtension.makeStaleSocket(at: pending)
        try FakeExtension.makeStaleSocket(at: stale)
        try bridge.start()
        try await eventually("扫描已发生：属主已死的残留被删") { fileGone(stale) }
        #expect(!fileGone(pending))
        #expect(bridge.sessions.isEmpty)
    }

    // MARK: 安全

    /// socket 目录只属于本人：缺了建成 0700，别人能写的目录拒绝启动。
    @Test func theSocketDirectoryIsOwnerOnlyAndAnInsecureOneIsRefused() throws {
        let fresh = dir.appending(path: "sub")
        try PiBridge(socketDirectory: fresh).start()
        var st = stat()
        #expect(lstat(fresh.path, &st) == 0 && st.st_mode & 0o777 == 0o700 && st.st_uid == getuid())

        chmod(dir.path, 0o755)
        #expect(throws: PiBridgeError.self) { try bridge.start() }
    }

    /// 别人能写的 socket 不连。启动时同步扫一遍目录，要连的话 `start()` 返回时连接已排进对端的 backlog：此刻监听端不可读就是没连。
    @Test func doesNotConnectToASocketOthersCouldWriteTo() throws {
        let path = dir.appending(path: "\(UUID().uuidString.lowercased()).\(getpid()).sock").path
        let listener = try UnixSocket.listen(path)
        defer { close(listener) }
        chmod(path, 0o666)
        try bridge.start()
        var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        #expect(poll(&pending, 1, 0) == 0)
    }

    // MARK: 协议兼容

    /// 读不懂的消息：连接判为不兼容并断开；之后在终端里 /reload，扩展在同一路径重新 listen，新 socket 不再被当成那个坏掉的旧连接跳过。
    @Test func aCorruptedMessageDropsTheConnectionAsIncompatibleAndAReloadConnectsAgain() async throws {
        let ext = FakeExtension(directory: dir)
        try ext.start()
        try bridge.start()
        let log = ChangeLog(bridge)
        try await eventually("appeared") { session(ext.id) != nil }
        ext.sendRaw(#"{"t":"state","state":{"kind":"warp-drive"}}"#)
        try await eventually("被判为不兼容并断开") {
            log.changes.contains { if case .incompatible = $0 { true } else { false } } && bridge.sessions.isEmpty
        }

        ext.crash()
        let reloaded = FakeExtension(directory: dir, sessionID: ext.sessionID)
        try reloaded.start()
        try await eventually("重载后的会话连上") { session(ext.id) != nil && reloaded.connectionCount == 1 }
    }

    // MARK: 命令

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
