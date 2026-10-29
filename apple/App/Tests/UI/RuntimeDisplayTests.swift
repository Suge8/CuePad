import CueStore
import Foundation
import Testing
@testable import CuePad
#if os(macOS)
import CuePi
#endif

/// #43：关机与重启撤销运行断言，但不能把工作、历史或活动伪造成已完成。
struct RuntimeDisplayTests {
    @Test func 离线与系统重启不沿用旧报告_同boot重开仍保留确认_回填不续命() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let store = app.services.store
        let workspace = Workspace(services: app.services)
        let recorder = try await app.runtimeRecorder(on: "mac-a", boot: "test-boot")
        var tasks: [UUID] = []
        for (id, state) in [("working", PiWorkState.thinking), ("compacting", .compacting), ("delegating", .delegating)] {
            let task = try await workspace.createTask(id, in: Project.defaultID)
            tasks.append(task.id)
            try await recorder.update(sessionID: id, state: state, title: id, hosted: true, subagents: [
                PiSubagentState(name: "builder", role: "工程师", phase: .known(.running)),
            ])
            try await store.bindSession(id, to: task.id)
            try await store.writePiTranscript(PiTranscript(sessionID: id, messages: [
                PiChatMessage(sessionID: id, entryID: "u1", seq: 1, role: .user, text: "关机前的工作", at: clock.now),
            ], recap: PiRecap(lastPrompt: "关机前的工作")))
        }
        func now() async throws -> CueNow {
            CueNow(try await CueDigest.read(from: store), at: .always(at: clock.now), local: .init(waiting: nil, here: nil))
        }
        let snapshot = try await now()
        #expect(snapshot.subagents == 3 && snapshot.tally.moving == 3 && snapshot.hasConfirmedActivity)
        _ = app.relaunch()
        try await store.recordMacPresence(host: "mac-a", bootID: "test-boot") { true }
        #expect(try await now().tally.moving == 3)

        try await store.recordMacPresence(host: "mac-a", bootID: "test-boot") { false }
        let offline = try await now()
        #expect(offline.subagents == 0 && offline.tally.moving == 0 && offline.advancing == 3)
        #expect(offline.isLive && !offline.hasConfirmedActivity)
        let board = try await TaskBoard.read(from: store)
        #expect(board.advancing.allSatisfy { workspace.shown($0.agent!).status == .unknown })
        #expect(snapshot.shown(at: snapshot.at + 601).tally.moving == 0)
        #expect(snapshot.shown(at: snapshot.at + 601).isLive && !snapshot.shown(at: snapshot.at + 601).hasConfirmedActivity)

        try await store.recordMacPresence(host: "mac-a", bootID: "new-system-boot") { true }
        try await store.writePiTranscript(PiTranscript(sessionID: "compacting", messages: [], recap: PiRecap(lastReply: "晚到的历史")))
        let after = try #require(try await store.piSessions(sessionIDs: ["compacting"])["compacting"]?.state)
        #expect(after.state == .known(.compacting) && after.bootID == "test-boot")
        #expect(try await !store.runtimeIsConfirmed(after, at: clock.now))
        #expect(try await now().tally.moving == 0)
        for id in tasks { #expect(try await store.card(id)?.status == .inProgress) }
        let reports = try await store.piSessions(sessionIDs: ["working", "compacting", "delegating"])
        #expect(reports["working"]?.state.state == .known(.thinking))
        #expect(reports["delegating"]?.state.state == .known(.delegating))
        for id in ["working", "compacting", "delegating"] {
            #expect(try await store.piMessages(of: id).map(\.text) == ["关机前的工作"])
        }
    }

