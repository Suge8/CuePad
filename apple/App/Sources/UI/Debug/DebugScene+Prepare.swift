#if DEBUG
import CueStore
import SwiftUI

// 摆画面前的准备：按参数摆库、输入框的预设、找卡与滚动。
extension DebugScene {
    static func prepareLibrary(_ workspace: Workspace) async -> UUID? {
        let store = workspace.services.store
        // -CuePadSampleCrash YES：存一份样例崩溃诊断，设置里出现"上次崩溃"（配 -CuePadCrashSheet YES 直接打开摘要）
        if defaults.bool(forKey: "CuePadSampleCrash") { workspace.services.diagnostics.record([sampleCrash]) }
        #if os(macOS)
        if defaults.string(forKey: "CuePadSeed") == "perf", (try? await store.projects().allSatisfy(\.isDefault)) == true {
            do { try await PerfLibrary.seed(store) } catch { workspace.fail(error) }
        }
        #endif
        if defaults.bool(forKey: "CuePadDemo"), (try? await store.projects().allSatisfy(\.isDefault)) == true {
            do { try await DemoLibrary.seed(store) } catch { workspace.fail(error) }
        }
        if defaults.bool(forKey: "CuePadDemo") { await seedMacAgents(workspace.services) }
        await presetSync(workspace.services)
        guard let name = defaults.string(forKey: "CuePadProject"),
              let project = try? await store.projects().first(where: { $0.name == name })
        else { return nil }
        let many = defaults.integer(forKey: "CuePadManyTasks")
        if many > 0, ((try? await store.taskCounts(in: project.id).open) ?? 0) < many {
            for index in 1...many { _ = try? await store.createTask("压力任务 \(index)：画布与节点的一段说明", in: project.id) }
        }
        if defaults.bool(forKey: "CuePadNoIdeas") {
            for card in (try? await store.cards(in: project.id)) ?? [] { try? await store.trashCard(card.id) }
        }
        #if os(macOS)
        workspace.show(.project(project.id))
        #endif
        return project.id
    }

    /// `-CuePadComposer <cards|attachments|lines|slash>`（配 session、newsession 画面，iOS 与 Mac）：输入框出现时 cards 打开选卡片面板，slash 写进 "/re" 弹出斜杠命令面板，
    /// attachments 带上一张卡片（`-CuePadCard` 挑哪张）并放进两张演示图片，lines 写进 9 行文字（看文字区长到 6 行后在里面滚）。
    /// ＋ 菜单是系统菜单、不能代为展开：截图时按一下 ＋（iPhone 17 Pro 回复框：`axe touch -x 37 -y 810 --down --up --delay 0.15`；axe 的 tap 太快，菜单不开）。
    static func presetComposer(_ draft: Binding<ComposerDraft>, source: Binding<ComposerSource?>, store: CueStore) async {
        switch defaults.string(forKey: "CuePadComposer") {
        case "cards":
            // 等推入页面的转场走完再弹，转场中弹出的面板会被系统丢掉
            try? await Task.sleep(for: .seconds(1))
            source.wrappedValue = .cards
        case "attachments":
            // 先挑默认项目里的，没有再挑第一个项目里的
            var id = await card(in: Project.defaultID, store: store)
            if id == nil, let project = try? await store.projects().first { id = await card(in: project.id, store: store) }
            if let id, let card = try? await store.card(id) {
                draft.wrappedValue.attach(card)
            }
            draft.wrappedValue.images = [(0.85, 0.47, 0.29), (0.25, 0.56, 0.72)].map { PickedImage(data: swatch(red: $0.0, green: $0.1, blue: $0.2)) }
        case "lines":
            draft.wrappedValue.text = (1...9).map { "第 \($0) 行" }.joined(separator: "\n")
        case "slash":
            draft.wrappedValue.text = "/re"
        default:
            break
        }
    }

    private static func swatch(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
        let size = CGSize(width: 240, height: 180)
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        return DemoLibrary.encode(context.makeImage()!)
    }

    /// `-CuePadCard` 指定（或最近修改）的一张散放的灵感。
    static func card(in project: UUID, store: CueStore) async -> UUID? {
        let cards = (try? await store.cards(in: project)) ?? []
        let prefix = defaults.string(forKey: "CuePadCard") ?? ""
        return cards.filter { $0.body.hasPrefix(prefix) }.max { $0.modifiedAt < $1.modifiedAt }?.id
    }

    static func scrollIfNeeded(_ proxy: ScrollViewProxy) {
        guard scene == "older" else { return }
        later(.milliseconds(300)) { proxy.scrollTo(ScrollAnchor.older, anchor: UnitPoint(x: 0.5, y: 0.35)) }
    }

    /// 产品视图读的启动预设（`DebugHooks.preset`）。
}
#endif
