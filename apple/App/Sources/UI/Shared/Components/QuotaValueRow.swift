import CueStore
import SwiftUI

struct QuotaValueRow: View {
    let value: QuotaDetails.Value
    @Environment(\.palette) private var palette

    var body: some View {
        MetaLine(gap: Spacing.item) {
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