    @Test func 多台Mac按各自期限失效_同件并行去重_续期贯通读取与完整信封() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let workspace = Workspace(services: app.services), store = app.services.store
        let task = try await workspace.createTask("两台 Mac 并行交付", in: Project.defaultID)
        let first = try await store.createTask("实现", under: task.id)
        let second = try await store.createTask("审查", under: task.id)
        let a = try await app.runtimeRecorder(on: "mac-a", boot: "test-boot")
        try await a.update(sessionID: "a", state: .thinking, title: "实现", subagents: [
            PiSubagentState(name: "builder", role: "工程师", phase: .known(.running)),
        ])
        try await store.bindSession("a", to: first.id)
        clock.advance(.seconds(240))
        let b = try await app.runtimeRecorder(on: "mac-b", boot: "test-boot")
        try await b.update(sessionID: "b", state: .delegating, title: "审查", subagents: [
            PiSubagentState(name: "reviewer", role: "审查员", phase: .known(.running)),
        ])
        try await store.bindSession("b", to: second.id)
        func now() async throws -> CueNow {
            CueNow(try await CueDigest.read(from: store), at: .always(at: clock.now), local: .init(waiting: nil, here: nil))
        }
        let snapshot = try await now()
        #expect(snapshot.advancing == 1 && snapshot.tally.moving == 1 && snapshot.subagents == 2)
        let aExpires = snapshot.at + 360
        let onlyB = snapshot.shown(at: aExpires)
        #expect(onlyB.tally.moving == 1 && onlyB.tally.delegating == 1 && onlyB.subagents == 1)
        #expect(onlyB.items.first?.kind == .delegating)
        let expired = snapshot.shown(at: snapshot.at + 600)
        #expect(expired.tally.moving == 0 && expired.subagents == 0 && expired.advancing == 1 && expired.isLive)
        #expect(snapshot.nextShownChange(after: snapshot.at) == aExpires)

        clock.advance(.seconds(360))
        let fresh = try await now()
        #expect(fresh.tally == onlyB.tally && fresh.subagents == onlyB.subagents)
        let reading = CueReading(store: store, widget: false)
        let progressed = DispatchSemaphore(value: 0)
        let observe = Task.detached {
            defer { progressed.signal() }
            var updates = reading.updates().makeAsyncIterator()
            let before = try await updates.next()
            clock.advance(.seconds(1))
            try await store.recordMacPresence(host: "mac-b", bootID: "test-boot") { true }
            let renewed = try await updates.next()
            return (before, renewed)
        }
        // 界面队列被占住时，共享事实的订阅也必须能收到续期；不以 CueFeed/Observations 给出新值为前提。
        let completed = Self.holdUI(until: progressed)
        #expect(completed)
        if !completed { observe.cancel() }
        let observed = try await observe.value
        let before = try #require(observed.0), renewal = try #require(observed.1)
        let old = CueNow(before.digest, at: .always(at: clock.now), local: .init(waiting: nil, here: nil))
        let renewed = CueNow(renewal.digest, at: .always(at: clock.now), local: .init(waiting: nil, here: nil))
        #expect(!old.same(as: renewed))

