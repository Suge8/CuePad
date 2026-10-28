#if os(iOS) && DEBUG
import SwiftUI

/// 视觉样板（`-CuePadScene style`）：颜色 token、纸与玻璃、各类按压、状态标与动效放在一页，改主题时对照，录屏取帧。
/// 打开后自动演一遍：计数每 1.5 秒加一（数字滚动）、列表每 2 秒进出一行、第二个状态标每 3 秒在工作 ↔ 做完之间切（看呼吸与涟漪）。
struct StyleBoard: View {
    @Environment(\.palette) private var palette
    @State private var count = 3
    @State private var rows = [1, 2, 3]
    @State private var working = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                swatches
                surfaces
                presses
                motion
                EmptyState(mascot: .clean, title: "都处理完了", message: "空态里的吉祥物")
            }
            .padding(16)
        }
        .background(palette.desk)
        .task { await play() }
    }

    private var swatches: some View {
        let tokens: [(String, Color)] = [
            ("sidebar", palette.sidebar), ("desk", palette.desk), ("paper", palette.paper),
            ("ink", palette.ink), ("ink2", palette.ink2), ("ink3", palette.ink3),
            ("signature", palette.signature), ("selection", palette.selection), ("waiting", palette.waiting),
            ("failure", palette.failure), ("replied", palette.replied), ("bubble", palette.bubble),
            ("hair", palette.hair), ("fill", palette.fill), ("track", palette.track), ("signatureFill", palette.signatureFill),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(tokens, id: \.0) { name, color in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: Radius.block).fill(color).frame(height: 44)
                        .overlay(RoundedRectangle(cornerRadius: Radius.block).strokeBorder(palette.hair))
                    Text(name).font(.caption2.monospaced()).foregroundStyle(palette.ink2)
                }
            }
        }
    }

    private var surfaces: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("纸").frame(maxWidth: .infinity, minHeight: 72).paper(lifted: true)
                Text("玻璃").frame(maxWidth: .infinity, minHeight: 72).glass(in: .rect(cornerRadius: Radius.card))
            }
            HStack(spacing: 8) {
                ForEach(Self.radii, id: \.name) { radius in
                    Text(radius.name).font(.caption2.monospaced()).frame(maxWidth: .infinity, minHeight: 56)
                        .background(palette.fill, in: .rect(cornerRadius: radius.value))
                }
            }
        }
        .foregroundStyle(palette.ink)
    }

    private static let radii: [(name: String, value: CGFloat)] = [
        ("chip", Radius.chip), ("block", Radius.block), ("card", Radius.card), ("sheet", Radius.sheet), ("field", Radius.field),
    ]

    private var presses: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {} label: { Image(.add).frame(width: 44, height: 44).glass(in: .circle, ink: .clear) }
                    .buttonStyle(PressStyle(.button))
                Button {} label: { Text("胶囊").padding(.horizontal, 16).frame(height: 36).background(palette.fill, in: .capsule) }
                    .buttonStyle(PressStyle())
                Button("主按钮") {}.buttonStyle(ControlButtonStyle(kind: .primary)).controlSize(.large)
                FilterChip(on: true) { Text("选中") }
            }
            .foregroundStyle(palette.ink)
            Button {} label: {
                Text("整张卡片").frame(maxWidth: .infinity, minHeight: 64).paper()
            }
            .buttonStyle(PressStyle(.card))
            Button {} label: {
                Text("一行").frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.row)
            .rowPaper(cornerRadius: Radius.card)
        }
        .foregroundStyle(palette.ink)
    }

    private static let statuses: [PiShown.Status] = [
        .working(.thinking), .delivery(.inTransit(.sending)), .delivery(.inTransit(.waking)), .asking, .awaitsReply, .failed(.other), .delivery(.failed(.timedOut)),
        .cueAsking, .unread, .idle, .resting, .fresh, .ended, .interrupted, .unknown,
    ]

    private var motion: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                PiStateDot(shown: PiShown(status: working ? .working(.tool) : .idle), size: 10)
                Spacer()
                Text("\(count)").font(.title.weight(.semibold).monospacedDigit()).foregroundStyle(palette.ink).counting(count)
            }
            // 全部会话状态：状态标、状态词与颜色
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(Self.statuses, id: \.self) { status in
                    let shown = PiShown(status: status)
                    HStack(spacing: 6) {
                        PiStateDot(shown: shown, size: 8)
                        Text(shown.label).font(.subheadline.weight(shown.isUnread ? .semibold : .medium)).foregroundStyle(shown.labelTint(palette))
                            .lineLimit(1)
                    }
                }
            }
            VStack(spacing: 0) {
                ForEach(rows, id: \.self) { row in
                    Text("第 \(row) 行").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 16)
                        .transition(.opacity)
                }
            }
            .paper()
            .foregroundStyle(palette.ink)
        }
    }

    private func play() async {
        var tick = 0
        while !Task.isCancelled {
            await Task.wait(for: .seconds(0.5))
            tick += 1
            if tick % 3 == 0 { count += 1 }
            if tick % 4 == 0 {
                withAnimation(Motion.nudge) {
                    if rows.count > 3 { rows.removeFirst() } else { rows.append((rows.last ?? 0) + 1) }
                }
            }
            if tick % 6 == 0 { working.toggle() }
        }
    }
}
#endif
