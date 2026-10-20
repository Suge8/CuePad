#if os(macOS) && DEBUG
import CoreGraphics
import CueStore
import CueText
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// 性能测量用的大资料库（`-CuePadSeed perf`，只在 Debug 构建、隔离资料库、库为空时写入）：
/// 50 个项目、5000 张卡（一个大项目 1200 张、默认项目 300 张，其余分给 49 个项目），其中 300 张带 4032×3024 的 JPEG；
/// 修改时间分布在一年内；另有 200 条任务、500 条发送记录、200 个 Pi 历史会话，其中前 \(chatRounds.count) 个带对话（轮数见 `chatRounds`，
/// 回答混着长段落、列表、表格、代码块与工具活动，给会话页滚动与切换用）；Cue 运行在另一台 Mac 上，对话 \(cueRounds) 轮
/// （你的话、这一轮的经过、它的回答，中间夹着动态，每 \(cueRenewEvery) 轮换一次新上下文），给 Cue 页首访用。内容由固定种子生成，每次一样。
enum PerfLibrary {
    static let projectCount = 50
    static let cardCount = 5000
    nonisolated static let imageCount = 300
    static let piSessionCount = 200
    static let bigProject = "大项目"
    private static let bigProjectCards = 1200
    private static let defaultCards = 300
    private static let boundProjects = 10
    /// 带对话的历史会话（`perf-0`…）各有多少轮，长短悬殊。
    static let chatRounds = [3, 6, 10, 16, 24, 36, 50, 70, 100, 140, 200, 300]
    /// 最长的那段对话。
    static var longestChat: String { "perf-\(chatRounds.count - 1)" }

    static func seed(_ store: CueStore) async throws {
        var random = SeededRandom(seed: 20261002)
        let images = try storeImages(store)
        var imagePool = images[...]
        var groups: [DemoLibrary.DemoProject] = []
        let otherCards = (cardCount - bigProjectCards - defaultCards) / (projectCount - 1)
        for index in 0..<projectCount {
            let name = index == 0 ? bigProject : "项目 \(index) · \(projectWords[index % projectWords.count])"
            let count = index == 0 ? bigProjectCards : otherCards + (index <= (cardCount - bigProjectCards - defaultCards) % (projectCount - 1) ? 1 : 0)
            groups.append(DemoLibrary.DemoProject(
                name: name, icon: icons[index % icons.count], color: colors[index % colors.count], pinned: index < 3, directory: nil,
                cards: (0..<count).map { _ in card(&random, images: &imagePool, imageShare: index == 0 ? 0.12 : 0.05) }))
        }
        groups.append(DemoLibrary.DemoProject(
            name: "", icon: .folder, color: "", pinned: false, directory: nil,
            cards: (0..<defaultCards).map { _ in card(&random, images: &imagePool, imageShare: 0.03) }))
        // 用剩的图分给大项目最近的卡，保证 300 张都用上
        var big = groups[0]
        for (offset, hash) in imagePool.enumerated() where offset < big.cards.count {
            big.cards[offset].text += "\n\n" + CueFormat.imageMarkup(id: hash)
        }
        groups[0] = big

        let tasks: [DemoLibrary.DemoTask] = (0..<200).map { index in
            (groups[index % projectCount].name, sentence(&random, chinese: index % 3 != 0, words: 4...10), index % 5 == 0)
        }
        try await DemoLibrary.seed(store, groups: groups, tasks: tasks)

        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let projects = try await store.projects()
        for (index, project) in projects.prefix(boundProjects).enumerated() {
            try await store.setDirectory("\(home)Project/perf-\(index)", for: project.id)
        }
        let cards = try await store.cards(in: projects[0].id) + store.cards(in: projects[5].id)
        let targets = ["cuepad", "atlas", "review", "deploy", "notes"]
        for index in 0..<500 {
            let card = cards[random.next(cards.count)]
            let name = targets[index % targets.count]
            try await store.recordSend(card.body, to: SendTarget(kind: .piSession, name: name), card: card.id)
        }
        for index in 0..<piSessionCount {
            let cwd = index % 2 == 0 ? "\(home)Project/perf-\(index % boundProjects)" : "/Users/dev/work/repo-\(index)"
            try await store.upsertPiSession(IndexedSession(
                id: "perf-\(index)", path: "/tmp/perf-\(index).jsonl", cwd: cwd,
                title: sentence(&random, chinese: index % 2 == 0, words: 3...9),
                lastActivityAt: .now.addingTimeInterval(-Double(index) * 3_600)), host: "perf-mac")
        }
        for (index, rounds) in chatRounds.enumerated() { try await seedChat("perf-\(index)", rounds: rounds, random: &random, store: store) }
        try await seedCue(random: &random, store: store)
    }