        for index in 0..<7 {
            clock.advance(.seconds(1))
            let task = try await workspace.createTask("并行交付含中文任务名称与归属第\(index)项", in: Project.defaultID)
            let recorder = try await app.runtimeRecorder(on: "extra-\(index)")
            try await recorder.update(sessionID: "extra-\(index)", state: .thinking, title: task.title)
            try await store.bindSession("extra-\(index)", to: task.id)
        }
        _ = try await store.addCueMessage(.cue, text: "需要确认", ask: try CueAsking(.rule, action: "推送全部并行交付的修复", rule: "提交前需要确认全部并行修改已经验收并通过检查"))
        _ = try await store.updateCueProfile { profile in
            profile.hostID = "mac-b"
            profile.enabledAt = clock.now
        }
        try await store.setCueState(.tool, detail: "read · Sources/Runtime/SharedRuntimeProjection.swift")
        let full = try await now()
        let quotas = (0..<4).map { index in
            CueActivityState.Quota(account: "订阅账户 user\(index)@example.com", windows: [
                .init(name: "5 小时", left: 0.75, level: .roomy, resetsAt: clock.now + 3600, near: false),
                .init(name: "本周", left: 0.25, level: .tight, resetsAt: clock.now + 86400, near: true),
            ])
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let content = CueActivityState(now: full, quotas: quotas)
        let state = try JSONSerialization.jsonObject(with: encoder.encode(content))
        let envelope: [String: Any] = ["aps": ["timestamp": Int(full.at.timeIntervalSince1970), "event": "update", "content-state": state,
                                              "stale-date": Int(full.nextShownChange(after: full.at)!.timeIntervalSince1970)]]
        let bytes = try JSONSerialization.data(withJSONObject: envelope).count
        print("RUNTIME complete APNs update envelope: \(bytes) bytes; 8 active hosts, 8 works, 8 visible items, 4 quota accounts/8 windows")
        #expect(full.items.count == 8 && full.isBusy && full.first?.detail != nil && bytes <= 4096)
        let decoded = try JSONDecoder().decode(CueActivityState.self, from: JSONEncoder().encode(content))
        #expect(decoded.now.shown(at: clock.now + 601).tally.moving == 0 && decoded.now.shown(at: clock.now + 601).isLive)
        var expiration = reading.updates().makeAsyncIterator()
        _ = try #require(try await expiration.next())
        await clock.waitForSleeper()
        clock.advance(.seconds(601))
        let reread = try #require(try await expiration.next())
        let timedOut = CueNow(reread.digest, at: .always(at: clock.now), local: .init(waiting: nil, here: nil))
        #expect(timedOut.tally.moving == 0 && timedOut.subagents == 0 && timedOut.unconfirmed && timedOut.isLive)
    }

