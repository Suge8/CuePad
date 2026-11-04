#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 重开（上次退出时写下了离线）：画第一帧时读到的本机会话就是确定的说法——还在的照它记下的、进程已经没了的对账成被打断，
/// 不先闪一下"状态未确认"再变（`AppServices.launch`）。
struct RuntimeLaunchTests {
    @Test func Mac重开_第一帧里本机的会话就是确定的说法() async throws {
        let app = TestApp(), store = app.services.store
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID, boot: SystemBoot.id!)
        let process = Process(), input = Pipe()
        process.executableURL = URL(filePath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let identity = try #require(PiProcess.running(pid: process.processIdentifier))
        try await recorder.update(sessionID: "resting", state: .settled, title: "歇着的", hosted: true)
        try await recorder.update(sessionID: "gone", state: .thinking, title: "做到一半的", hosted: true, process: identity)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        try await store.recordMacPresence(host: TestApp.hostID) { false }  // 上次退出时写下的离线

        let services = app.relaunch()
        // 第一帧画的就是打开资料库时当场读到的这一页（`LiveSessions.init`），还没开始跟库
        let first = Dictionary(uniqueKeysWithValues: services.liveSessions.items.map { ($0.state.sessionID, $0) })
        let workspace = Workspace(services: services)
        let resting = workspace.shown(try #require(first["resting"])), gone = workspace.shown(try #require(first["gone"]))
        #expect(resting.status != .unknown() && resting.label != "状态未确认", "\(resting.label)")
        #expect(gone.status == .interrupted, "\(gone.label)")
        #expect(try await store.macOnline(TestApp.hostID))
    }
}
#endif
