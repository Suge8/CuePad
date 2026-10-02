#if os(macOS) && DEBUG
import CoreGraphics
import CueStore
import CueText
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// 性能测量用的大资料库（`-CuePadSeed perf`，只在 Debug 构建、隔离资料库、库为空时写入）：
/// 50 个项目、5000 张卡（一个大项目 1200 张、未归档 300 张，其余分给 49 个项目），其中 300 张带 4032×3024 的 JPEG；
/// 修改时间分布在一年内；另有 200 条任务、500 条发送记录、200 个 Pi 历史会话。内容由固定种子生成，每次一样。
enum PerfLibrary {
    static let projectCount = 50
    static let cardCount = 5000
    nonisolated static let imageCount = 300
    static let piSessionCount = 200
    static let bigProject = "大项目"
    private static let bigProjectCards = 1200
    private static let inboxCards = 300
    private static let boundProjects = 10

    static func seed(_ store: CueStore) async throws {
        var random = SeededRandom(seed: 20261002)
        let images = try storeImages(store)
        var imagePool = images[...]
        var groups: [DemoLibrary.DemoProject] = []
        let otherCards = (cardCount - bigProjectCards - inboxCards) / (projectCount - 1)
        for index in 0..<projectCount {
            let name = index == 0 ? bigProject : "项目 \(index) · \(projectWords[index % projectWords.count])"
            let count = index == 0 ? bigProjectCards : otherCards + (index <= (cardCount - bigProjectCards - inboxCards) % (projectCount - 1) ? 1 : 0)
            groups.append(DemoLibrary.DemoProject(
                name: name, icon: icons[index % icons.count], color: colors[index % colors.count], pinned: index < 3, directory: nil,
                cards: (0..<count).map { _ in card(&random, images: &imagePool, imageShare: index == 0 ? 0.12 : 0.05) }))
        }
        groups.append(DemoLibrary.DemoProject(
            name: "", icon: "", color: "", pinned: false, directory: nil,
            cards: (0..<inboxCards).map { _ in card(&random, images: &imagePool, imageShare: 0.03) }))
        // 用剩的图分给大项目最近的卡，保证 300 张都用上
        var big = groups[0]
        for (offset, hash) in imagePool.enumerated() where offset < big.cards.count {
            big.cards[offset].text += "\n\n" + CueFormat.imageMarkup(id: hash)
        }
        groups[0] = big

        let tasks: [DemoLibrary.LegacyTask] = (0..<200).map { index in
            (groups[index % projectCount].name, sentence(&random, chinese: index % 3 != 0, words: 4...10), index % 5 == 0)
        }
        let source = FileManager.default.temporaryDirectory.appending(path: "cuepad-perf-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: source) }
        try DemoLibrary.writeLegacy(groups, tasks: tasks, to: source)
        _ = try await store.importElectronLibrary(from: source)

        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let projects = try await store.projects()
        for (index, project) in projects.prefix(boundProjects).enumerated() {
            try await store.setDirectory("\(home)Project/perf-\(index)", for: project.id)
        }
        let cards = try await store.cards(in: projects[0].id) + store.cards(in: projects[5].id)
        let targets = ["cuepad", "atlas", "Ghostty", "Cursor", "剪贴板"]
        for index in 0..<500 {
            let card = cards[random.next(cards.count)]
            let name = targets[index % targets.count]
            try await store.recordSend(card.body, to: SendTarget(kind: index % 5 < 2 ? .piSession : .app, name: name), card: card.id)
        }
        for index in 0..<piSessionCount {
            let cwd = index % 2 == 0 ? "\(home)Project/perf-\(index % boundProjects)" : "/Users/dev/work/repo-\(index)"
            try await store.upsertPiSession(PiSession(
                id: "perf-\(index)", path: "/tmp/perf-\(index).jsonl", cwd: cwd,
                title: sentence(&random, chinese: index % 2 == 0, words: 3...9),
                lastActivityAt: .now.addingTimeInterval(-Double(index) * 3_600)))
        }
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
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private static let projectWords = ["发布", "增长", "研究", "运营", "客户端", "后端", "设计系统", "数据", "招聘", "文档"]
    private static let icons = ["folder", "sparkles", "globe", "hammer", "book", "target", "briefcase", "lightbulb"]
    private static let colors = ["#A260C4", "#D9774B", "#6A6FD1", "#3F8FB8", "#C9A227", "#5E9E5A", "#C25A6E", "#8A8A84"]
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
