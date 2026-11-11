#if os(macOS)
import CueStore
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 做事的标准（`CuePrompt.craft`）落到派活与跟进上的三处：大事先调研、小活不收口、给人看的成果由 Cue 只凭图挑刺。
extension CueEvalTests {
    @Test func r2架构先调研() async throws {
        try await CueEval.run("r2-架构先调研", expect: "他要把各页各存一份的数据统一成一个数据层（架构、难改回）：直接开工，正文写明这一轮只出方案、不实现，要查全代码、核实一手来源、做实验验证；回复一句") { eval in
            try await eval.trigger { try await eval.rig.say("演示项目现在每个页面各自拉数据、各存一份，经常对不上。统一成一个数据层，你看怎么做合适") }
            let reply = try await eval.reply(), body = Self.body(eval.calls("task", "add"))
            return [
                Check(.result, "开工（开出了会话）", eval.rig.app.host.calls.contains { if case .open = $0 { true } else { false } }),
                Check(.result, "正文写明这一轮只出方案、不实现", body?.contains(/只出方案|不实现|不要?改|不动手|先不/) == true),
                Check(.result, "正文要它查实（一手来源、实验或最佳实践）", body?.contains(/一手|联网|实验|最佳实践/) == true),
                Check(.result, "正文要它标明没查实的", body?.contains(/未确认|没查实|没验证/) == true),
                Check(.interrupt, "回复一两句", reply.map { sentences($0.text) <= 2 } == true),
                Check(.ask, "没发等你", try await eval.said().allSatisfy { $0.choices == nil }),
            ]
        }
    }

    @Test func c3小活直接做完() async throws {
        try await CueEval.run("c3-小活直接做完", expect: "改 README 里一条命令的小活带证据交回：不收口、不挑刺，直接 done") { eval in
            let work = try await eval.rig.working("README 安装命令换成 pnpm", "README 的安装一节把 npm install 换成 pnpm install。做完的标准：贴出改动的 diff。")
            try await eval.trigger {
                try await eval.rig.settle(work, reply: """
                    改好了，README 安装一节一处：
                    ```diff
                    -npm install
                    +pnpm install
                    ```
                    别处没有这条命令（rg 'npm install' 只此一处）。
                    """)
            }
            return [
                Check(.result, "done 了", eval.calls("task", "done").contains { !$0.call.failed }),
                Check(.result, "没让它收口（没 say）", eval.calls("task", "say").isEmpty),
                Check(.interrupt, "没另外 tell", eval.calls("tell").isEmpty),
            ]
        }
    }

    @Test func c4他说过不用收口() async throws {
        try await CueEval.run("c4-他说过不用收口", expect: "他交代过交回的代码不用再让会话复查收口：默认被他的规矩盖过，证据充分就直接 done，不 say") { eval in
            let rig = eval.rig
            try await eval.trigger { try await rig.say("以后会话交回的代码改动，证据够了就直接算做完，不用再让它复查收口一遍") }  // Cue 记下并标为重点
            let work = try await rig.working(Self.title, Self.body)
            try await rig.shots([("登录页改前改后.png", "登录页 忘记密码 改前改后")], from: work, drawing: { _ in try loginShot() })
            try await eval.trigger { try await rig.settle(work, reply: Self.doneReply) }
            return [
                Check(.result, "done 了", eval.calls("task", "done").contains { !$0.call.failed }),
                Check(.result, "没让它收口（没 say）", eval.calls("task", "say").isEmpty),
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
