#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealCodexHostedTests {
    @Test func aHostedSessionNamesItselfFromItsFirstMessageInATemporaryThread() async throws {
        try await withCodexRig { rig in
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-name", name: nil, model: nil, thinking: nil)
            #expect(rig.bridge.canNameItself(id))
            try await rig.bridge.send(PiMessage(text: "Fix the login page that renders blank after sign-in. Reply with OK only."), to: id)
            try await eventually("这一轮做完、第一句话上报") {
                rig.bridge.session(id: id).map { $0.state == .settled && $0.firstMessage != nil && rig.replies($0).last != nil } == true
            }
            let name = try await rig.bridge.suggestName(for: id)
            // 真模型的说法每次重录都可能变：只看起出了名字、没超长，不查用词
            #expect(!name.isEmpty && name.count <= SessionNameSuggestion.limit, "\(name)")
            #expect(rig.bridge.session(id: id)?.name == nil, "只起名，不写回")
            #expect(rig.bridge.sessions.map(\.id) == [id], "临时线程不是会话")
            try await rig.bridge.configure(PiConfig(name: name), in: id)
            let thread = try await rig.runtime.control(try #require(rig.runtime.tracked[id])).call("thread/read", ["threadId": .string(try #require(rig.bridge.session(id: id)).sessionID)])
            #expect(thread["thread"]?["name"]?.string == name, "写进了 Codex")
        }
    }
}
#endif
