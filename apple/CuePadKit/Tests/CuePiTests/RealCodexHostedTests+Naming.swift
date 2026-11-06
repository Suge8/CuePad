#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealCodexHostedTests {
    /// 托管会话按第一句话起名（`CodexRuntime+Naming`）：在它自己的 app-server 里开用完不留的临时线程、真模型回一个短名，
    /// `thread/name/set` 写回；临时线程不冒成会话（它的钩子关着）。
    @Test func aHostedSessionNamesItselfFromItsFirstMessageInATemporaryThread() async throws {
        try await withCodexRig { rig in
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-name", name: nil, model: nil, thinking: nil)
            #expect(rig.bridge.canNameItself(id))
            try await rig.bridge.send(PiMessage(text: "Fix the login page that renders blank after sign-in. Reply with OK only."), to: id)
            try await eventually("这一轮做完、第一句话上报") {
                rig.bridge.session(id: id).map { $0.state == .settled && $0.firstMessage != nil && rig.replies($0).last != nil } == true
            }
            try await rig.bridge.nameItself(id)
            let name = try #require(rig.bridge.session(id: id)?.name)
            #expect(name.count <= 36 && name.lowercased().contains("login"), "\(name)")
            #expect(rig.bridge.sessions.map(\.id) == [id], "临时线程不是会话")
            let thread = try await rig.runtime.control(try #require(rig.runtime.tracked[id])).call("thread/read", ["threadId": .string(try #require(rig.bridge.session(id: id)).sessionID)])
            #expect(thread["thread"]?["name"]?.string == name, "写进了 Codex")
        }
    }
}
#endif