    private static let cueRounds = 60
    private static let cueRenewEvery = 25

    private static func seedCue(random: inout SeededRandom, store: CueStore) async throws {
        _ = try await store.updateCueProfile { profile in
            profile.hostID = "perf-mac"
            profile.enabledAt = .now
        }
        for round in 0..<cueRounds {
            if round > 0, round % cueRenewEvery == 0 {
                _ = try await store.addCueMessage(.handoff, text: "**在做**\n- " + sentence(&random, chinese: true, words: 8...20))
            }
            let you = try await store.addCueMessage(.you, text: sentence(&random, chinese: round % 3 != 0, words: 6...30))
            try await store.markCueMessagesDelivered([you.id])
            _ = try await store.recordCueRound(nil, startedAt: .now, answersYou: true, tools: tools(&random))
            _ = try await store.addCueMessage(.cue, text: answer(&random, round: round))
            if round % 4 == 1 {
                _ = try await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: tools(&random), wake: .idle)
                _ = try await store.addCueMessage(.note, text: sentence(&random, chinese: true, words: 6...18))
            }
        }
    }

    private static func seedChat(_ sessionID: String, rounds: Int, random: inout SeededRandom, store: CueStore) async throws {
        let start = Date.now.addingTimeInterval(-Double(rounds) * 300)
        let turns = (0..<rounds).map { round in
            let asked = start.addingTimeInterval(Double(round) * 300)
            return DebugScene.ChatTurn(
                you: sentence(&random, chinese: round % 3 != 0, words: 6...30), pi: answer(&random, round: round),
                tools: round % 4 == 3 ? nil : tools(&random), asked: asked, answered: asked.addingTimeInterval(90))
        }
        try await DebugScene.writeChat(sessionID, turns, store: store)
    }

    /// 一轮回答：长段落、列表、表格、代码块轮换。
    private static func answer(_ random: inout SeededRandom, round: Int) -> String {
        let chinese = round % 2 == 0
        func paragraph(_ random: inout SeededRandom) -> String {
            sentence(&random, chinese: chinese, words: 12...40) + sentence(&random, chinese: chinese, words: 8...30)
        }
        switch round % 5 {
        case 0: return paragraph(&random) + "\n\n" + paragraph(&random) + "\n\n" + paragraph(&random)
        case 1: return paragraph(&random) + "\n\n" + (1...6).map { "- **\($0)** " + sentence(&random, chinese: chinese, words: 4...14) }.joined(separator: "\n")
        case 2:
            return paragraph(&random) + "\n\n| 项 | 结果 | 说明 |\n|:--|--:|:--|\n"
                + (1...5).map { "| 用例 \($0) | \(random.next(100)) | " + sentence(&random, chinese: chinese, words: 3...10) + " |" }.joined(separator: "\n")
        case 3:
            return paragraph(&random) + "\n\n```swift\n" + (1...18).map { "let value\($0) = compute(\($0), retry: \(random.next(5)))" }.joined(separator: "\n") + "\n```"
        default: return paragraph(&random)
        }
    }

    private static func tools(_ random: inout SeededRandom) -> PiChatMessage.Tools {
        let edits = random.next(4), reads = random.next(6), commands = random.next(5)
        var items: [PiChatMessage.Tools.Item] = []
        for _ in 0..<edits { items.append(.init(kind: .edit, target: "src/module\(random.next(40)).swift", added: random.next(60), removed: random.next(20))) }
        for _ in 0..<reads { items.append(.init(kind: .read, target: "docs/note\(random.next(40)).md")) }
        for _ in 0..<commands { items.append(.init(kind: .command, target: "pnpm test --filter pkg\(random.next(9))")) }
        return .init(steps: items.count, items: items)
    }

    private static func card(_ random: inout SeededRandom, images: inout ArraySlice<String>, imageShare: Double) -> (days: Double, text: String, favorite: Bool) {
        let chinese = random.unit() < 0.7
        var lines = [sentence(&random, chinese: chinese, words: 2...8), ""]
        for _ in 0..<(1 + random.next(8)) {
            lines.append((0..<(1 + random.next(5))).map { _ in sentence(&random, chinese: chinese, words: 6...24) }.joined(separator: chinese ? "" : " "))
        }
        if random.unit() < imageShare, let hash = images.popFirst() {
            lines.insert(CueFormat.imageMarkup(id: hash), at: 2)
        }
        // 一年内，越近越密
        let days = 365 * pow(random.unit(), 2.2)
        return (days, lines.joined(separator: "\n"), random.unit() < 0.004)
    }

    private static func sentence(_ random: inout SeededRandom, chinese: Bool, words: ClosedRange<Int>) -> String {
        let count = words.lowerBound + random.next(words.count)
        if chinese {
            return (0..<count).map { _ in chineseWords[random.next(chineseWords.count)] }.joined() + "。"
        }
        let text = (0..<count).map { _ in englishWords[random.next(englishWords.count)] }.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    /// 300 张内容各不相同的大图（存储按内容去重），并行生成。
    nonisolated private static func storeImages(_ store: CueStore) throws -> [String] {
        let hashes = Mutex([String?](repeating: nil, count: imageCount))
        let failure = Mutex<(any Error)?>(nil)
        DispatchQueue.concurrentPerform(iterations: imageCount) { index in
            do {
                let hash = try store.files.store(photo(seed: UInt64(index) + 1))
                hashes.withLock { $0[index] = hash }
            } catch {
                failure.withLock { $0 = error }
            }
        }
        if let error = failure.withLock({ $0 }) { throw error }
        return hashes.withLock { $0.compactMap { $0 } }
    }

    /// 像照片的 4032×3024 JPEG：低分辨率噪声放大成柔和的色块，再叠几块渐变。
    nonisolated private static func photo(seed: UInt64) -> Data {
        var random = SeededRandom(seed: seed)
        let small = 252, smallHeight = 189
        var pixels = [UInt8](repeating: 255, count: small * smallHeight * 4)
        let base = (random.next(200), random.next(200), random.next(200))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = UInt8(min(255, base.0 + random.next(56)))
            pixels[i + 1] = UInt8(min(255, base.1 + random.next(56)))
            pixels[i + 2] = UInt8(min(255, base.2 + random.next(56)))
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let noise = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: small, height: smallHeight, bitsPerComponent: 8, bytesPerRow: small * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        }
        let width = 4032, height = 3024
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(noise, in: CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<12 {
            let rect = CGRect(x: random.next(width), y: random.next(height), width: 200 + random.next(1600), height: 200 + random.next(1200))
            context.setFillColor(red: random.unit(), green: random.unit(), blue: random.unit(), alpha: 0.35)
            context.fillEllipse(in: rect)
        }
        return DemoLibrary.encode(context.makeImage()!, as: .jpeg, quality: 0.85)
    }

    private static let projectWords = ["发布", "增长", "研究", "运营", "客户端", "后端", "设计系统", "数据", "招聘", "文档"]
    private static let icons: [ProjectIcon] = [.folder, .sparkles, .globe, .hammer, .book, .target, .briefcase, .lightbulb]
    private static let colors = ["#A260C4", "#D9774B", "#3AA088", "#3F8FB8", "#C9A227", "#5E9E5A", "#C25A6E", "#8A8A84"]
    private static let chineseWords = [
        "投送", "队列", "重试", "边界", "编辑器", "变量", "模板", "同步", "冲突", "附件", "搜索", "索引", "性能", "内存", "首屏",
        "卡片", "项目", "任务", "会话", "终端", "发布", "验收", "数据", "迁移", "回收站", "缓存", "布局", "动画", "滚动", "预览",
        "我们", "需要", "先把", "然后", "如果", "因为", "所以", "已经", "还没", "可以", "确认", "处理", "失败", "成功", "上线",
    ]
    private static let englishWords = [
        "queue", "retry", "boundary", "editor", "template", "sync", "conflict", "attachment", "search", "index", "latency", "memory",
        "the", "a", "we", "should", "first", "then", "when", "because", "before", "after", "release", "review", "api", "cache",
        "layout", "scroll", "preview", "session", "terminal", "migration", "budget", "deadline", "customer", "draft", "notes",
    ]
}

/// 可复现的伪随机数（SplitMix64）。
nonisolated struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0..<upperBound
    mutating func next(_ upperBound: Int) -> Int { Int(nextUInt64() % UInt64(upperBound)) }

    /// 0..<1
    mutating func unit() -> Double { Double(nextUInt64() >> 11) / Double(1 << 53) }
}
#endif
