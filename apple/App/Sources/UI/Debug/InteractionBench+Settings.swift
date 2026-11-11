#if DEBUG && (os(macOS) || os(iOS))
#if os(macOS)
import AppKit
#endif

/// 开设置、关设置（`-CuePadBench interact`，只在点名时量，不改全量里其余各项的先后与基线）：两端各做两遍，第一遍要现建那一页。
/// Mac 开的是设置窗口（同 ⌘,），它不在主窗口里，画面变化看不到（`seen` 为 false），看合计与最重一圈；iPhone 是冷启动后接着点设置（同侧栏的设置钮）、再回 Cue 页。
/// 每行的 `freezes` 见 `PerfProbe.freezes`。量法：`xc.sh perf ios 5 -CuePadInteractOnly "冷启动·Cue 页,开设置,关设置"`、`xc.sh perf mac 5 -CuePadInteractOnly 开设置,关设置`。
/// 首次开设置最重一圈 iPhone 164～195ms、Mac 111～152ms（超 28ms），再开 iPhone 52～88ms、Mac 1～31ms；开销在系统建 SwiftUI 表单与排版（模拟器上约四分之一是第一次用到类型时的 Swift 一致性查找），
/// 没有读库、文件读写或大计算。调试实例冷启动开设置时记到过一次 1.56 秒卡住，没能复现（Debug 7 次、Release 40 次都没有超 1 秒的一圈）。
enum SettingsBench {
    static let names: Set<String> = ["开设置", "关设置"]

    static func run(_ workspace: Workspace, only: Set<String>?, step: (String, () -> Void) async -> Void) async {
        guard let only, !only.isDisjoint(with: names) else { return }
        for _ in 0..<2 {
            #if os(macOS)
            await step("开设置") { SettingsPane.open(.general) }
            await step("关设置") { NSApp.windows.first { $0.contentViewController is NSTabViewController }?.orderOut(nil) }
            #else
            await step("开设置") { workspace.select(.settings) }
            await step("关设置") { workspace.select(.cue) }
            #endif
        }
    }
}
#endif
