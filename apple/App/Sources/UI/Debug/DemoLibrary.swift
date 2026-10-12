#if DEBUG
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CueStore
import CueText
import Foundation

/// 视觉验收的演示资料库：项目与灵感按各自的修改时间写入（`CueStore.seed`，所以墙、"更早"的周/月分组都有真实分布），
/// 再补任务层级、项目介绍、目录绑定、发送记录与 Pi 历史。
/// 只在 Debug 构建、隔离资料库、`-CuePadDemo YES` 时运行。
enum DemoLibrary {
    struct DemoProject {
        var name: String, icon: String, color: String, pinned: Bool, directory: String?, intro: String? = nil
        var cards: [(days: Double, text: String, favorite: Bool)]
    }

    static func seed(_ store: CueStore) async throws {
        let image = try store.files.store(sampleImage())
        try await seed(store, groups: projects(image: image), tasks: tasks)
        try await seedSubtasks(store)

        let catalog = projects(image: image)
        for project in try await store.projects() {
            if let directory = catalog.first(where: { $0.name == project.name })?.directory {
                try await store.setDirectory(directory, for: project.id)
            }
            if let intro = catalog.first(where: { $0.name == project.name })?.intro {
                try await store.updateProject(project.id) { $0.intro = intro }
            }
            for card in try await store.cards(in: project.id).filter({ $0.body.contains("发给 Pi") || $0.body.hasPrefix("评审") }).prefix(4) {
                try await store.recordSend(card.body, to: SendTarget(kind: .piSession, name: project.name.lowercased()), card: card.id)
            }
        }
        let retired = try await store.createProject(name: "旧落地页", color: "#8A8A84", icon: "globe")
        _ = try await store.createCard(in: retired.id, body: "旧落地页文案\n\n首屏标题与三段卖点。")
        try await store.trashProject(retired.id)
        for project in try await store.projects() {
            for card in try await store.cards(in: project.id) where card.body.hasPrefix("旧方案") || card.body.hasPrefix("产品决策") {
                try await store.trashCard(card.id)
            }
        }
        let home = demoHome
        for (index, item) in [("cuepad", "规划投送队列的重试边界"), ("atlas", "多 Agent 调度压测"), ("homepage", "首页改版文案")].enumerated() {
            try await store.upsertPiSession(PiSession(
                id: "demo-\(index)", path: "/tmp/demo-\(index).jsonl", cwd: "\(home)Project/\(item.0)",
                title: item.1, lastActivityAt: .now.addingTimeInterval(-Double(index + 1) * 5400)), host: "demo-mac")
        }
    }

