#if os(iOS) && DEBUG
import CueStore
import SwiftUI

struct StyleBoard: View {
    @Environment(\.palette) private var palette
    @State private var count = 3
    @State private var rows = [1, 2, 3]
    @State private var working = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                controls
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

    private var surfaces: some View {
        HStack(spacing: 12) {
            Text("纸").frame(maxWidth: .infinity, minHeight: 72).paper(lifted: true)
            Text("玻璃").frame(maxWidth: .infinity, minHeight: 72).glass(in: .rect(cornerRadius: Radius.card))
        }
        .foregroundStyle(palette.ink)
    }

    private var presses: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {} label: { Image(.add).frame(width: 44, height: 44).glass(in: .circle, ink: .clear) }
                    .buttonStyle(PressStyle(.button))
                Button {} label: { Text("胶囊").padding(.horizontal, 16).frame(height: 36).background(palette.fill, in: .capsule) }
                    .buttonStyle(PressStyle())
                Button("主按钮") {}.buttonStyle(ControlButtonStyle(kind: .primary)).controlSize(.large)
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

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("主按钮") {}.buttonStyle(ControlButtonStyle(kind: .primary, size: .compact))
                Button {} label: { Text(verbatim: "次按钮") }.buttonStyle(ControlButtonStyle(size: .compact))
                Button {} label: { Text(verbatim: "安静") }.buttonStyle(ControlButtonStyle(kind: .quiet, size: .compact))
                Button {} label: { Image(.close) }.buttonStyle(ControlButtonStyle(kind: .round, size: .compact)).accessibilityLabel("关闭")
                HelpButton { Text(verbatim: "说明气泡里的一句").padding(16) }
            }
            HStack(spacing: 8) {
                ForEach(Self.sizes, id: \.name) { size in
                    Button(size.name) {}.buttonStyle(ControlButtonStyle(size: size.value))
                }
            }
            HStack(spacing: 8) {
                Text(verbatim: "关着").chip()
                Text("开着").chip(on: true)
                Text("项目").chip(menu: true)
                Text("全部").chip(on: true, menu: true)
            }
            SectionHeader("最近", count: 13)
            SectionHeader("重点", level: .group, icon: .pin)
            Button {} label: { LinkRow(title: Text(verbatim: "定时"), value: Text(verbatim: "8:00"), alert: palette.ink) { Image(.schedule) } }
                .buttonStyle(.row)
                .rowPaper(cornerRadius: Radius.card)
            HStack(spacing: 12) {
                Chevron(.forward)
                Chevron(.expand)
                Chevron(.back)
                StatusDot(color: palette.ink)
                StatusDot(color: palette.replied, rim: palette.desk)
            }
        }
        .foregroundStyle(palette.ink)
    }

    private static let sizes: [(name: String, value: ControlSize)] = [("inline", .inline), ("compact", .compact), ("regular", .regular)]

    private static let statuses: [SessionShown.Status] = [
        .working(.thinking), .delivery(.inTransit(.sending)), .delivery(.inTransit(.waking)), .asking, .awaitsReply, .failed(.other), .delivery(.failed(.reported(DeliveryRequest.unexplainedFailure))),
        .cueAsking, .unread, .idle, .resting, .fresh, .ended, .interrupted, .unknown(),
    ]

    private var motion: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                StateDot(shown: SessionShown(status: working ? .working(.tool) : .idle), size: 10)
                Spacer()
                Text("\(count)").font(.title.weight(.semibold).monospacedDigit()).foregroundStyle(palette.ink).counting(count)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(Self.statuses, id: \.self) { status in
                    let shown = SessionShown(status: status)
                    HStack(spacing: 6) {
                        StateDot(shown: shown, size: 8)
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
