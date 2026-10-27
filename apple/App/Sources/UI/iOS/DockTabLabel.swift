#if os(iOS)
import SwiftUI
import UIKit

/// 标签栏上一个 tab 的字与图标（`DockRoot`）。有事时图标角上带点，不用系统的红角标（`TabMarks`）；读屏把点说的那几样念出来。
struct DockTabLabel: View {
    let tab: Route
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        switch tab {
        case .shelf:
            let entry = SidebarOutline.Entry.projects
            let alert = services.macAlert
            Label { Text(entry.title) } icon: { TabMarks(icon: entry.icon, badge: alert.map { palette.color($0.tone) }).image }
                .accessibilityValue(alert?.title ?? "")
        case .progress:
            Label(SidebarOutline.Entry.progress.title, icon: SidebarOutline.Entry.progress.icon)
        default:
            let cue = workspace.cue
            let drafted = !cue.draft.isEmpty(accepting: .images)
            Label { Text(verbatim: cue.name) } icon: { TabMarks.cue(cue, drafted: drafted, palette: palette).image }
                .accessibilityValue(Dotted(cue.unread > 0 ? String(localized: "\(cue.unread) 条新消息") : nil, cue.now.spoken, drafted ? String(localized: "有草稿") : nil).spoken)
        }
    }
}

/// 标签栏图标角上的点：图标换成带点的符号变体（`Icon.platformImage(badge:status:)`，同 SF Symbols 的 *.badge，点与图形之间刻一圈缝）。
/// - 项目：同步到不了 Mac 时右上一颗，颜色按 `AppServices.macAlert` 的 tone（同设置那一行的点）。
/// - Cue 右上是对话：新消息石绿先于草稿（同原来 Cue 钮的角）。草稿用第三档墨色：气泡的牛皮纸做成一颗点，在标签栏的玻璃上浅色、深色都几乎看不见（实测）。
/// - Cue 右下是此刻的事，`CueNow.keyTone`：拍板赭黄、只有待回复墨色、在动或推进中靛青，其余不画（同灵动岛描边一条规则；位置同头像右下"在动"那颗点）。
///   两角各说一件，等你与新消息同时在也都看得见。
///
/// 为什么是符号变体、不在运行时合成一张图：标签栏只给图标上一种颜色，合成的位图要么整张跟着 tint（点也被染成选中色），要么整张原色
/// （图形的选中、未选中、深浅色都得照抄系统的颜色，系统一改就对不上）。符号分层：主体是 `.tintColor`，由标签栏照常上色，
/// 点是自己那一层的颜色；缝是几何，任何字号都利落；只多四个生成的符号（cue-symbols.py 的 `dotted`），运行时不画。
/// 图按点的组合与颜色记下来（`made`）：标签栏的 label 每次切 tab 都求值，点没变就还是同一张图，系统不重新上图。
struct TabMarks: Hashable {
    let icon: Icon
    var badge: Color?
    var status: Color?

    static func cue(_ cue: CueWatch, drafted: Bool, palette: Palette) -> TabMarks {
        let message = cue.unread > 0 ? palette.replied : drafted ? palette.ink3 : nil
        let tone = cue.now.keyTone
        return TabMarks(icon: .cue, badge: message, status: tone == .quiet ? nil : tone.color(palette))
    }

    var image: Image {
        if let made = Self.made[self] { return Image(uiImage: made) }
        guard let made = icon.platformImage(badge: badge.map { UIColor($0) }, status: status.map { UIColor($0) }) else { return Image(icon) }
        Self.made[self] = made
        return Image(uiImage: made)
    }

    /// 几种点乘几套颜色（深浅、增强对比度），一共几十张，不清。
    private static var made: [TabMarks: UIImage] = [:]
}
#endif
