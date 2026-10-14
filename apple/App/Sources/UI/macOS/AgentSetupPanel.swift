#if os(macOS)
import SwiftUI

/// 接入 Agent：首次启动出现一次（`Workspace.showsAgentSetup`），之后同样的几行在设置里。
/// 一句话说接入后双向能做什么、会写什么，下面是与设置同一份的开关行（`AgentRows`、`CommandLineToolRow`）——开关就是同意，不预先勾选，点了才写；
/// 底下一句教怎么用。只有"完成"一个主按钮，关掉就是不接。
struct AgentSetupPanel: View {
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(Mascot.hello.rawValue).resizable().scaledToFit().frame(width: 64, height: 64)
                    .scaleEffect(shown || reduceMotion ? 1 : 0.9)
                    .opacity(shown ? 1 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("把 Agent 接进 CuePad").font(Typography.heading).foregroundStyle(palette.ink)
                    Text("接入后它的会话出现在 CuePad 里：在 Mac 和手机上看进展、发话、回答提问，也能在后台开会话。每家写什么列在下面，关掉就删干净。")
                        .font(Typography.secondary).foregroundStyle(palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24).padding(.top, 24)
            // 不用 Form：浮层里的 Form 给开关报错位置、没有按下动作，读屏与辅助控制点不中（macOS 27 实测），这里按设置窗口的样子自己排
            VStack(spacing: 12) {
                group { AgentRows() }
                group { CommandLineToolRow() }
            }
            .font(Typography.body)
            .labeledContentStyle(RowLayout())
            .labelStyle(RowLabel())
            .controlSize(.mini)
            .padding(.horizontal, 20).padding(.vertical, 16)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("接好后，对 Agent 说「记到 CuePad」「看看 CuePad 里的任务」")
                        .foregroundStyle(palette.ink2)
                    Text("之后在设置里随时改")
                        .foregroundStyle(palette.ink3)
                }
                .font(Typography.meta)
                Spacer(minLength: 8)
                Button("完成") { close() }
                    .buttonStyle(ControlButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(width: 520)
        .background(palette.desk)
        .onAppear { withAnimation(reduceMotion ? Motion.quick : Motion.snappy) { shown = true } }
    }

    /// 与设置窗口的分组同一种样子：纸色圆角底，行间一条细线。
    private func group(@ViewBuilder _ rows: () -> some View) -> some View {
        VStack(spacing: 0) {
            Group(subviews: rows()) { subviews in
                ForEach(subviews) { row in
                    row.padding(.horizontal, 12).padding(.vertical, 9)
                    if row.id != subviews.last?.id { Divider().padding(.leading, 12) }
                }
            }
        }
        .background(palette.paper, in: .rect(cornerRadius: 10, style: .continuous))
    }
}

/// 设置行（`SettingRow`）在 Form 外的排法，同 Form 里：名称在左、控件靠右。
private struct RowLayout: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}

/// 同 Form 里：图标一列，名称与它下面的状态上下排。
private struct RowLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
            VStack(alignment: .leading, spacing: 2) { configuration.title }
        }
    }
}
#endif
