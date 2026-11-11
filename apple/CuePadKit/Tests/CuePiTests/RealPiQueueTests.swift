#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePi

/// 按回合停止与后续发送的协议合同。真实 Pi、桥和 Python 工具；模型与异步事件闸是替身。
@MainActor
@Suite(RealAgents.needs(.pi), RealAgents.tiered, .serialized)
struct RealPiQueueTests {
    @Test(arguments: ["preflight", "preflight-control", "pending", "starting", "sdk"])
    func 停止原回合不遗失后续消息(stage: String) async throws {
        try await withAgent { bridge, session, folder, gate in
            let delivery = UUID().uuidString
            try await bridge.send(SessionMessage(text: work("A"), deliveryID: delivery), to: session.id)
            try await eventually("A 的真实工具开始") { exists(folder, "A.pid") }
            let a = try pid("A", in: folder)
            let originalTurn = try #require(bridge.session(id: session.id)?.turnStartedAt).stored
            let held = stage == "preflight-control" ? "preflight" : stage
            try Data().write(to: gate.appending(path: "\(held).arm"))
            if stage == "sdk" {
                try await eventually("公开 SDK 队列已受理") { exists(gate, "sdk.pending") || exists(gate, "sdk.empty") }
                try #require(exists(gate, "sdk.pending"))
                await #expect(throws: BridgeError.rejected("stale_turn")) { try await bridge.abort(session.id, deliveryID: delivery, turnStartedAt: originalTurn) }
                #expect(kill(a, 0) == 0)
                #expect(kill(a, SIGUSR1) == 0)
            } else {
                let send = Task { try await bridge.send(SessionMessage(text: "QUEUE-B " + work("B")), to: session.id) }
                defer { try? Data().write(to: gate.appending(path: "\(held).release")); send.cancel() }
                try await eventually("\(held) 处等待") { exists(gate, "\(held).held") }
                if stage == "pending" {
                    try await eventually("旧停止的实际回合已结束，后续消息仍在闸内") {
                        bridge.session(id: session.id)?.turnStartedAt?.stored != originalTurn
                    }
                    await #expect(throws: BridgeError.rejected("stale_turn")) {
                        try await bridge.abort(session.id, deliveryID: delivery, turnStartedAt: originalTurn)
                    }
                } else if stage == "starting" {
                    await #expect(throws: BridgeError.rejected("stale_turn")) { try await bridge.abort(session.id, deliveryID: delivery, turnStartedAt: originalTurn) }
                } else if stage != "preflight-control" {
                    try await bridge.abort(session.id, deliveryID: delivery, turnStartedAt: originalTurn)
                    if stage == "preflight" { try await eventually("原回合 A 已实际退出") { kill(a, 0) != 0 } }
                }
                try Data().write(to: gate.appending(path: "\(held).release"))
                try await send.value
                #expect(!exists(gate, "\(held).ceiling"), "不能靠闸超时制造通过")
            }
            try await eventually("B 的实际工具开始") { exists(folder, "B.pid") }
            let b = try pid("B", in: folder)
            #expect(kill(b, 0) == 0)
            if stage == "sdk" { #expect(exists(folder, "A.done"), "A 正常结束后才轮到 SDK 队列里的 B") }
            try await bridge.abort(session.id)
            try await eventually("B 的真实工具停止，进程清理完毕") { kill(b, 0) != 0 }
        }
    }

    private func work(_ name: String) -> String { "WORK-\(name)" }

    /// 每句话的工具是一个真进程：写下自己的 pid（先写别名再改名：测试见到文件就读，直接写会读到空的），等 SIGUSR1 至多 30 秒，等到了才留下 `<名>.done`。
    /// 写 pid 之前先屏蔽 SIGUSR1 与到点的 SIGALRM 再用 sigwait 收（macOS 的 Python 没有 sigtimedwait）：测试见到 pid 就可能发信号，`signal.pause()` 之前到的会被处理掉，pause 就一直等到上限（负载下实测）
    private func script(_ model: FakeModel) {
        for name in ["A", "B"] {
            let command = "python3 -c 'import os,signal;signal.pthread_sigmask(signal.SIG_BLOCK,{signal.SIGUSR1,signal.SIGALRM});open(\"\(name).tmp\",\"w\").write(str(os.getpid()));os.rename(\"\(name).tmp\",\"\(name).pid\");signal.alarm(30);signal.sigwait({signal.SIGUSR1,signal.SIGALRM})==signal.SIGUSR1 and open(\"\(name).done\",\"w\").write(\"finished\")'"
            model.on(work(name), .call("bash", ["command": command]), .say("TOOL_DONE"))
        }
    }

    private func exists(_ folder: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: name).path)
    }

    private func pid(_ name: String, in folder: URL) throws -> pid_t {
        try #require(pid_t(String(contentsOf: folder.appending(path: "\(name).pid"), encoding: .utf8)))
    }

    private func withAgent(_ body: (Bridge, Session, URL, URL) async throws -> Void) async throws {
        let root = try makeTempDirectory(), folder = root.appending(path: "work"), agent = root.appending(path: "agent")
        let paths = PiPaths(agentDirectory: agent, socketDirectory: root.appending(path: "s"), binDirectory: root.appending(path: "bin"))
        for directory in [folder, agent] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try pinnedPi.require()
        let model = try await FakeModel()
        try PiProcess.writeModels(model, into: agent)
        script(model)
        let environment = pinnedPi.environment(home: root, paths.launchEnvironment.merging(["PI_OFFLINE": "1"]) { $1 })
        let process = try await ChildProcess(pinnedPi.executable, ["--mode", "rpc", "--no-extensions", "-e", PiExtensionBundle.url.path,
            "-e", fixturesDirectory.appending(path: "queue-gates.ts").path,
            "--model", "fake/echo", "--no-skills"], directory: folder, environment: environment, placement: .group, input: .pipe)
        let bridge = Bridge(socketDirectory: paths.socketDirectory)
        do {
            try bridge.start()
            try await eventually("真实 Pi 接上桥") { bridge.sessions.contains { $0.pid == process.pid } }
            let session = try #require(bridge.sessions.first { $0.pid == process.pid })
            try await body(bridge, session, folder, agent.appending(path: "queue-gates"))
        } catch {
            bridge.stop(); process.end(); _ = await process.waitForExit()
            throw error
        }
        bridge.stop(); process.end(); _ = await process.waitForExit()
    }
}
#endif
