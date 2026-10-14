import SwiftUI

/// 对话里上下文换了的地方（会话页的压缩、Cue 页的换新）：一条细线，中间一颗小胶囊写这里换了什么；它以上的话 Agent 不再逐句看得到。
/// 带交接备忘的（Cue 换新时写下的那一份，`CueMessage` 的 handoff）点胶囊在弹层里看备忘（不在对话里就地展开：贴着最新时内容往上长，
/// 点的那条分隔会被顶出屏幕）；没有的只是一条分隔。刻度滑条上它是一个点（`ChatMark.Kind.boundary`），从滑条跳过来时胶囊描一圈。
struct ContextBoundary: View {
    let title: String
    var time: Date?
    /// 换新时写下的交接备忘（Markdown）。
    var memo: String?
    var highlighted = false
    @State private var showsMemo = false
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            rule
            capsule.layoutPriority(1)
            rule
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .transition(.entry)
    }

    private var rule: some View { Rectangle().fill(palette.hair).frame(height: 1) }

    @ViewBuilder private var capsule: some View {
        let label = HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
            Text(title).lineLimit(1)
            if let time { Text(time.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(palette.ink3) }
            if memo != nil { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
        }
        .font(Typography.meta).foregroundStyle(palette.ink2)
        .padding(.horizontal, 10).frame(minHeight: 26)
        .background(palette.fill, in: .capsule)
        .overlay { Capsule().strokeBorder(palette.signature, lineWidth: 2).opacity(highlighted ? 1 : 0) }
        .animation(Motion.quick, value: highlighted)
        if let memo {
            Button { showsMemo = true } label: { label.contentShape(.capsule) }
                .buttonStyle(PressStyle(.button))
                .frame(minHeight: 44)
                .accessibilityHint("看交接备忘")
                .panel(isPresented: $showsMemo) { HandoffMemo(time: time, memo: memo) }
        } else {
            label.accessibilityElement(children: .combine)
        }
    }
}

/// 换新时写下的交接备忘（点对话里那条分隔打开）：它带着这份备忘接着做，上面的对话已不在眼前。
private struct HandoffMemo: View {
    let time: Date?
    let memo: String
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette

    private static let title = "交接备忘"

    private var text: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(Dotted(time.map { $0.formatted(date: .abbreviated, time: .shortened) }, "换上下文前写下：之后它靠这份备忘接着做，分隔上面的对话已不在它眼前"))
                    .font(Typography.meta).foregroundStyle(palette.ink3)
                MarkdownText(source: memo).equatable()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    #if os(macOS)
    var body: some View {
        VStack(spacing: 6) {
            PanelHeader(Self.title)
            text
        }
        .padding(.top, 18)
        .frame(width: 520).frame(maxHeight: 560)
        .background(palette.desk)
    }
    #else
    var body: some View {
        NavigationStack {
            text
                .background(palette.desk)
                .navigationTitle(Self.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { close() } }
                }
        }
        .presentationDetents([.medium, .large])
    }
    #endif
}
