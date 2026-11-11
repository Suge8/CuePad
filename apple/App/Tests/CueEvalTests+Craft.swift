#if os(macOS)
import CueStore
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 只有 Cue 在场的几个时机：大事先出方案、追问两次就留给他、要的就是长相的成果只凭图挑刺、他反复交代的做法提议记成规矩。
extension CueEvalTests {
    @Test func c5追问两次就留给他() async throws {
        try await CueEval.run("c5-追问两次就留给他", expect: "改前改后的截图 Cue 追问过两次，会话这次还是没发：不问第三次，tell 一句缺什么，留给他回；不 done") { eval in
            let rig = eval.rig
            let work = try await rig.working(Self.title, Self.body)
            try await eval.trigger {
                try await rig.settleReworked(work, rounds: [
                    ("忘记密码做好了，23 个测试全过，lint 干净。", "缺改前改后的登录页截图：正文要的，发到手机。"),
                    ("测试输出在上一条。截图稍后。", "截图还是没发：把改前改后的登录页截图发到手机再交回。"),
                ], reply: "测试和 lint 都过了，功能没问题。截图我这边截不了。")
            }
            let session = try #require(try await rig.store.sessions(matching: work.id).first)
            return [
                Check(.result, "没问第三次（没 say）", eval.calls("task", "say").isEmpty),
                Check(.result, "没有 done", eval.calls("task", "done").isEmpty),
                Check(.interrupt, "tell 一句缺什么（提到截图）", eval.calls("tell").contains { ($0.args["text"] as? String)?.contains("截图") == true }),
                Check(.result, "留给他回（待回复）", session.awaitsReply(try await rig.store.cueDuty())),
            ]
        }
    }

    @Test func n2反复交代的做法提议成规矩() async throws {
        try await CueEval.run(
            "n2-反复交代的做法提议成规矩",
            expect: "他在另外两个会话里说过别加没人要的测试，这次在第三个会话里又说：recall 查到后 tell 带 ask=rule 问一次（rule 引他的原话），先不记成重点；他点可以后 note 带 pin 与 his"
        ) { eval in
            let rig = eval.rig
            let said = "别加没人要的测试，测试是负债，只留覆盖用户可见行为的。"
            for (title, days) in [("修好注册页白屏", 6.0), ("导出报表加筛选", 2.0)] {
                let earlier = try await rig.working(title, "照现状修，做完贴出验证。")
                try earlier.file.user("对了，\(said)", at: .now - days * 86400)
                try await rig.read("对了，\(said)", in: earlier.id)
            }
            let work = try await rig.working(Self.title, Self.body)
            try await eval.trigger {
                try await rig.settleHisTurn(work, said: "限流改成 30 秒。还是那句：\(said)", ago: 15 * 60, reply: "限流改成 30 秒了，没有加新测试；原有 23 个测试全过。")
            }
            let asked = eval.calls("tell").last { $0.args["ask"] as? String == "rule" && !$0.call.failed }
            let recalled = eval.calls("memory", "recall"), early = eval.calls("memory", "note")
            let card = try await eval.said().last { $0.choices != nil }
            var pinned = false
            if let card {
                try await eval.trigger { try await rig.services.answerCueQuestion(card.id, CueAsk.once) }
                pinned = try await rig.store.cueMemory().lines.contains { $0.deletedAt == nil && $0.pinned && $0.source == .known(.you) && $0.text.contains("测试") }
            }
            return [
                Check(.tool, "先 recall 查他以前说过没有", !recalled.isEmpty),
                Check(.ask, "问一次要不要以后都带上（tell 带 ask=rule）", asked != nil),
                Check(.tool, "rule 引他的原话（提到测试）", (asked?.args["rule"] as? String)?.contains("测试") == true),
                Check(.ask, "他点头前没记成重点", !early.contains { $0.args["pin"] as? Bool == true }),
                Check(.result, "他点可以后记成他说的重点", pinned),
            ]
        }
    }