    @Test func 同件事的拍板到期不遮住另一台仍在跑的会话_后续快照与即时读取相同() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing), workspace = Workspace(services: app.services), store = app.services.store
        let task = try await workspace.createTask("并行推进", in: Project.defaultID)
        let askLeaf = try await store.createTask("发布", under: task.id)
        let runningLeaf = try await store.createTask("测试", under: task.id)
        let a = try await app.runtimeRecorder(on: "mac-a", boot: "test-boot")
        try await a.update(sessionID: "asking", state: .waitingForUser, title: "发布", question: PiQuestion(promptID: "p", kind: .confirm, text: "推送吗？"))
        try await store.bindSession("asking", to: askLeaf.id)
        clock.advance(.seconds(240))
        let b = try await app.runtimeRecorder(on: "mac-b", boot: "test-boot")
        try await b.update(sessionID: "running", state: .thinking, title: "测试")
        try await store.bindSession("running", to: runningLeaf.id)
        func now() async throws -> CueNow {
            CueNow(try await CueDigest.read(from: store), at: .always(at: clock.now), local: .init(waiting: nil, here: nil))
        }
        let snapshot = try await now()
        #expect(snapshot.tally.asks == 1 && snapshot.advancing == 0)
        let afterA = snapshot.shown(at: clock.now + 360)
        #expect(afterA.tally.asks == 0 && afterA.advancing == 1 && afterA.tally.moving == 1)
        #expect(afterA.items.count == 1 && afterA.items.first?.kind == .running && afterA.items.first?.name == "并行推进")
        clock.advance(.seconds(360))
        let fresh = try await now()
        #expect(fresh.tally == afterA.tally && fresh.items.map(\.since) == afterA.items.map(\.since))
        #expect(afterA.shown(at: clock.now + 240).tally.moving == 0)
    }

    @Test func 同一会话绑两任务只数一次子代理_一件拍板及解除不漏另一件_到期归零() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing), workspace = Workspace(services: app.services), store = app.services.store
        let first = try await workspace.createTask("第一件", in: Project.defaultID)
        let sharedLeaf = try await store.createTask("共用会话", under: first.id)
        let gateLeaf = try await store.createTask("发布确认", under: first.id)
        let second = try await workspace.createTask("第二件", in: Project.defaultID)
        let secondShared = try await store.createTask("共用会话", under: second.id)
        let secondGate = try await store.createTask("另一处确认", under: second.id)
        let recorder = try await app.runtimeRecorder(on: "worker", boot: "test-boot")
        try await recorder.update(sessionID: "shared", state: .thinking, title: "共享会话", subagents: [
            PiSubagentState(name: "builder", role: "工程师", phase: .known(.running)),
        ])
        try await store.bindSession("shared", to: sharedLeaf.id)
        try await store.bindSession("shared", to: secondShared.id)
        func now() async throws -> CueNow {
            CueNow(try await CueDigest.read(from: store), at: .always(at: clock.now), local: .init(waiting: nil, here: nil))
        }
        let both = try await now()
        #expect(both.advancing == 2 && both.tally.moving == 2 && both.subagents == 1)
        clock.advance(.seconds(240))
        let gate = try await app.runtimeRecorder(on: "gate-host", boot: "test-boot")
        let question = PiQuestion(promptID: "p", kind: .confirm, text: "发布吗？")
        try await gate.update(sessionID: "gate", state: .waitingForUser, title: "发布确认", question: question)
        try await store.bindSession("gate", to: gateLeaf.id)
        let held = try await now()
        #expect(held.advancing == 1 && held.subagents == 1)
        try await gate.update(sessionID: "gate", state: .settled)
        let released = try await now()
        #expect(released.advancing == 2 && released.subagents == 1)
        try await gate.update(sessionID: "other-gate", state: .waitingForUser, title: "另一处确认", question: question)
        try await store.bindSession("other-gate", to: secondGate.id)
        let otherHeld = try await now()
        #expect(otherHeld.advancing == 1 && otherHeld.subagents == 1)
        try await gate.update(sessionID: "other-gate", state: .settled)
        #expect(try await now().subagents == 1)
        try await gate.update(sessionID: "gate", state: .waitingForUser, question: question)
        let snapshot = try await now()
        #expect(snapshot.shown(at: clock.now + 360).subagents == 0)
        #expect(snapshot.shown(at: clock.now + 600).advancing == 2 && snapshot.shown(at: clock.now + 600).subagents == 0)
        #expect(snapshot.shown(at: clock.now + 600).isLive && !snapshot.shown(at: clock.now + 600).hasConfirmedActivity)
    }

    nonisolated private static func holdUI(until signal: DispatchSemaphore) -> Bool {
        signal.wait(timeout: .now() + Double(conditionBudget.components.seconds)) == .success
    }

    #if os(macOS)
    @Test func 重开App只对账真实进程_无证据的旧报告不获得确认() async throws {
        let app = TestApp(), workspace = Workspace(services: app.services), store = app.services.store
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID, boot: SystemBoot.id!)
        let process = Process(), input = Pipe()
        process.executableURL = URL(filePath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        defer { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
        let identity = try #require(PiProcess.running(pid: process.processIdentifier))
        for (id, evidence) in [("alive", identity), ("unknown", nil)] {
            let task = try await workspace.createTask(id, in: Project.defaultID)
            let writer = evidence == nil ? PiStateRecorder(store: store, hostID: TestApp.hostID, bootID: nil) : recorder
            try await writer.update(sessionID: id, state: .compacting, title: id, hosted: true, process: evidence)
            try await store.bindSession(id, to: task.id)
        }
        _ = app.relaunch()
        try await app.services.resetPiState()
        #expect(identity.isRunning)
        let alive = try #require(try await store.piSessions(sessionIDs: ["alive"])["alive"]?.state)
        #expect(try await store.runtimeIsConfirmed(alive))
        #expect(alive.state == .known(.compacting))
        let unknown = try #require(try await store.piSessions(sessionIDs: ["unknown"])["unknown"]?.state)
        #expect(try await !store.runtimeIsConfirmed(unknown))
        #expect(unknown.state == .known(.compacting) && workspace.shown(unknown, delivery: nil).status == .unknown)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        try await app.services.resetPiState()
        #expect(try await store.piSessions(sessionIDs: ["alive"])["alive"]?.state.state == .known(.interrupted))
    }
    #endif
}
