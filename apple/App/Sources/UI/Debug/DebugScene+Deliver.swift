#if DEBUG
import CueStore
import SwiftUI

/// 演示库里 Cue 页的结果卡（`seedCue` 里调）：三件活各有会话发来的交付物——"落地页深浅两版"做完了，挂着两份网页（同一组两份网页左右翻）；
/// "修好登录页的键盘遮挡"做完了，挂着修复前与修复后两张截图；
/// "重做定价区"中途 Cue 核对过一批，挂着网页、PDF、横图与 Markdown 四份（三份起横向滑）。README 那件挂着一张（`seedCue`），
/// "等你"里的推送挂着部署会话发来的截图与测试报告（迷你一排）。
extension DebugScene {
    static func seedDeliveries(_ store: CueStore) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cuepad-demo-deliver", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func file(_ name: String, _ data: Data) throws -> URL {
            let url = directory.appending(path: name)
            try data.write(to: url)
            return url
        }

        let landing = try await store.createTask("落地页深浅两版", in: nil)
        try await store.linkCard(landing.id, toSession: "landing")
        _ = try await store.addPreviews(filesAt: [
            try file("浅色.html", Data(pricingPage.utf8)),
            try file("深色.html", Data(pricingPage.replacing("</style>", with: darkPricing + "</style>").utf8)),
        ], title: nil, sessionID: "landing")
        _ = try await store.finishTask(landing.id, evidence: ["浅色深色各一版，按钮对比度都过了 4.5:1"])

        let keyboard = try await store.createTask("修好登录页的键盘遮挡", in: nil)
        try await store.linkCard(keyboard.id, toSession: "keyboard")
        _ = try await store.addPreviews(filesAt: [
            try file("修复前.png", phonePNG(covered: true)), try file("修复后.png", phonePNG(covered: false)),
        ], title: nil, sessionID: "keyboard")
        _ = try await store.finishTask(keyboard.id, evidence: ["小屏上键盘弹出后登录钮仍可见", "横竖屏切换不跳动"])

        let pricing = try await store.createTask("重做定价区", in: nil)
        try await store.linkCard(pricing.id, toSession: "pricing")
        _ = try await store.addPreviews(filesAt: [
            try file("pricing.html", Data(pricingPage.utf8)), try file("定价对比.pdf", reportPDF()),
            try file("宽屏.png", widePNG()), try file("改动说明.md", Data(pricingNotes.utf8)),
        ], title: "定价区三种方案", sessionID: "pricing")
        _ = try await store.addCueMessage(
            .cue, text: "定价区的会话发来了一批，我核对过：三档价格在窄屏下不再挤成两行，年付的折扣标在卡片右上角。还差深色模式，让它接着做。",
            task: pricing.id)

        // "等你"里推送的那件：部署会话发来预发上的截图与测试报告
        _ = try await store.addPreviews(filesAt: [try file("预发.png", phonePNG(covered: false))], title: "预发上的发言顺序", sessionID: "deploy")
        _ = try await store.addPreviews(filesAt: [try file("测试报告.pdf", reportPDF())], title: "重连测试报告", sessionID: "deploy")
    }

    /// `-CuePadAllKinds YES|<n>`：空着的 scratch 会话里发六批，每批两份并排：3D 模型与一张还没到本机的（附件文件删掉，卡片写"下载中"；
    /// 标题"模型"，配 `-CuePadOpenPreview 模型` 打开模型的预览页），之后每种能发的类型各一份。给数字只发前 n 批：
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
        let batches: [(String, [URL?])] = [
            ("模型", [file("模型.usdz", filler), file("还在路上.png", away)]),
            ("录音与录屏", [file("录音.m4a", filler), file("录屏.mov", filler)]),
            ("文稿与表格", [file("需求.docx", filler), file("数据.xlsx", filler)]),
            ("汇报与报告", [file("汇报.pptx", filler), file("报告.pdf", reportPDF())]),
            ("日志与说明", [file("日志.txt", Data("12:00 ok\n12:01 retry\n".utf8)), file("改动说明.md", Data(pricingNotes.utf8))]),
            ("网页与截图", [file("定价页.html", Data(pricingPage.utf8)), file("预发.png", phonePNG(covered: false))]),
        ]
        for (title, files) in batches.prefix(count ?? batches.count) {
            guard let added = try? await store.addPreviews(filesAt: files.compactMap { $0 }, title: title, sessionID: "scratch") else { continue }
            for entry in added where entry.preview.name == "还在路上.png" {
                if let stored = store.files.fileURL(for: entry.preview.hash) { try? FileManager.default.removeItem(at: stored) }
            }
        }
    }

    /// 手机登录页的截图：`covered` 时键盘挡住了登录钮。
    static func phonePNG(covered: Bool) -> Data {
        let view = ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("登录").font(.system(size: 30, weight: .bold)).padding(.top, 70)
                ForEach(["邮箱", "密码"], id: \.self) { field in
                    RoundedRectangle(cornerRadius: 10).stroke(.gray.opacity(0.4)).frame(height: 46)
                        .overlay(alignment: .leading) { Text(field).foregroundStyle(.gray).padding(.leading, 12) }
                }
                RoundedRectangle(cornerRadius: 12).fill(.indigo).frame(height: 48)
                    .overlay { Text("登录").foregroundStyle(.white).bold() }
                    .padding(.top, covered ? 150 : 8)
                Spacer()
            }
            .padding(24)
            RoundedRectangle(cornerRadius: 0).fill(Color(white: 0.82)).frame(height: 250)
                .overlay { Text("键盘").foregroundStyle(.gray) }
        }
        .frame(width: 320, height: 640).background(.white)
        return render(view)
    }

    /// 一张宽屏截图（16:9）。
    private static func widePNG() -> Data {
        let view = HStack(spacing: 16) {
            ForEach(["基础", "专业", "团队"], id: \.self) { tier in
                VStack(spacing: 10) {
                    Text(tier).font(.title3.bold())
                    Text(tier == "专业" ? "¥68" : tier == "基础" ? "¥0" : "¥198").font(.system(size: 34, weight: .heavy))
                    RoundedRectangle(cornerRadius: 8).fill(tier == "专业" ? .indigo : .gray.opacity(0.3)).frame(height: 34)
                }
                .padding(18).frame(maxWidth: .infinity).background(.white, in: .rect(cornerRadius: 16))
            }
        }
        .padding(28).frame(width: 640, height: 360).background(Color(red: 0.93, green: 0.94, blue: 0.99))
        return render(view)
    }

    private static func render(_ view: some View) -> Data {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage.map { DemoLibrary.encode($0) } ?? Data()
    }

    /// 两页的 PDF：表格样子的对比。
    static func reportPDF() -> Data {
        let page = VStack(alignment: .leading, spacing: 12) {
            Text("定价对比").font(.system(size: 28, weight: .bold))
            ForEach(["基础 · ¥0 · 3 个项目", "专业 · ¥68 · 不限项目", "团队 · ¥198 · 10 人协作"], id: \.self) { line in
                Text(line).font(.system(size: 16))
                Divider()
            }
            Spacer()
        }
        .padding(48).frame(width: 595, height: 842).background(.white)
        let data = NSMutableData()
        let renderer = ImageRenderer(content: page)
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            for _ in 0..<2 {
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
            context.closePDF()
        }
        return data as Data
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
