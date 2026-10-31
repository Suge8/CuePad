import CueStore
import SwiftUI

/// 没有明确周期的计量、余额与文本只显示提供方的读数，不参与匀速线与额度环；一行，同额度明细里的余额（名字与重置在左、读数在右）。
struct QuotaValueRow: View {
    let value: QuotaDetails.Value
    @Environment(\.palette) private var palette

    var body: some View {
        MetaLine(gap: 8) {
            if let resetsAt = value.resetsAt {
                LiveText(style: QuotaMeter.Countdown(end: resetsAt)) { Text("\(name)\(Dotted.inline)\(Text("\($0)后重置").foregroundStyle(palette.ink3))") }
            } else {
                name
            }
        } meta: {
            reading.foregroundStyle(palette.ink).monospacedDigit()
        }
        .font(Typography.meta)
    }

    private var name: Text { Text(verbatim: value.name).fontWeight(.medium).foregroundStyle(palette.ink) }

    private var reading: Text {
        if let display = value.display { return Text(verbatim: display) }
        if value.unlimited == true { return Text("不限量") }
        if let balance = value.balance { return Text("\(balance.formatted()) \(value.unit ?? "")") }
        if let used = value.used { return Text("剩 \((1 - min(used, 1)).formatted(.percent.precision(.fractionLength(0))))") }
        return Text("尚未观测到额度")
    }
}
