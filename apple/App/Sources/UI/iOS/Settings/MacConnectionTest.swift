#if os(iOS)
import CueStore
import SwiftUI

/// 设置·同步里的"测试到 Mac 的连接"：给最近写过 Pi 状态的那台 Mac 依次发 10 条连接测试请求，
/// 显示往返的中位数与最大值，以及三段（上传、到 Mac 执行完、回到手机）各自的中位数，便于看出哪段慢。
/// 需要那台 Mac 上的 CuePad 在运行。
struct MacConnectionTest: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var rounds: [AppServices.PingTiming] = []
    @State private var running = false
    @State private var failure: String?

    private static let count = 10

    var body: some View {
        Button(running ? "正在测试…（\(rounds.count)/\(Self.count)）" : "测试到 Mac 的连接", systemImage: "antenna.radiowaves.left.and.right") {
            Task { await run() }
        }
        .disabled(running)
        if !rounds.isEmpty || failure != nil {
            VStack(alignment: .leading, spacing: 4) {
                if !rounds.isEmpty {
                    let totals = rounds.map(\.total).sorted()
                    Text("往返中位数 \(Self.text(Self.median(totals))) · 最大 \(Self.text(totals.last!))")
                        .font(.footnote.weight(.medium)).foregroundStyle(palette.ink)
                    Text("上传 \(Self.text(Self.median(rounds.map(\.upload)))) · 到 Mac 执行完 \(Self.text(Self.median(rounds.map(\.toMac)))) · 回到手机 \(Self.text(Self.median(rounds.map(\.back))))")
                        .font(.footnote.monospacedDigit()).foregroundStyle(palette.ink2)
                    Text(rounds.map { Self.text($0.total) }.joined(separator: "  "))
                        .font(.footnote.monospacedDigit()).foregroundStyle(palette.ink3)
                    Text("后两段用 Mac 记下的完成时间，两台设备的时钟可能差零点几秒").font(.caption).foregroundStyle(palette.ink3)
                }
                if let failure { Text(failure).font(.footnote).foregroundStyle(palette.failure) }
            }
        }
    }

    private func run() async {
        running = true
        rounds = []
        failure = nil
        defer { running = false }
        do {
            let states = try await services.store.piSessionStates()
            guard let host = states.max(by: { $0.modifiedAt < $1.modifiedAt })?.hostID else {
                failure = "还没有 Mac 同步来的 Pi 会话，不知道发给哪台 Mac"
                return
            }
            for _ in 0..<Self.count { rounds.append(try await services.ping(host)) }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// 中位数：偶数个取中间两个的平均。
    private static func median(_ values: [Duration]) -> Duration {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// "0.8 秒"、"12 秒"。
    private static func text(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return abs(seconds) < 10 ? String(format: "%.1f 秒", seconds) : "\(Int(seconds.rounded())) 秒"
    }
}
#endif
