#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealPiTests {
    /// 按第一句话起名（`SessionNameSuggestion`）走真实 Pi 的桥扩展：用会话所在 provider 里最便宜的模型（假模型里是 echo-b），
    /// 交的是第一句话；只回不写，写回走改名（扩展里即 Pi 的改名接口），会话名随即上报。
    @Test func theSessionNamesItselfFromItsFirstMessageWithTheCheapestModelOfItsProvider() async throws {
        try await withRig { _, bridge, s in
            #expect(bridge.canNameItself(s.id))
            try await bridge.send(PiMessage(text: "帮我看看登录页为什么白屏"), to: s.id)
            try await eventually("第一句话上报") { bridge.sessions.first?.firstMessage != nil }
            let name = try await bridge.suggestName(for: s.id)
            #expect(name == "echo-b：帮我看看登录页为什么白屏")
            #expect(bridge.sessions.first?.name == nil, "只起名，不写回")
            try await bridge.configure(PiConfig(name: name), in: s.id)
            try await eventually("写回成会话名") { bridge.sessions.first?.name == name }
        }
    }
}
#endif
