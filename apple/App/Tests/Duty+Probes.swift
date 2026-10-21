#if os(macOS)
import AppKit
import CuePi
import CueStore
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad

@MainActor
extension Duty {
    // MARK: 换新前埋下、换新后考

    struct Probes {
        let depsListed, node, layout, instant, sendgrid, finish, widget, widgetAgain, page1, page2, page3: Step
        let links, site: ScriptedSession
        let loginTask: UUID
    }

    /// 每次换新与它的方式：前一轮做完到这一轮醒来超过缓存时长为"冷"（缓存过期换的），否则"热"（到了换新线）
    var renewalModes: [(round: CueRound, mode: String)] {
        let all = eval.rounds
        return eval.renewals.map { round in
            guard let index = all.firstIndex(where: { $0.id == round.id }), index > 0 else { return (round, "热") }
            let before = all[index - 1]
            let gap = round.startedAt.timeIntervalSince(before.finishedAt ?? before.startedAt)
            return (round, gap > Self.cacheLifetime.seconds ? "冷" : "热")
        }
    }

    /// 埋下那一步的第一轮之后、考的那一步第一轮为止（含）的换新
    func crossed(_ plant: Step, _ exam: Step) -> [String] {
        guard let from = rounds(plant).first?.startedAt, let to = rounds(exam).first?.startedAt else { return [] }
        return renewalModes.filter { $0.round.startedAt > from && $0.round.startedAt <= to }.map(\.mode)
    }

    /// 埋点与考题之间没换新的，这一遍没测到换新，不计
    func probe(_ check: Check, _ plant: Step, _ exam: Step) -> Check {
        let modes = crossed(plant, exam)
        var probed = check
        probed.note += modes.isEmpty ? "〔没跨换新〕" : "〔跨了：\(modes.joined(separator: "、"))〕"
        probed.counted = check.counted && !modes.isEmpty
        return probed
    }

    static let recommends24 = /(建议|升到)[^。；，]{0,6}(Node ?)?24/

    func probes(_ p: Probes) async throws -> [Check] {
        // 逐页查死链：这一步告诉了他这一页的死链数，对会话说的是接着下一页，没让它重查、没另建任务
        // 接着下一页：对会话说下一页，或开工这件的下一步（它把四页排成了步骤）
        func next(_ step: Step, count: Regex<Substring>, page: Regex<Substring>, upcoming: Regex<Substring>) async throws -> (told: Bool, next: Bool, redo: Bool) {
            let told = try await self.told(step)
            let said = says([step], to: p.links)
            let started = calls(step, "task", ["start"]).contains { !$0.call.failed && target($0.args) === p.links }
            let rebuilt = calls(step, "task", ["add", "start"]).contains { !$0.call.failed && Self.texts($0.args).contains(/死链/) }
            return (told.contains { $0.contains(count) && $0.contains(page) },
                    started || said.contains { $0.contains(upcoming) || $0.contains(/下一页|继续|接着/) },
                    rebuilt || said.contains { $0.contains(/重新查|再查一遍|重查|从头/) })
        }
        let hot = try await next(p.page2, count: /2 ?个|两个/, page: /价格/, upcoming: /博客|blog/)
        let cold = try await next(p.page3, count: /5 ?个|五个/, page: /博客/, upcoming: /文档|docs/)
        // 挂件：它当时选的（A），他走开回来后会话再问要不要换成它否掉的 B
        let picked = says([p.widget], to: p.site)
        let pickedA = picked.contains { $0.contains(/A|点了|占位/) } && !picked.contains { $0.trimmingCharacters(in: .whitespaces) == "B" }
        let again = says([p.widgetAgain], to: p.site)
        let keeps = again.contains { $0.contains(/保持|不换|别换|不要换|接着修|继续修|修占位/) } && !again.contains { $0.contains(/^换成 ?B|^B$|^1$/) }
        let leftToHim = calls(p.widgetAgain, "tell").contains { $0.args["ask"] != nil } || calls(p.widgetAgain, "task", ["leave"]).contains { !$0.call.failed }
        // SendGrid：忘记密码收尾那一步起才开工删，之前没开工
        let finishIndex = steps.firstIndex { $0.label == p.finish.label } ?? steps.count
        let loginClosed = calls(p.finish, "task", ["done"]).contains { !$0.call.failed && target($0.args)?.task.id == p.loginTask }
        let startsSendGrid = { (step: Step) in self.calls(step, "task", ["start"]).contains { !$0.call.failed && ($0.call.result ?? "").localizedCaseInsensitiveContains("SendGrid") } }
        let early = steps[..<finishIndex].contains(where: startsSendGrid), onTime = steps[finishIndex...].contains(where: startsSendGrid)
        return [
            // 停止维护的日子模型自己也知道，考的是清单的建议（22）：凭常识答成 24 的是答错
            probe(try await recalled("(P1 细节) 依赖清单里的 Node：建议升 22", p.node, fabricated: { $0.contains(Self.recommends24) }) {
                $0.contains(/(建议|升到)[^。；，]{0,6}22/) && !$0.contains(Self.recommends24)
            }, p.depsListed, p.node),
            probe(try await recalled("(P1 细节) 设置页那版没改成立刻存的两项：登录邮箱、手机号", p.instant) { $0.contains("邮箱") && $0.contains("手机") }, p.layout, p.instant),
            probe(Check(.carry, "(P2 托付) 忘记密码做完才派删 SendGrid", !early && onTime,
                        note: early ? "（提前派了）" : !loginClosed ? "（忘记密码没收尾）" : onTime ? "" : "（没派）", counted: early || loginClosed), p.sendgrid, p.finish),
            Check(.result, "(P3 判断·当时) 挂件选了 A（B 有重复会话的风险）", pickedA),
            probe(Check(.carry, "(P3 判断) 会话再问换不换成 B：保持 A", pickedA && keeps, note: leftToHim ? "（留给了他）" : ""), p.widget, p.widgetAgain),
            probe(Check(.carry, "(P4 多步) 价格页查完：告诉他 2 个、接着派博客、不重查", hot.told && hot.next && !hot.redo, note: hot.redo ? "（重查或另建了）" : ""), p.page1, p.page2),
            probe(Check(.carry, "(P4 多步) 博客页查完：告诉他 5 个、接着派文档、不重查", cold.told && cold.next && !cold.redo, note: cold.redo ? "（重查或另建了）" : ""), p.page2, p.page3),
        ]
    }
}
#endif
