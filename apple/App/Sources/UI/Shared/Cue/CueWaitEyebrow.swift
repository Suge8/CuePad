import CueStore
import SwiftUI

/// 拍板卡顶上的眉题行（小号、淡墨，几样靠间距与深浅分开，不用"·"拼）：
/// - 左边：所在项目（项目自己的图标与颜色，`ProjectGlyph`，同看板与侧栏）与项目名，再是这件事的名字（`TaskBoard.Wait.title`：任务名或会话名，同看板的卡，深一档）。
///   名字点得到：Cue 的提问打开它落在的任务（`CueTaskButton`，接力也落在这里），会话在问的进会话（谁在问就是这个会话，打开会话的入口也是它）；
///   没落在任务上的提问没有这件事，写 Cue 的名字、不可点。不属于哪个项目的不写项目。地方不够先截名字。
/// - 右边：等了多久（"刚刚""已等 38 分钟"），不止一件时再是"1/3"第几件；Mac 上计数两边各一颗小箭头换一件（`step`），手机上左右滑卡换（`CueWaitDock`）。
struct CueWaitEyebrow: View {
    let wait: TaskBoard.Wait
    let index: Int
    let count: Int
    let step: (Int) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static let height: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            project
            name.layoutPriority(-1)
            Spacer(minLength: 12)
            LiveText(style: PiClock.Waited(since: wait.since)).monospacedDigit().fixedSize()
            if count > 1 { position.padding(.leading, 10) }
        }
        .font(Typography.caption)
        .foregroundStyle(palette.ink3)
        .frame(height: Self.height)
    }

    @ViewBuilder private var project: some View {
        if let project = workspace.catalog?.project(wait.project) {
            HStack(spacing: 2) {
                ProjectGlyph(project: project, size: 11)
                Text(project.shownName).lineLimit(1)
            }
            .fixedSize()
            .padding(.trailing, 10)
        }
    }

    @ViewBuilder private var name: some View {
        let title = wait.title ?? workspace.cue.name
        switch wait.wait {
        case .message(let message, _):
            if let task = wait.item?.task.id ?? message.taskID {
                CueTaskButton(task: task) { label(title, linked: true).relaySpot(task: task) }
                    .accessibilityHint("打开任务")
            } else {
                label(title, linked: false)
            }
        case .session(let session, _):
            Button { workspace.openSession(session.id, sessionID: session.sessionID) } label: { label(title, linked: true) }
                .buttonStyle(PressStyle())
                .accessibilityHint("打开会话")
        }
    }

    private func label(_ title: String, linked: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title).lineLimit(1)
            if linked { Image(.forward).font(Glyph.mark) }
        }
        .foregroundStyle(palette.ink2)
        // 小字本身矮：点得到的范围往上下扩，不撑高这一行
        .contentShape(.rect.inset(by: -Self.reach))
    }

    private var position: some View {
        HStack(spacing: 0) {
            #if os(macOS)
            arrow(.back, enabled: index > 0, label: "上一件") { step(-1) }
            #endif
            Text("\(index + 1)/\(count)").monospacedDigit()
                .accessibilityLabel("第 \(index + 1) 件，共 \(count) 件")
            #if os(macOS)
            arrow(.forward, enabled: index < count - 1, label: "下一件") { step(1) }
            #endif
        }
        .fixedSize()
    }

    #if os(macOS)
    private func arrow(_ icon: Icon, enabled: Bool, label: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon).font(Glyph.mark).frame(width: Self.height, height: Self.height).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.inline))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
    #endif

    private static let reach: CGFloat = 10
}
