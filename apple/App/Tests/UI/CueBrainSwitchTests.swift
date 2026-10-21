#if os(macOS)
import CueStore
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 在 Cue 页输入框的选择器里给值班的 Cue 换脑子，按用户看得到的写：换模型、思考强度，Cue 下一轮就用新的，同一个会话里前面说的话它还记得；
/// 换名字（在系统提示里）要换大脑，新大脑的第一条输入带着对话视图，前面说的话照样接得上。
/// 选择器写设置走 `AppServices.updateCue`，写法照它的菜单项（`CueConfigControls`）；说话走 `Workspace.speak`。
/// 大脑是真的 Pi，模型是 `CueHostTests` 的假端点（看得到每一轮用的模型与强度）。
@MainActor
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"), .serialized, .timeLimit(.minutes(2)))
struct CueBrainSwitchTests {
    /// 在 Cue 页对它说一句，等它回一句含 `reply` 的话。
    private func say(_ text: String, to rig: CueHostTests.Rig, expecting reply: String) async throws {
        let workspace = Workspace(services: rig.services)
        workspace.cue.draft = ComposerDraft(text: text)
        await workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { try $0.stored(in: rig.store.files) }?.value
        try await rig.message(.cue, containing: reply)
    }

    @Test func 选别的模型和思考强度_Cue下一轮就用新的_前面说的话还记得() async throws {
        let rig = try await CueHostTests.Rig()
        try await say("暗号是 PAPAYA", to: rig, expecting: "收到：暗号是 PAPAYA")

        try await rig.services.updateCue {  // 模型菜单里 Pi 那组的 Fake Model 2
            $0.runtime = .known(.pi)
            $0.model = "fake/fake-model-2"
        }
        try await rig.services.updateCue { $0.effort = .known(.high) }  // 思考强度选"高"
        try await say("暗号是什么？", to: rig, expecting: "记得，暗号是 PAPAYA")

        let used = try #require(rig.model.requests.last)
        #expect(used.model == "fake-model-2" && used.effort == "high", "\(rig.model.requests)")
        await rig.stop()
    }

    @Test func 换名字_换了大脑_新大脑接上前面说的() async throws {
        let rig = try await CueHostTests.Rig()
        let first = try #require(rig.brainPIDs.first)
        try await say("暗号是 PAPAYA", to: rig, expecting: "收到：暗号是 PAPAYA")

        try await rig.services.updateCue { $0.name = "小满" }
        try await eventually("换了大脑") { rig.brainPIDs.count == 1 && rig.brainPIDs.first != first }
        try await say("暗号是什么？", to: rig, expecting: "从视图接上：暗号是 PAPAYA")
        await rig.stop()
    }
}
#endif
