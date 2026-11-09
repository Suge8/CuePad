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
