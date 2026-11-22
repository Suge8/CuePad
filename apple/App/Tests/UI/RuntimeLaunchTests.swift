#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct RuntimeLaunchTests {
    @Test func Mac重开_第一帧里本机的会话就是确定的说法() async throws {
        let app = TestApp(), store = app.services.store
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID, boot: SystemBoot.id!)
        let process = Process(), input = Pipe()
        process.executableURL = URL(filePath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let identity = try #require(SessionProcess.running(pid: process.processIdentifier))
        try await recorder.update(sessionID: "resting", state: .settled, title: "歇着的", hosted: true)
        try await recorder.update(sessionID: "gone", state: .thinking, title: "做到一半的", hosted: true, process: identity)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        try await store.recordMacPresence(host: TestApp.hostID) { false }

        let services = app.relaunch()
        let first = Dictionary(uniqueKeysWithValues: services.liveSessions.items.map { ($0.state.sessionID, $0) })
        let workspace = Workspace(services: services)
        let resting = workspace.shown(try #require(first["resting"])), gone = workspace.shown(try #require(first["gone"]))
        #expect(resting.status != .unknown() && resting.label != "状态未确认", "\(resting.label)")
        #expect(gone.status == .interrupted, "\(gone.label)")
        #expect(try await store.macOnline(TestApp.hostID))
    }
}
#endif
