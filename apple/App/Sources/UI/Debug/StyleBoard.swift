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
            ("signature", palette.signature), ("selection", palette.selection), ("attention", palette.attention),
            ("failure", palette.failure), ("variable", palette.variable), ("bubble", palette.bubble),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(tokens, id: \.0) { name, color in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color).frame(height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.hair))
                    Text(name).font(.caption2.monospaced()).foregroundStyle(palette.ink2)
                }
            }
        }
    }

    private var surfaces: some View {
        HStack(spacing: 12) {
            Text("纸").frame(maxWidth: .infinity, minHeight: 72).paper(radius: 16, lifted: true)
            Text("玻璃").frame(maxWidth: .infinity, minHeight: 72).glass(in: .rect(cornerRadius: 16))
        }
        .foregroundStyle(palette.ink)
    }

    private var presses: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {} label: { Image(systemName: "plus").frame(width: 44, height: 44).glass(in: .circle) }
                    .buttonStyle(PressStyle(scale: Press.button))
                Button {} label: { Text("胶囊").padding(.horizontal, 16).frame(height: 36).background(palette.fill, in: .capsule) }
                    .buttonStyle(PressStyle())
                Button("主按钮") {}.prominentButton().controlSize(.large)
                FilterChip(on: true) { Text("选中") }
            }
            .foregroundStyle(palette.ink)
            Button {} label: {
                Text("整张卡片").frame(maxWidth: .infinity, minHeight: 64).paper(radius: 16)
            }
            .buttonStyle(CardPressStyle())
            Button {} label: {
                Text("一行").frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 16)
                    .contentShape(.rect)
            }
            .buttonStyle(RowPressStyle())
            .paper(radius: 14)
        }
        .foregroundStyle(palette.ink)
    }

    private var motion: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                PiStateDot(state: .known(.thinking), size: 10)
                PiStateDot(state: .known(working ? .tool : .settled), size: 10)
                PiStateDot(state: .known(.waitingForUser), size: 10)
                PiStateDot(state: .known(.error), size: 10)
                PiStateDot(state: .known(.settled), unread: true, size: 10)
                PiStateDot(state: .known(.ended), size: 10)
                Spacer()
                Text("\(count)").font(.title.weight(.semibold).monospacedDigit()).foregroundStyle(palette.ink).counting(count)
            }
            VStack(spacing: 0) {
                ForEach(rows, id: \.self) { row in
                    Text("第 \(row) 行").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 16)
                        .transition(Motion.item)
                }
            }
            .paper(radius: 14)
            .foregroundStyle(palette.ink)
        }
    }

    private func play() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(0.5))
            tick += 1
            if tick % 3 == 0 { count += 1 }
            if tick % 4 == 0 {
                withAnimation(Motion.snappy) {
                    if rows.count > 3 { rows.removeFirst() } else { rows.append((rows.last ?? 0) + 1) }
                }
            }
            if tick % 6 == 0 { working.toggle() }
        }
    }
}
#endif