    private static func projects(image: String) -> [DemoProject] {
        let home = demoHome
        let pic = CueFormat.imageMarkup(id: image)
        return [
            DemoProject(name: "CuePad", icon: "sparkles", color: "#A260C4", pinned: false, directory: "\(home)Project/cuepad", intro: "投送队列本月可上线", cards: [
                (0.2, "修复 TextKit 编辑器\n\nTextKit 编辑器偶发失败。先稳定复现，定位根因后再改，不要加重试掩盖。", false),
                (0.6, "设计 iCloud 同步\n\n给 iCloud 同步出三个方案，比较代价，推荐一个并说明理由。\n---split---\n约束：离线并发编辑保留两个版本，不静默覆盖。", false),
                (1.2, "变量模板文档\n\n\(pic)\n更新变量模板的开发文档，删掉过时的说明。", false),
                (1.5, "排查 Pi 桥\n\n日志里 Pi 桥报错 {{错误码}}，查清触发条件再动手。", false),
                (2.0, "重构菜单栏面板\n\n把 {{模块路径}} 里的菜单栏面板拆成独立模块，保持公开接口不变。\n---split---\n验收：菜单栏唤起到可输入 < 100ms。\n---split---\n完成后把改动摘要写进发布说明。", false),
                (3.0, "评审：导入旧数据\n\n审查 {{分支}} 中导入旧数据相关改动，只报告会导致错误行为的问题。", false),
                (4.0, "优化回收站性能\n\n回收站在 {{数据量}} 条时明显卡顿，先测量再优化。", false),
                (5.5, "迁移投送队列\n\n把投送队列迁到新的存储层，旧数据一次性导入。", false),
                (6.0, "想法：TextKit 编辑器\n\n\(pic)\n编辑器的附件也许可以按视口懒加载，只挂缩略图。", false),
                (9.0, "变量模板补测试\n\n在接缝上给变量模板补验收测试，先看到它失败，再实现。", false),
                (12.0, "Todo\n\n- 截图换成 Swift 版\n- 续费域名\n- 更新落地页", false),
                (18.0, "排查剪贴板回读\n\n写入后回读偶尔为空，先确认是不是竞态。", false),
                (21.0, "评审：快捷键录制\n\n只看会导致错误行为的问题。", false),
                (26.0, "想法：发送记录\n\n一键重发时带上当时的变量取值。", false),
                (33.0, "重构设置页\n\n设置项的描述写打开后会发生什么。", false),
                (38.0, "排查 socket 残留\n\n强杀后 socket 没删，检查 kqueue 退出通知。", false),
                (45.0, "设计通知\n\nPi 完成与等你确认时推送，点通知跳到会话。", false),
                (52.0, "整理发布清单\n\n签名、公证、Sparkle 更新源。", false),
                (60.0, "修复拖入图片\n\n拖入 HEIC 时缩略图空白。", false),
                (75.0, "想法：卡片墙\n\n只在打开项目或跨天时重排，同一次打开里墙不自己挪动。", false),
                (84.0, "评审：搜索筛选\n\n分页前先筛选，总数不受分页影响。", false),
                (110.0, "旧方案：轮询会话状态\n\n每两秒查一次，耗电。", false),
                (130.0, "调研 CKSyncEngine\n\n记录级同步、资产上传与冲突处理。", false),
                (170.0, "原型：三个视觉方向\n\n桌面、看板、流。", false),
                (200.0, "常用提示：代码评审\n\n只报告会导致错误行为的问题，按严重程度排序。", true),
            ]),
            DemoProject(name: "圆桌", icon: "messages-square", color: "#D9774B", pinned: true, directory: "\(home)Project/atlas", intro: "多 Agent 调度本月可上线", cards: [
                (1.0, "产品决策\n\n先列出现状和约束，再给出下一步。", false),
                (2.5, "评审：计费额度\n\n审查 {{分支}} 中计费额度相关改动。", true),
                (40.0, "主持人提示词\n\n\(pic)\n提示词写好，一键投送。", false),
            ]),
            DemoProject(name: "Flow", icon: "layers", color: "#3AA088", pinned: true, directory: nil, cards: [
                (1.0, "撤销栈合并连续拖拽\n\n连续拖拽只记一步撤销。", false),
                (15.0, "画布缩放\n\n双指缩放锚点跟随指针。", false),
            ]),
            DemoProject(name: "闲鱼", icon: "shopping-bag", color: "#3F8FB8", pinned: false, directory: nil, intro: "二手相机这周挂出去", cards: [
                (3.0, "定价补测试\n\n在接缝上给定价补验收测试。", false),
            ]),
            DemoProject(name: "个人网站", icon: "globe", color: "#C9A227", pinned: false, directory: "\(home)Project/homepage", cards: [
                (8.0, "首页改版\n\n给首页改版出三个方案，比较代价。", false),
            ]),
            DemoProject(name: "Career", icon: "briefcase", color: "#5E9E5A", pinned: false, directory: nil, cards: [
                (20.0, "求职信\n\n按岗位描述改写第一段。", false),
            ]),
            DemoProject(name: "读书", icon: "book", color: "#D0607D", pinned: false, directory: nil, intro: "每周读完一章", cards: [
                (30.0, "《设计心理学》第二章\n\n示能与意符的区别。", false),
            ]),
            DemoProject(name: "旅行", icon: "globe", color: "#3F8FB8", pinned: false, directory: nil, cards: [
                (12.0, "京都行程\n\n第二天去岚山，避开周末。", false),
            ]),
            DemoProject(name: "装修", icon: "hammer", color: "#8A8A84", pinned: false, directory: nil, cards: [
                (6.0, "比价\n\n三家报价，水电分开算。", false),
            ]),
        ]
    }

    private static let tasks: [DemoTask] = [
        ("CuePad", "投送队列超时报错不发键", false),
        ("CuePad", "导入旧数据时保留回收站", false),
        ("CuePad", "菜单栏面板 ⌘↩ 直接发出", false),
        ("圆桌", "发言轮次在 5 人以上会乱序", false),
        ("圆桌", "登录回调改走统一网关", false),
        ("圆桌", "清理旧的计费脚本", true),
        ("Flow", "画布缩放锚点跟随指针", false),
        ("Flow", "撤销栈合并连续拖拽", false),
        (nil, "README 截图换成 Swift 版", false),
        (nil, "续费域名", false),
    ]

    typealias DemoTask = (project: String?, text: String, done: Bool)

