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
        var name: String, icon: ProjectIcon, color: String, pinned: Bool, directory: String?, intro: String? = nil
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
            for card in try await store.cards(in: project.id).filter({ $0.body.hasPrefix(String(localized: "评审", table: "Demo")) }).prefix(4) {
                try await store.recordSend(card.body, to: SendTarget(kind: .piSession, name: project.name.lowercased()), card: card.id)
            }
        }
        let retired = try await store.createProject(name: String(localized: "旧落地页", table: "Demo"), color: "#8A8A84", icon: ProjectIcon.globe.rawValue)
        _ = try await store.createCard(in: retired.id, body: String(localized: "旧落地页文案\n\n首屏标题与三段卖点。", table: "Demo"))
        try await store.trashProject(retired.id)
        for project in try await store.projects() {
            for card in try await store.cards(in: project.id) where card.body.hasPrefix(String(localized: "旧方案：轮询会话状态", table: "Demo")) || card.body.hasPrefix(String(localized: "产品决策", table: "Demo")) {
                try await store.trashCard(card.id)
            }
        }
        try await seedQuotas(store)
        let home = demoHome
        for (index, item) in [("cuepad", String(localized: "规划投送队列的重试边界", table: "Demo")), ("atlas", String(localized: "多 Agent 调度压测", table: "Demo")), ("homepage", String(localized: "首页改版文案", table: "Demo"))].enumerated() {
            try await store.upsertPiSession(IndexedSession(
                id: "demo-\(index)", path: "/tmp/demo-\(index).jsonl", cwd: "\(home)Project/\(item.0)",
                title: item.1, lastActivityAt: .now.addingTimeInterval(-Double(index + 1) * 5400)), host: "demo-mac")
        }
    }

    /// 订阅额度：Claude 的 5 小时用得比匀速快（照这速度会提前用完）、本周宽松、按模型的周额度几乎没用（明细里不列）；Codex 本周已过九成（胭脂）。
    /// `-CuePadQuotaResetIn <秒>`：Claude 的 5 小时窗口这么多秒后重置，截图等到重置之后再拍（核对明细在那一刻变成已重置）。
    /// `-CuePadQuotaRemindIn <秒>`：Claude 的本周这么多秒后到提醒时刻（`QuotaReminder`），该响；5 小时（不是周窗口）、按模型的本周与 Codex 的本周（还远）不该响。
    /// 到点 20 秒后再观测到同一个本周窗口（多用了一些），不该再响。
    private static func seedQuotas(_ store: CueStore) async throws {
        let now = Date.now
        let resetIn = DebugScene.defaults.double(forKey: "CuePadQuotaResetIn")
        if resetIn > 0 { DebugHooks.later(.seconds(resetIn + 5)) {} }
        let remindIn = DebugScene.defaults.double(forKey: "CuePadQuotaRemindIn")
        func window(_ seconds: Int, used: Double, left: TimeInterval, model: String? = nil) -> QuotaWindow {
            QuotaWindow(seconds: seconds, used: used, resetsAt: now.addingTimeInterval(left), model: model)
        }
        let (hours5, week) = (5 * 3_600, QuotaWindow.week)
        let weekLeft = remindIn > 0 ? QuotaReminder.lead + remindIn : 4 * 86_400 + 3 * 3_600
        try await store.recordQuota(QuotaReport(provider: "anthropic", windows: [
            window(hours5, used: 0.68, left: resetIn > 0 ? resetIn : 2 * 3_600 + 14 * 60), window(week, used: 0.38, left: weekLeft),
            window(week, used: 0.12, left: weekLeft, model: "Fable"),
        ], complete: true), host: "demo-mac")
        if remindIn > 0 {
            Task {
                try? await Task.sleep(for: .seconds(remindIn + 20))
                _ = try? await store.recordQuota(QuotaReport(provider: "anthropic", windows: [window(week, used: 0.45, left: weekLeft)], complete: false), host: "demo-mac")
            }
        }
        try await store.recordQuota(QuotaReport(provider: "openai-codex", windows: [
            window(week, used: 0.91, left: 36 * 3_600),
        ], complete: true), host: "demo-mac")
    }

    /// 两级任务：圆桌的"乱序"四个子任务，每个子任务是叶子、带着正文（发给 Agent 的状态见 `DebugScene.seedTaskStates`）；
    /// CuePad 的"投送超时"是叶子、带着正文（演示里发给 notes）。
    private static func seedSubtasks(_ store: CueStore) async throws {
        let tasks = try await store.tasks(.todo).flatMap(\.tasks)
        if let timeout = tasks.first(where: { $0.body.hasPrefix(String(localized: "投送队列超时报错不发键", table: "Demo")) }) {
            try await store.updateCard(timeout.id) { $0.rest = String(localized: "投送超时时先重试一次，还失败再报错，并在提示里写明原因", table: "Demo") }
        }
        guard let order = tasks.first(where: { $0.body.hasPrefix(String(localized: "发言轮次乱序", table: "Demo")) }) else { return }
        for (step, rest) in [
            (String(localized: "复现乱序", table: "Demo"), String(localized: "跑一下 scheduler 的测试，找出 5 人以上时谁被排到了最前\n先别改代码，告诉我原因和改法", table: "Demo")),
            (String(localized: "改成按首次加入时间排序", table: "Demo"), String(localized: "按首次加入时间排序，把断言也改了，再跑一遍", table: "Demo")),
            (String(localized: "补 3 个重连用例", table: "Demo"), String(localized: "改完补 3 个重连用例，覆盖断线、超时、换设备", table: "Demo")),
            (String(localized: "部署到预发环境", table: "Demo"), String(localized: "测试都过了就部署到预发环境", table: "Demo")),
        ] {
            _ = try await store.createTask(step + "\n" + rest, under: order.id)
        }
    }

    /// 把项目分组与任务写进库；名称为空的一组进默认项目。
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
            projects: named.map { SeedProject(name: $0.name, icon: $0.icon.rawValue, color: $0.color, pinned: $0.pinned) }, cards: cards)
    }

    /// 一张像界面截图的示意图：桌面底色上几块纸片。用 CoreGraphics 画，Mac 与 iOS 共用。
    /// 演示用的主目录（以 / 结尾）：演示项目绑的文件夹、假 Pi 会话的工作目录都在它下面。Mac 上在隔离库里（`CUEPAD_LIBRARY_DIR/home`，
    /// 没给隔离库时在临时目录），不是真实主目录：演示实例会真去读写绑定的文件夹（技能与规则的扫描与整理），落在真实主目录下就会改到真的仓库。
    /// iOS 只作显示。
    static var demoHome: String {
        #if os(macOS)
        let root = ProcessInfo.processInfo.environment[LibraryLocation.environmentKey].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.temporaryDirectory.appending(path: "cuepad-demo", directoryHint: .isDirectory)
        return root.appending(path: "home/", directoryHint: .isDirectory).path(percentEncoded: false)
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
