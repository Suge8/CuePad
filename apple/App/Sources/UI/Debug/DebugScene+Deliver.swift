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

        let landing = try await store.createTask(String(localized: "落地页深浅两版", table: "Demo"))
        try await store.linkCard(landing.id, toSession: "landing")
        _ = try await store.addPreviews([(try file("draft-hero.png", widePNG()), String(localized: "方案稿：首屏三档并排", table: "Demo"))], sessionID: "landing")
        let pages = try await store.addPreviews([
            (try file("final-light.html", Data(pricingPage.utf8)), String(localized: "最终版浅色：定价页首屏", table: "Demo")),
            (try file("final-dark.html", Data(pricingPage.replacing("</style>", with: darkPricing + "</style>").utf8)), String(localized: "最终版深色：定价页首屏", table: "Demo")),
        ], sessionID: "landing").map(\.preview)
        _ = try await store.finishTask(
            landing.id, evidence: [String(localized: "浅色深色各一版，按钮对比度都过了 4.5:1", table: "Demo")],
            shots: [CueShot(preview: pages[0].id, look: String(localized: "浅色：专业档描边是推荐", table: "Demo")), CueShot(preview: pages[1].id, look: String(localized: "深色：按钮对比度够", table: "Demo"))])

        let keyboard = try await store.createTask(String(localized: "修好登录页的键盘遮挡", table: "Demo"))
        try await store.linkCard(keyboard.id, toSession: "keyboard")
        let fixes = try await store.addPreviews([
            (try file("before.png", phonePNG(covered: true)), String(localized: "修复前：键盘挡住登录钮", table: "Demo")),
            (try file("wip.png", phonePNG(covered: true) + Data("wip".utf8)), String(localized: "中途一版：只改了滚动", table: "Demo")),
            (try file("after.png", phonePNG(covered: false)), String(localized: "修复后：登录钮在键盘上方", table: "Demo")),
        ], sessionID: "keyboard").map(\.preview)
        _ = try await store.finishTask(
            keyboard.id, evidence: [String(localized: "小屏上键盘弹出后登录钮仍可见", table: "Demo"), String(localized: "横竖屏切换不跳动", table: "Demo")],
            shots: [CueShot(preview: fixes[0].id, look: String(localized: "修复前：登录钮被键盘挡住", table: "Demo")), CueShot(preview: fixes[2].id, look: String(localized: "修复后：登录钮露在键盘上方", table: "Demo"))])

        let pricing = try await store.createTask(String(localized: "重做定价区", table: "Demo"))
        try await store.linkCard(pricing.id, toSession: "pricing")
        _ = try await store.addPreviews([
            (try file("pricing.html", Data(pricingPage.utf8)), String(localized: "定价页：三档在窄屏横滑", table: "Demo")), (try file(String(localized: "定价对比.pdf", table: "Demo"), pricingPDF()), String(localized: "三档价格对比表", table: "Demo")),
            (try file(String(localized: "宽屏.png", table: "Demo"), widePNG()), String(localized: "宽屏：三档并排", table: "Demo")), (try file(String(localized: "改动说明.md", table: "Demo"), Data(pricingNotes.utf8)), String(localized: "改了什么、还差什么", table: "Demo")),
        ], sessionID: "pricing")
        _ = try await store.addCueMessage(
            .cue, text: String(localized: "定价区的会话发来了一批，我核对过：三档价格在窄屏下不再挤成两行，年付的折扣标在卡片右上角。还差深色模式，让它接着做。", table: "Demo"),
            task: pricing.id)

        // "等你"里推送的那件：部署会话发来预发上的截图与测试报告
        _ = try await store.addPreviews([(try file(String(localized: "预发.png", table: "Demo"), stagingOrderPNG()), String(localized: "预发上的发言顺序", table: "Demo"))], sessionID: "deploy")
        _ = try await store.addPreviews([(try file(String(localized: "测试报告.pdf", table: "Demo"), reconnectReportPDF()), String(localized: "重连测试报告", table: "Demo"))], sessionID: "deploy")
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
            [file(String(localized: "模型.usdz", table: "Demo"), filler), file(String(localized: "还在路上.png", table: "Demo"), away)],
            [file(String(localized: "录音.m4a", table: "Demo"), filler), file(String(localized: "录屏.mov", table: "Demo"), filler)],
            [file(String(localized: "需求.docx", table: "Demo"), filler), file(String(localized: "数据.xlsx", table: "Demo"), filler)],
            [file(String(localized: "汇报.pptx", table: "Demo"), filler), file(String(localized: "报告.pdf", table: "Demo"), reconnectReportPDF())],
            [file(String(localized: "日志.txt", table: "Demo"), Data("12:00 ok\n12:01 retry\n".utf8)), file(String(localized: "改动说明.md", table: "Demo"), Data(pricingNotes.utf8))],
            [file(String(localized: "定价页.html", table: "Demo"), Data(pricingPage.utf8)), file(String(localized: "预发.png", table: "Demo"), stagingOrderPNG())],
        ]
        for files in batches.prefix(count ?? batches.count) {
            let named = files.compactMap { $0 }.map { (url: $0, title: $0.deletingPathExtension().lastPathComponent) }
            guard let added = try? await store.addPreviews(named, sessionID: "scratch") else { continue }
            for entry in added where entry.preview.name == String(localized: "还在路上.png", table: "Demo") {
                if let stored = store.files.fileURL(for: entry.preview.hash) { try? FileManager.default.removeItem(at: stored) }
            }
        }
    }

    private static var pricingPage: String { """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>
        body{margin:0;font:17px -apple-system,system-ui,sans-serif;background:linear-gradient(160deg,#eef2ff,#fdf2f8);color:#1c1b19;padding:48px}
        h1{font-size:40px;margin:0 0 8px}p{color:#666;margin:0 0 32px}.row{display:flex;gap:20px}
        .card{flex:1;background:#fff;border-radius:18px;padding:28px;box-shadow:0 8px 30px -12px rgba(0,0,0,.2)}
        .card.pro{outline:3px solid #4f46e5}.price{font-size:44px;font-weight:800;margin:12px 0}
        button{width:100%;border:0;border-radius:12px;padding:12px;font-size:16px;background:#4f46e5;color:#fff}
        @media(max-width:600px){body{padding:24px}h1{font-size:30px}.row{flex-direction:column;gap:14px}.card{padding:20px}}
        </style></head><body><h1>\(String(localized: "选一个适合你的方案", table: "Demo"))</h1><p>\(String(localized: "年付立省 20%，随时可以取消。", table: "Demo"))</p><div class="row">
        <div class="card"><b>\(String(localized: "基础", table: "Demo"))</b><div class="price">¥0</div><button>\(String(localized: "开始使用", table: "Demo"))</button></div>
        <div class="card pro"><b>\(String(localized: "专业", table: "Demo"))</b><div class="price">¥68</div><button>\(String(localized: "升级", table: "Demo"))</button></div>
        <div class="card"><b>\(String(localized: "团队", table: "Demo"))</b><div class="price">¥198</div><button>\(String(localized: "联系我们", table: "Demo"))</button></div>
        </div></body></html>
        """ }

    private static let darkPricing = "body{background:#15151c;color:#eee}p{color:#9a9aa6}.card{background:#23232d;box-shadow:none}"

    private static var pricingNotes: String { String(localized: """
        # 定价区改动说明

        ## 改了什么
        - 三档价格卡在窄屏下改成横向滑动，不再挤成两行
        - 年付折扣标挪到卡片右上角
        - 专业档加了描边，作为推荐

        ## 还没做
        - 深色模式的配色
        """, table: "Demo") }
}
#endif