    /// 两级任务：圆桌的"乱序"四条提示词（发给 Agent 的状态见 `DebugScene.seedTaskStates`），两条子任务（一条已完成），
    /// 其中一条下再挂两条提示词；CuePad 的"投送超时"一条提示词（演示里发给 notes，送达后用掉）。
    private static func seedSubtasks(_ store: CueStore) async throws {
        let tasks = try await store.tasks(.todo).flatMap(\.tasks)
        if let timeout = tasks.first(where: { $0.body.hasPrefix("投送队列") }) {
            _ = try await store.createCard(body: "投送超时时先重试一次，还失败再报错，并在提示里写明原因", under: timeout.id)
        }
        guard let order = tasks.first(where: { $0.body.hasPrefix("发言轮次") }) else { return }
        for body in [
            "跑一下 scheduler 的测试，找出 5 人以上时谁被排到了最前\n先别改代码，告诉我原因和改法",
            "按首次加入时间排序，把断言也改了，再跑一遍",
            "改完补 3 个重连用例，覆盖断线、超时、换设备",
            "测试都过了就部署到预发环境",
        ] {
            _ = try await store.createCard(body: body, under: order.id)
        }
        let reproduce = try await store.createTask("复现乱序", under: order.id)
        try await store.setStatus(reproduce.id, .done)
        let sort = try await store.createTask("改成按首次加入时间排序", under: order.id)
        for content in ["补 3 个重连用例", "跑一遍 16 人压测"] { _ = try await store.createCard(body: content, under: sort.id) }
    }

    /// 把项目分组与任务写进库；名称为空的一组是未分类的灵感。
    static func seed(_ store: CueStore, groups: [DemoProject], tasks: [DemoTask]) async throws {
        let named = groups.filter { !$0.name.isEmpty }
        func index(of name: String?) -> Int? { name.flatMap { name in named.firstIndex { $0.name == name } } }
        let now = Date.now
        let cards = groups.flatMap { group in
            group.cards.map {
                SeedCard(project: index(of: group.name), body: $0.text, pinned: $0.favorite, modifiedAt: now - $0.days * 86_400)
            }
        } + tasks.map { SeedCard(project: index(of: $0.project), body: $0.text, modifiedAt: now, kind: $0.done ? .doneTask : .task) }
        try await store.seed(
            projects: named.map { SeedProject(name: $0.name, icon: $0.icon, color: $0.color, pinned: $0.pinned) }, cards: cards)
    }

    /// 一张像界面截图的示意图：桌面底色上几块纸片。用 CoreGraphics 画，Mac 与 iOS 共用。
    /// 演示用的主目录：Mac 上是真实主目录（截图用的假 Pi 会话按它归到项目），iOS 只作显示。
    private static var demoHome: String {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        #else
        "/Users/demo/"
        #endif
    }

    private static func sampleImage() -> Data {
        let width = 960, height = 600
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // 翻成左上角为原点，方便按版面坐标画
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        func fill(_ rect: CGRect, radius: CGFloat, _ gray: (CGFloat, CGFloat, CGFloat, CGFloat)) {
            context.setFillColor(red: gray.0, green: gray.1, blue: gray.2, alpha: gray.3)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        let ink = (0.11, 0.106, 0.098)
        fill(CGRect(x: 0, y: 0, width: width, height: height), radius: 0, (0.94, 0.93, 0.91, 1))
        for (index, frame) in [
            CGRect(x: 40, y: 90, width: 270, height: 170), CGRect(x: 340, y: 90, width: 270, height: 230),
            CGRect(x: 640, y: 90, width: 270, height: 140), CGRect(x: 40, y: 290, width: 270, height: 250),
        ].enumerated() {
            fill(frame, radius: 18, (0.99, 0.985, 0.97, 1))
            fill(CGRect(x: frame.minX + 20, y: frame.minY + 22, width: 120 + CGFloat(index) * 20, height: 14), radius: 4, (ink.0, ink.1, ink.2, 0.85))
            for line in 0..<3 {
                fill(CGRect(x: frame.minX + 20, y: frame.minY + 54 + CGFloat(line) * 22, width: frame.width - 60 - CGFloat(line) * 30, height: 9),
                     radius: 3, (ink.0, ink.1, ink.2, 0.3))
            }
        }
        fill(CGRect(x: 40, y: 30, width: 180, height: 26), radius: 6, (ink.0, ink.1, ink.2, 1))
        return encode(context.makeImage()!)
    }

    /// 把一张图编成 PNG（或给了 `quality` 的 JPEG）：演示图片、大库的照片、截图示意图共用。
    nonisolated static func encode(_ image: CGImage, as type: UTType = .png, quality: Double? = nil) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary })
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
#endif
