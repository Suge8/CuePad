#if os(macOS)
import CueStore
import SwiftUI

extension View {
    /// 只给一出一收会挤动同一排旁边控件的（同步提醒、技能与规则的说明）用，其余按条件写。
    func keepsPlace(shown: Bool) -> some View {
        opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
    }
}

/// 打开、收起卡片只改动三处（收起按钮、编辑页图层、底部输入条的位置），各自读"打开的卡"：主窗口的视图体不读它，开合时不重算整个窗口。

struct CloseButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.overlay != nil {
            // 箭头比放大镜、"⋯"细瘦：大一号、粗一档，与它们一样重
            Button { workspace.overlay = nil } label: { Image(.back).font(Glyph.control.weight(.bold)) }
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .keyboardShortcut(.cancelAction)
            .help("收起（Esc）")
            .accessibilityLabel("收起")
            .padding(.trailing, Spacing.item)
        }
    }
}

/// 有同步就常驻一格圆钮宽，平时只是看不见（`keepsPlace`）：提醒一出一收不挤动左边的编辑页标题与项目名。
struct SyncAlertSlot: View {
    static func needed(_ services: AppServices) -> Bool {
        services.sync != nil && SyncSummary(services.syncState.status).tone != .calm
    }

    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        if services.sync != nil {
            let summary = SyncSummary(services.syncState.status)
            Button { SettingsPane.open(.general) } label: {
                Image(summary.icon).foregroundStyle(palette.color(summary.tone))
            }
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .help([summary.title, summary.detail, String(localized: "点按在设置里处理")].compactMap { $0 }.joined(separator: "\n"))
            .accessibilityLabel(summary.title)
            .keepsPlace(shown: summary.tone != .calm)
        }
    }
}

#endif
