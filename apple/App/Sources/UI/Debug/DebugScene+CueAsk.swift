#if DEBUG
import CueStore
import SwiftUI

/// `-CuePadCueAsk <proposals|push|one|four|evidence>`（配 `-CuePadScene cue` 与演示库）：把"等你"换成提问卡的一种样子，对照设计稿截图。
/// 演示库原有的两条先撤回，换上这一条：
/// - proposals：真实那张卡的同款——审美取舍，在三个方案里挑，推荐 1，点名每个方案一张手机截图；
/// - push：推送，有第二项（"以后……不用问"），不带图；
/// - one：部署到预发，只点名一张竖图；
/// - four：四张竖图（一行平分，缩略图变小）；
/// - evidence：合并，三张横图的证据，说明不带"："。
extension DebugScene {
    static func seedAsk(_ variant: String, store: CueStore, task: UUID?) async throws {
        for open in try await store.cueMessagesWaitingForYou() { try await store.endCueQuestion(open.id, .withdrawn) }
        func shots(_ items: [(name: String, title: String, look: String, png: Data)]) async throws -> [CueShot] {
            let folder = FileManager.default.temporaryDirectory.appending(path: "cue-ask-\(variant)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var shots: [CueShot] = []
            for item in items {
                let file = folder.appending(path: item.name)
                try item.png.write(to: file)
                let preview = try await store.addPreviews([(file, item.title)], sessionID: "ask-card-design")[0].preview
                shots.append(CueShot(preview: preview.id, look: item.look))
            }
            return shots
        }
        let proposals = [
            ("decision-sheet-iphone.png", "提问卡方案 1：决定单", "方案 1 决定单：大按钮占满一行", proposalPNG(.sheet)),
            ("in-thread-iphone.png", "提问卡方案 2：对话里问", "方案 2 对话里问：按钮贴输入框", proposalPNG(.thread)),
            ("slide-to-allow-iphone.png", "提问卡方案 3：郑重放行", "方案 3 郑重放行：滑过去才同意", proposalPNG(.slide)),
        ]
        let proposalTaste = try CueAsking(.taste, action: "按方案 1 决定单改提问卡")
        let (text, asking, shown): (String, CueAsking, [CueShot]) = switch variant {
        case "push":
            ("发言顺序修好了，测试都过了。要推送到 origin/main 吗？", try CueAsking(.push, action: "把发言顺序的修复推送到 origin/main"), [])
        case "one":
            ("1.4.2 在预发分支上打好包了，要部署到预发吗？", try CueAsking(.release, action: "把 1.4.2 部署到预发环境"), try await shots([
                ("staging-1.4.2.png", "预发 1.4.2", "预发 1.4.2 要上的四处改动", stagingPNG()),
            ]))
        case "four":
            ("提问卡我重画了四个方向，你挑一个。", proposalTaste, try await shots(
                proposals + [("drawer-iphone.png", "提问卡方案 4：抽屉", "方案 4 抽屉：从底下拉出来", proposalPNG(.drawer))]))
        case "evidence":
            ("修复验过了，三处证据都在。要合并进 main 吗？", try CueAsking(.merge, action: "把发言顺序的修复合并进 main"), try await shots([
                ("before-after.png", "改前改后", "改前改后的发言顺序", evidencePNG("改前 / 改后", tint: .indigo)),
                ("tests.png", "测试", "重连用例全部通过", evidencePNG("✔ 4 tests passed", tint: .green)),
                ("pressure.png", "压测", "6 人同时重连的压测", evidencePNG("p95 9ms", tint: .orange)),
            ]))
        default:
            ("提问卡我重画了三个方向，都放在下面这条里，你挑一个。我推荐 1：点一下就答完。", proposalTaste, try await shots(proposals))
        }
        _ = try await store.addCueMessage(.cue, text: text, ask: asking, shots: shown, task: task)
    }

    private enum Proposal { case sheet, thread, slide, drawer }

    /// 一个方案的手机效果图：一页对话，中间是那种样子的提问（各有一块显眼、彼此分得开的样子：黄卡大蓝钮、对话气泡、绿色滑轨、深色抽屉），
    /// 方形缩略图取细节最多的那一段（`DeliverableLooks.detailCrop`）也一眼认得出是哪张。
    private static func proposalPNG(_ proposal: Proposal) -> Data {
        let indigo = Color(red: 0.18, green: 0.29, blue: 0.62)
        let question = Text("可以推送 scheduler 的重连修复吗？").font(.system(size: 15, weight: .semibold))
        @ViewBuilder var middle: some View {
            switch proposal {
            case .sheet:
                VStack(alignment: .leading, spacing: 12) {
                    question
                    Text(CueAsk.once).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 56).background(indigo, in: .capsule)
                    Text("以后「圆桌」里推送代码不用问").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity)
                }
                .padding(18).background(Color(red: 0.98, green: 0.88, blue: 0.55), in: .rect(cornerRadius: 22))
            case .thread:
                VStack(alignment: .trailing, spacing: 10) {
                    question.padding(14).background(Color(white: 0.9), in: .rect(cornerRadius: 18)).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(["以后不用问", CueAsk.once], id: \.self) { choice in
                        Text(choice).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 22).padding(.vertical, 14).background(Color(red: 0.2, green: 0.55, blue: 0.95), in: .capsule)
                    }
                }
            case .slide:
                VStack(spacing: 18) {
                    question
                    Capsule().fill(Color(red: 0.2, green: 0.7, blue: 0.4)).frame(height: 72)
                        .overlay(alignment: .leading) { Circle().fill(.white).frame(width: 60, height: 60).padding(6) }
                        .overlay { Text("滑过去，可以 ›").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white) }
                }
            case .drawer:
                VStack(spacing: 14) {
                    Capsule().fill(.white.opacity(0.5)).frame(width: 44, height: 5)
                    question.foregroundStyle(.white)
                    Text(CueAsk.once).font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 48).background(.white, in: .capsule)
                }
                .padding(18).background(Color(white: 0.15), in: .rect(cornerRadius: 26))
            }
        }
        let view = VStack(alignment: .leading, spacing: 12) {
            HStack { Text("9:41").font(.system(size: 13, weight: .semibold)); Spacer() }
            Text("Cue").font(.system(size: 17, weight: .semibold))
            Text("• 重连后保留原来的轮次").font(.system(size: 12))
            Spacer()
            middle
            Spacer()
            Capsule().fill(Color(white: 0.93)).frame(height: 36).overlay(alignment: .leading) { Text("对 Cue 说").font(.system(size: 12)).foregroundStyle(.gray).padding(.leading, 14) }
        }
        .padding(16).frame(width: 320, height: 696).background(.white).foregroundStyle(.black)
        return render(view)
    }

    private static func stagingPNG() -> Data {
        let view = VStack(alignment: .leading, spacing: 10) {
            Text("预发 1.4.2").font(.system(size: 22, weight: .bold)).padding(.top, 40)
            Text("staging.roundtable.app · 今天 10:12").font(.system(size: 11)).foregroundStyle(.gray)
            ForEach([("修好", "同一时刻入座按座位号排"), ("修好", "断线重连后保留发言轮次"), ("改进", "README 换成新截图"), ("改进", "发言计时到点会轻震一下")], id: \.1) { tag, line in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tag).font(.system(size: 10)).foregroundStyle(.indigo)
                    Text(line).font(.system(size: 13))
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: .rect(cornerRadius: 10))
            }
            Spacer()
        }
        .padding(18).frame(width: 320, height: 640).background(Color(white: 0.95)).foregroundStyle(.black)
        return render(view)
    }

    private static func evidencePNG(_ headline: String, tint: Color) -> Data {
        let view = Text(headline).font(.system(size: 40, weight: .heavy)).foregroundStyle(tint)
            .frame(width: 640, height: 360).background(Color(white: 0.97))
        return render(view)
    }
}
#endif
