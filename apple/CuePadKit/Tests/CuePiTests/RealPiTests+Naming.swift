#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealPiTests {
    /// 按第一句话起名（`SessionNameSuggestion`）走真实 Pi 的桥扩展：用会话所在 provider 里最便宜的模型（假模型里是 echo-b），
    /// 交的是第一句话，用 Pi 的改名接口写下，会话名随即上报；已有名字的会话不动。
    @Test func theSessionNamesItselfFromItsFirstMessageWithTheCheapestModelOfItsProvider() async throws {
        try await withRig { _, bridge, s in
            #expect(bridge.canNameItself(s.id))
            try await bridge.send(PiMessage(text: "帮我看看登录页为什么白屏"), to: s.id)
            try await eventually("第一句话上报") { bridge.sessions.first?.firstMessage != nil }
            try await bridge.nameItself(s.id)
            try await eventually("写下成会话名") { bridge.sessions.first?.name == "echo-b：帮我看看登录页为什么白屏" }

            try await bridge.configure(name: "我起的", in: s.id)
            try await eventually("改名") { bridge.sessions.first?.name == "我起的" }
            try await bridge.nameItself(s.id)
            #expect(bridge.sessions.first?.name == "我起的", "已有名字不动")
        }
    }
}
#endif
