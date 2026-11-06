#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealPiTests {
    /// 按第一句话起名（`SessionNameSuggestion`）走真实 Pi 的桥扩展：用会话所在 provider 里最便宜、标了价的模型（假模型里只有 echo-b），
    /// 交的是第一句话；只回名字不写，写回走改名，会话名随即上报。
    @Test func theSessionIsNamedFromItsFirstMessageByTheCheapestModelOfItsProvider() async throws {
        try await withRig { _, bridge, s in
            try await bridge.send(PiMessage(text: "帮我看看登录页为什么白屏"), to: s.id)
            try await eventually("第一句话上报") { bridge.sessions.first?.firstMessage != nil }
            let name = try await bridge.suggestName(for: s.id)
            #expect(name == "echo-b：帮我看看登录页为什么白屏")
            #expect(bridge.sessions.first?.name == nil, "只起名，不写回")
            try await bridge.configure(name: name, in: s.id)
            try await eventually("写回成会话名") { bridge.sessions.first?.name == name }
        }
    }
}
#endif
