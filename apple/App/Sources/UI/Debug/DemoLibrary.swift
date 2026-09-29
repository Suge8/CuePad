#if os(macOS) && DEBUG
import AppKit
import CueStore
import CueText
import Foundation
import SQLite3

/// 视觉验收的演示资料库：生成一份 Electron 旧库格式的 SQLite，经正式的导入流程写入（导入保留原修改时间，
/// 所以墙、"更早"的周/月分组都有真实分布），再补目标卡、目录绑定、发送记录与 Pi 历史。
/// 只在 Debug 构建、隔离资料库、`-CuePadDemo YES` 时运行。
enum DemoLibrary {
    private struct DemoProject {
        var name: String, icon: String, color: String, pinned: Bool, directory: String?
        var cards: [(days: Double, text: String, favorite: Bool)]
    }

    static func seed(_ store: CueStore) async throws {
        let image = try await store.addImage(sampleImage()).hash
        let source = FileManager.default.temporaryDirectory.appending(path: "cuepad-demo-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: source) }
        try writeLegacy(projects(image: image), to: source)
        _ = try await store.importElectronLibrary(from: source)

        let catalog = projects(image: image)
        for project in try await store.projects() {
            if let directory = catalog.first(where: { $0.name == project.name })?.directory {
                try await store.setDirectory(directory, for: project.id)
            }
            let cards = try await store.cards(in: project.id)
            if let goal = cards.first(where: { $0.body.hasPrefix("目标：") }) {
                try await store.setGoal(goal.id, for: project.id)
            }
            for card in cards.filter({ $0.body.contains("发给 Pi") || $0.body.hasPrefix("评审") }).prefix(4) {
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        for (index, item) in [("cuepad", "规划投送队列的重试边界"), ("atlas", "多 Agent 调度压测"), ("homepage", "首页改版文案")].enumerated() {
            try await store.upsertPiSession(PiSession(
                id: "demo-\(index)", path: "/tmp/demo-\(index).jsonl", cwd: "\(home)Project/\(item.0)",
                title: item.1, lastActivityAt: .now.addingTimeInterval(-Double(index + 1) * 5400)))
        }
    }

    private static func projects(image: String) -> [DemoProject] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let pic = CueFormat.imageMarkup(id: image)
        return [
            DemoProject(name: "CuePad", icon: "sparkles", color: "#A260C4", pinned: false, directory: "\(home)Project/cuepad", cards: [
                (0.1, "目标：投送队列本月可上线\n\n能在真实数据上跑完一整天；投送队列、TextKit 编辑器、变量模板都有验收记录，发布说明写好。", false),
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
                (110.0, "旧方案：Electron 投送\n\nsidecar 串行队列与超时。", false),
                (130.0, "调研 CKSyncEngine\n\n记录级同步、资产上传与冲突处理。", false),
                (170.0, "原型：三个视觉方向\n\n桌面、看板、流。", false),
                (200.0, "常用提示：代码评审\n\n只报告会导致错误行为的问题，按严重程度排序。", true),
            ]),
            DemoProject(name: "圆桌", icon: "messages-square", color: "#D9774B", pinned: true, directory: "\(home)Project/atlas", cards: [
                (0.3, "目标：多 Agent 调度本月可上线\n\n能在真实数据上跑完一整天；调度、主持人提示词、发言轮次都有验收记录。", false),
                (1.0, "产品决策\n\n先列出现状和约束，再给出下一步。", false),
                (2.5, "评审：计费额度\n\n审查 {{分支}} 中计费额度相关改动。", false),
                (40.0, "主持人提示词\n\n\(pic)\n提示词写好，一键投送。", false),
            ]),
            DemoProject(name: "Flow", icon: "layers", color: "#6A6FD1", pinned: true, directory: nil, cards: [
                (1.0, "撤销栈合并连续拖拽\n\n连续拖拽只记一步撤销。", false),
                (15.0, "画布缩放\n\n双指缩放锚点跟随指针。", false),
            ]),
            DemoProject(name: "闲鱼", icon: "shopping-bag", color: "#3F8FB8", pinned: false, directory: nil, cards: [
                (3.0, "定价补测试\n\n在接缝上给定价补验收测试。", false),
            ]),
            DemoProject(name: "个人网站", icon: "globe", color: "#C9A227", pinned: false, directory: "\(home)Project/homepage", cards: [
                (8.0, "首页改版\n\n给首页改版出三个方案，比较代价。", false),
            ]),
            DemoProject(name: "Career", icon: "briefcase", color: "#5E9E5A", pinned: false, directory: nil, cards: [
                (20.0, "求职信\n\n按岗位描述改写第一段。", false),
            ]),
        ]
    }

    private static let tasks: [(project: String?, text: String, done: Bool)] = [
        ("CuePad", "投送队列超时报错不发键", false),
        ("CuePad", "导入旧数据时保留回收站", false),
        ("CuePad", "菜单栏面板 ⌘↩ 直接发出", false),
        ("圆桌", "发言轮次在 5 人以上会乱序", false),
        ("圆桌", "登录回调改走统一网关", false),
        ("圆桌", "清理旧的计费脚本", true),
        ("Flow", "撤销栈合并连续拖拽", false),
        (nil, "README 截图换成 Swift 版", false),
        (nil, "续费域名", false),
    ]

    private static func writeLegacy(_ projects: [DemoProject], to url: URL) throws {
        let now = Date.now.timeIntervalSince1970 * 1000
        var sql = """
            CREATE TABLE projects (id INTEGER PRIMARY KEY, name TEXT, icon TEXT, color TEXT NOT NULL, sort_order INTEGER,
              is_pinned INTEGER, deleted_at INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
            CREATE TABLE cards (id INTEGER PRIMARY KEY, project_id INTEGER, title TEXT, body TEXT, sort_order INTEGER,
              is_favorite INTEGER, numbering TEXT, deleted_at INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
            CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL, color TEXT, deleted_at INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
            CREATE TABLE card_tags (card_id INTEGER NOT NULL, tag_id INTEGER NOT NULL, created_at INTEGER NOT NULL);
            CREATE TABLE tasks (id INTEGER PRIMARY KEY, content TEXT NOT NULL, project_id INTEGER, sort_order INTEGER,
              completed_at INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
            CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);

            """
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        var cardID = 1
        for (index, project) in projects.enumerated() {
            let projectID = index + 1
            sql += "INSERT INTO projects VALUES (\(projectID), \(quoted(project.name)), \(quoted(project.icon)), \(quoted(project.color)), \(index), \(project.pinned ? 1 : 0), NULL, \(Int(now)), \(Int(now)));\n"
            for card in project.cards {
                let stamp = Int(now - card.days * 86_400_000)
                sql += "INSERT INTO cards VALUES (\(cardID), \(projectID), NULL, \(quoted(card.text)), \(cardID), \(card.favorite ? 1 : 0), 'none', NULL, \(stamp), \(stamp));\n"
                cardID += 1
            }
        }
        for (index, task) in tasks.enumerated() {
            let project = task.project.flatMap { name in projects.firstIndex { $0.name == name } }.map { "\($0 + 1)" } ?? "NULL"
            sql += "INSERT INTO tasks VALUES (\(index + 1), \(quoted(task.text)), \(project), \(index), \(task.done ? "\(Int(now))" : "NULL"), \(Int(now)), \(Int(now)));\n"
        }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            throw DemoError(message: message.map { String(cString: $0) } ?? "sqlite")
        }
    }

    private struct DemoError: Error { var message: String }

    /// 一张像界面截图的示意图：桌面底色上几块纸片。
    private static func sampleImage() -> Data {
        let size = NSSize(width: 960, height: 600)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor(red: 0.94, green: 0.93, blue: 0.91, alpha: 1).setFill()
            rect.fill()
            let paper = NSColor(red: 0.99, green: 0.985, blue: 0.97, alpha: 1)
            let ink = NSColor(red: 0.11, green: 0.106, blue: 0.098, alpha: 1)
            for (index, frame) in [
                NSRect(x: 40, y: 90, width: 270, height: 170), NSRect(x: 340, y: 90, width: 270, height: 230),
                NSRect(x: 640, y: 90, width: 270, height: 140), NSRect(x: 40, y: 290, width: 270, height: 250),
            ].enumerated() {
                paper.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 18, yRadius: 18).fill()
                ink.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: frame.minX + 20, y: frame.minY + 22, width: 120 + CGFloat(index) * 20, height: 14), xRadius: 4, yRadius: 4).fill()
                ink.withAlphaComponent(0.3).setFill()
                for line in 0..<3 {
                    NSBezierPath(roundedRect: NSRect(x: frame.minX + 20, y: frame.minY + 54 + CGFloat(line) * 22, width: frame.width - 60 - CGFloat(line) * 30, height: 9), xRadius: 3, yRadius: 3).fill()
                }
            }
            ink.setFill()
            NSBezierPath(roundedRect: NSRect(x: 40, y: 30, width: 180, height: 26), xRadius: 6, yRadius: 6).fill()
            return true
        }
        let bitmap = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        return bitmap.representation(using: .png, properties: [:])!
    }
}
#endif
