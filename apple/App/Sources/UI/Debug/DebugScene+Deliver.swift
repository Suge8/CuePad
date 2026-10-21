#if DEBUG
import CueStore
import SwiftUI

/// 演示库里 Cue 页的结果卡（`seedCue` 里调）：会话发来的不止最终成果，结果卡只挂 Cue 做完时点名的那几张——
/// "落地页深浅两版"会话发了方案稿与最终版浅深两份网页，结果卡只挂最终版两份（左右翻）；
/// "修好登录页的键盘遮挡"发了修复前、中途一版与修复后，结果卡只挂修复前与修复后；
/// "重做定价区"中途 Cue 核对过一批（网页、PDF、横图与 Markdown 四份），那句话不挂图，四份在会话页里。README 那件做完没点名图（`seedCue`），
/// "等你"里的推送点名了部署会话发来的截图与测试报告（`seedCue`）。
extension DebugScene {
    static func seedDeliveries(_ store: CueStore) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cuepad-demo-deliver", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func file(_ name: String, _ data: Data) throws -> URL {
            let url = directory.appending(path: name)
            try data.write(to: url)
            return url
        }

        let landing = try await store.createTask("落地页深浅两版")
        try await store.linkCard(landing.id, toSession: "landing")
        _ = try await store.addPreviews([(try file("draft-hero.png", widePNG()), "方案稿：首屏三档并排")], sessionID: "landing")
        let pages = try await store.addPreviews([
            (try file("final-light.html", Data(pricingPage.utf8)), "最终版浅色：定价页首屏"),
            (try file("final-dark.html", Data(pricingPage.replacing("</style>", with: darkPricing + "</style>").utf8)), "最终版深色：定价页首屏"),
        ], sessionID: "landing").map(\.preview)
        _ = try await store.finishTask(
            landing.id, evidence: ["浅色深色各一版，按钮对比度都过了 4.5:1"],
            shots: [CueShot(preview: pages[0].id, look: "浅色：专业档描边是推荐"), CueShot(preview: pages[1].id, look: "深色：按钮对比度够")])

        let keyboard = try await store.createTask("修好登录页的键盘遮挡")
        try await store.linkCard(keyboard.id, toSession: "keyboard")
        let fixes = try await store.addPreviews([
            (try file("before.png", phonePNG(covered: true)), "修复前：键盘挡住登录钮"),
            (try file("wip.png", phonePNG(covered: true) + Data("wip".utf8)), "中途一版：只改了滚动"),
            (try file("after.png", phonePNG(covered: false)), "修复后：登录钮在键盘上方"),
        ], sessionID: "keyboard").map(\.preview)
        _ = try await store.finishTask(
            keyboard.id, evidence: ["小屏上键盘弹出后登录钮仍可见", "横竖屏切换不跳动"],
            shots: [CueShot(preview: fixes[0].id, look: "修复前：登录钮被键盘挡住"), CueShot(preview: fixes[2].id, look: "修复后：登录钮露在键盘上方")])

        let pricing = try await store.createTask("重做定价区")
        try await store.linkCard(pricing.id, toSession: "pricing")
        _ = try await store.addPreviews([
            (try file("pricing.html", Data(pricingPage.utf8)), "定价页：三档在窄屏横滑"), (try file("定价对比.pdf", pricingPDF()), "三档价格对比表"),
            (try file("宽屏.png", widePNG()), "宽屏：三档并排"), (try file("改动说明.md", Data(pricingNotes.utf8)), "改了什么、还差什么"),
        ], sessionID: "pricing")
        _ = try await store.addCueMessage(
            .cue, text: "定价区的会话发来了一批，我核对过：三档价格在窄屏下不再挤成两行，年付的折扣标在卡片右上角。还差深色模式，让它接着做。",
            task: pricing.id)

        // "等你"里推送的那件：部署会话发来预发上的截图与测试报告
        _ = try await store.addPreviews([(try file("预发.png", stagingOrderPNG()), "预发上的发言顺序")], sessionID: "deploy")
        _ = try await store.addPreviews([(try file("测试报告.pdf", reconnectReportPDF()), "重连测试报告")], sessionID: "deploy")
    }

    /// `-CuePadAllKinds YES|<n>`：空着的 scratch 会话里发六批，每批两份并排：3D 模型与一张还没到本机的（附件文件删掉，卡片写"下载中"；
    /// 标题同文件名），之后每种能发的类型各一份；`-CuePadOpenPreview <文件名>` 打开其中一份的预览页。给数字只发前 n 批：
    /// 会话页停在最新处，一屏看到的是最后两三批，换着 n 拍几张就每种都拍到了。
    /// 视频、音频、Office 与 3D 只要扩展名对，内容是占位的字节：系统给不出缩略图、时长时显示的正是类型图标。
    static func seedAllKinds(_ store: CueStore, upTo count: Int?) async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cuepad-demo-kinds", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func file(_ name: String, _ data: Data) -> URL? {
            let url = directory.appending(path: name)
            return (try? data.write(to: url)).map { url }
        }
        let filler = Data("placeholder".utf8)
        // 字节与别处的截图不同：附件按内容存一份，同样的字节会被别的演示数据重新写回来
        let away = phonePNG(covered: true) + Data("away".utf8)
        let batches: [[URL?]] = [
            [file("模型.usdz", filler), file("还在路上.png", away)],
            [file("录音.m4a", filler), file("录屏.mov", filler)],
            [file("需求.docx", filler), file("数据.xlsx", filler)],
            [file("汇报.pptx", filler), file("报告.pdf", reconnectReportPDF())],
            [file("日志.txt", Data("12:00 ok\n12:01 retry\n".utf8)), file("改动说明.md", Data(pricingNotes.utf8))],
            [file("定价页.html", Data(pricingPage.utf8)), file("预发.png", stagingOrderPNG())],
        ]
        for files in batches.prefix(count ?? batches.count) {
            let named = files.compactMap { $0 }.map { (url: $0, title: $0.deletingPathExtension().lastPathComponent) }
            guard let added = try? await store.addPreviews(named, sessionID: "scratch") else { continue }
            for entry in added where entry.preview.name == "还在路上.png" {
                if let stored = store.files.fileURL(for: entry.preview.hash) { try? FileManager.default.removeItem(at: stored) }
            }
        }
    }

    private static let pricingPage = """
        <!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>
        body{margin:0;font:17px -apple-system,system-ui,sans-serif;background:linear-gradient(160deg,#eef2ff,#fdf2f8);color:#1c1b19;padding:48px}
        h1{font-size:40px;margin:0 0 8px}p{color:#666;margin:0 0 32px}.row{display:flex;gap:20px}
        .card{flex:1;background:#fff;border-radius:18px;padding:28px;box-shadow:0 8px 30px -12px rgba(0,0,0,.2)}
        .card.pro{outline:3px solid #4f46e5}.price{font-size:44px;font-weight:800;margin:12px 0}
        button{width:100%;border:0;border-radius:12px;padding:12px;font-size:16px;background:#4f46e5;color:#fff}
        @media(max-width:600px){body{padding:24px}h1{font-size:30px}.row{flex-direction:column;gap:14px}.card{padding:20px}}
        </style></head><body><h1>选一个适合你的方案</h1><p>年付立省 20%，随时可以取消。</p><div class="row">
        <div class="card"><b>基础</b><div class="price">¥0</div><button>开始使用</button></div>
        <div class="card pro"><b>专业</b><div class="price">¥68</div><button>升级</button></div>
        <div class="card"><b>团队</b><div class="price">¥198</div><button>联系我们</button></div>
        </div></body></html>
        """

    private static let darkPricing = "body{background:#15151c;color:#eee}p{color:#9a9aa6}.card{background:#23232d;box-shadow:none}"

    private static let pricingNotes = """
        # 定价区改动说明

        ## 改了什么
        - 三档价格卡在窄屏下改成横向滑动，不再挤成两行
        - 年付折扣标挪到卡片右上角
        - 专业档加了描边，作为推荐

        ## 还没做
        - 深色模式的配色
        """
}
#endif
