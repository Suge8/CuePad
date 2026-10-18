#if os(macOS)
import CueStore
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 在 Cue 页输入框的选择器里给值班的 Cue 换脑子，按用户看得到的写：换模型、思考强度，Cue 下一轮就用新的，前面说的话它还记得，
/// 对话里没有"换了新上下文"的分隔；换 Agent 要换大脑，对话里出现那条分隔（点开是交接备忘）。
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

    /// 对话里"换了新上下文"的分隔（交接备忘）。
    private func boundaries(_ rig: CueHostTests.Rig) async throws -> [CueMessage] {
        try await CueThread.read(from: rig.store, showsSteps: true).rows.compactMap { if case .renewed(let handoff) = $0 { handoff } else { nil } }
    }

    @Test func 选别的模型和思考强度_Cue下一轮就用新的_前面说的话还记得_没有换新分隔() async throws {
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
        #expect(try await boundaries(rig).isEmpty)
        await rig.stop()
    }

    @Test func 换Agent_Cue先写交接_对话里出现换新分隔() async throws {
        let rig = try await CueHostTests.Rig()
        try await say("暗号是 PAPAYA", to: rig, expecting: "收到：暗号是 PAPAYA")

        try await rig.services.updateCue {  // 模型菜单里 Codex 那组标着默认的那项
            $0.runtime = .known(.codex)
            $0.model = nil
        }

        try await eventually("出现换新分隔") { try await !self.boundaries(rig).isEmpty }
        let rows = try await CueThread.read(from: rig.store, showsSteps: true).rows
        let said = try #require(rows.firstIndex { if case .you(let message) = $0 { message.text == "暗号是 PAPAYA" } else { false } })
        let boundary = try #require(rows.firstIndex { if case .renewed = $0 { true } else { false } })
        #expect(boundary > said)
        await rig.stop()
    }
}
#endif