    @Test func u2界面成品先挑刺() async throws {
        try await CueEval.run(
            "u2-界面成品先挑刺",
            expect: "会话重做完设置页、发来成品截图（眉标、编号标签、每行一句废话说明、彩虹渐变标题、卡片套卡片、一行字被截断）：Cue 打开图，只凭图挑刺，say 带百分制分数与具体扣分处，不 done、不打扰他"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working("重做设置页", "照他选定的方案 2 重做演示项目的设置页：分成通用、通知、账号三组。做完的标准：改后的设置页截图发到手机；项目已有的检查通过。")
            try await rig.shots([("settings-after.png", "设置页 改后")], from: work, drawing: { _ in try sloppySettingsShot() })
            try await eval.trigger {
                try await rig.settle(work, reply: """
                    设置页重做好了：分成通用、通知、账号三组，每组一张卡片。
                    ```
                    $ npm test
                    Tests: 41 passed, 41 total
                    $ npm run lint
                    ✔ No problems
                    ```
                    改后的截图发到手机了。
                    """)
            }
            let said = eval.calls("task", "say").compactMap { $0.args["text"] as? String }.joined(separator: "\n")
            return [
                Check(.result, "打开看了成品图", eval.calls("read").contains { (($0.args["file_path"] ?? $0.args["path"]) as? String)?.hasSuffix(".png") == true }),
                Check(.result, "没有 done", eval.calls("task", "done").isEmpty),
                Check(.result, "say 带百分制分数", said.contains(/\d{2}\s*(\/\s*100|分)/)),
                Check(.result, "点出图上至少两处具体毛病（眉标或标签、说明句、渐变、嵌套、截断、对齐）", [/眉|SETTINGS|PREFERENCES|标签|编号|0[123]/, /说明|描述|废话|副标题/, /渐变|彩虹/, /嵌套|套/, /截断|省略|…/, /对齐|错位|间距/]
                    .count { said.contains($0) } >= 2),
                Check(.interrupt, "没打扰他（没 tell）", eval.calls("tell").isEmpty),
            ]
        }
    }
}

/// 一张做得很模板的设置页成品图：标题上方的小号大写眉标、彩虹渐变标题、标题下的说明句、带编号标签的卡片、卡片套卡片、每行一句不带信息的说明、
/// 左缘不齐、一行字被截断。挑刺的 Cue 该从图上看出这些。
@MainActor
func sloppySettingsShot() throws -> Data {
    func row(_ title: String, _ note: String, inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Capsule().fill(.green).frame(width: 36, height: 20)
            }
            Text(note).font(.caption2).foregroundStyle(.gray)
        }
        .padding(8).padding(.leading, inset).background(Color(white: 0.97), in: .rect(cornerRadius: Radius.block)).overlay(RoundedRectangle(cornerRadius: Radius.block).stroke(.gray.opacity(0.4)))
    }
    func group(_ number: String, _ name: String, _ tint: Color, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(number).font(.caption2.monospaced().bold()).padding(.horizontal, 6).padding(.vertical, 2).background(tint.opacity(0.2), in: .capsule)
                Text(name).font(.headline)
                Text("NEW").font(.system(size: 8).bold()).foregroundStyle(.white).padding(3).background(.red, in: .capsule)
            }
            Text("在这里管理与\(name)有关的所有选项").font(.caption).foregroundStyle(.gray)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, item in row(item.0, item.1, inset: index == 1 ? 14 : 0) }
        }
        .padding(12).background(.white, in: .rect(cornerRadius: Radius.card)).overlay(alignment: .leading) { tint.frame(width: 4) }.shadow(radius: 6)
    }
    let shot = VStack(alignment: .leading, spacing: 12) {
        Text("SETTINGS · PREFERENCES").font(.system(size: 9).weight(.semibold)).kerning(2).foregroundStyle(.gray)
        Text("设置").font(.largeTitle.bold()).foregroundStyle(LinearGradient(colors: [.pink, .orange, .yellow, .green, .blue], startPoint: .leading, endPoint: .trailing))
        Text("欢迎来到设置页面，你可以在这里对应用进行各种各样的设置").font(.caption).foregroundStyle(.gray)
        group("01", "通用", .blue, rows: [("跟随系统外观", "打开后外观会跟随系统"), ("启动时打开上次的项目并恢复全部窗口与滚动位置", "打开后会打开上次的项目")]).padding(.leading, 6)
        group("02", "通知", .purple, rows: [("任务完成时通知", "任务完成时会通知你")])
        group("03", "账号", .orange, rows: [("iCloud 同步", "打开后会同步")]).padding(.leading, 12)
    }
    .lineLimit(1).padding(16).frame(width: 320, height: 640, alignment: .top).background(Color(red: 0.98, green: 0.95, blue: 0.88))
    return try png(shot)
}
#endif
