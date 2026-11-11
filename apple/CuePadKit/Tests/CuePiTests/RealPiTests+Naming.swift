#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealPiTests {
    @Test func theSessionNamesItselfFromItsFirstMessageWithTheCheapestModelOfItsProvider() async throws {
        try await withRig { _, bridge, s in
            #expect(bridge.canNameItself(s.id))
            try await bridge.send(SessionMessage(text: "帮我看看登录页为什么白屏"), to: s.id)
            try await eventually("第一句话上报") { bridge.sessions.first?.firstMessage != nil }
            let name = try await bridge.suggestName(for: s.id)
            #expect(name == "echo-b：帮我看看登录页为什么白屏")
            #expect(bridge.sessions.first?.name == nil, "只起名，不写回")
            try await bridge.configure(SessionConfig(name: name), in: s.id)
            try await eventually("写回成会话名") { bridge.sessions.first?.name == name }
        }
    }

    /// 扩展回模型的原话，CuePad 取第一个不空的行、去掉首尾空白、截到上限；整理完是空的就报起不出
    @Test(arguments: [
        ("\n  修登录页白屏的问题，顺便把注册页、找回密码页和设置页的同类问题一起排查掉，再看首页  \n第二行", "修登录页白屏的问题，顺便把注册页、找回密码页和设置页的同类问题一起排查掉"),
        ("  \n \n", nil),
    ])
    func theModelsRawReplyIsCleanedByCuePadAndAnEmptyOneIsAFailure(reply: String, expected: String?) async throws {
        try await withRig { pi, bridge, s in
            pi.model.onTitle { _ in .say(reply) }
            try await bridge.send(SessionMessage(text: "帮我看看登录页为什么白屏"), to: s.id)
            try await eventually("第一句话上报") { bridge.sessions.first?.firstMessage != nil }
            if let expected {
                #expect(try await bridge.suggestName(for: s.id) == expected)
            } else {
                await #expect(throws: BridgeError.rejected("failed: empty title")) { try await bridge.suggestName(for: s.id) }
            }
        }
    }
}
#endif
