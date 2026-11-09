import SwiftUI

/// 设置里"把最近日志发到 Mac"：存一份最近的日志、经你自己的 iCloud 送到你的 Mac（`Diagnostics.sendRecentLogs`）。
/// 只在连着 iCloud 时有（`Diagnostics.canSend`）。
struct SendLogsRow: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var phase = Phase.idle

    private enum Phase: Equatable {
        case idle, sending
        case sent(Date)
        /// 日志已存下，iCloud 一时没收：连上后自己送出
        case pending
        case failed(String)
    }

    static let note: LocalizedStringResource = "只有 CuePad 最近 15 分钟的日志，标成私密的内容系统已打码。经你自己的 iCloud 送到你的 Mac（~/Library/Logs/CuePad），不经别人。"

    private var status: String? {
        switch phase {
        case .idle: nil
        case .sending: String(localized: "正在发送…")
        case .sent(let at): String(localized: "已发出 \(at.formatted(date: .omitted, time: .shortened))")
        case .pending: String(localized: "已存下，连上 iCloud 后自动发出")
        case .failed(let reason): String(localized: "没发出去：\(reason)")
        }
    }

    private var tone: StatusTone {
        if case .failed = phase { .failure } else { .calm }
    }

    private func send() {
        phase = .sending
        Task {
            do {
                try await services.diagnostics.sendRecentLogs()
                phase = .sent(.now)
            } catch is Diagnostics.SendTimedOut {
                phase = .pending
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    #if os(iOS)
    var body: some View {
        Button(action: send) {
            LabeledContent {
                if phase == .sending { Spinner(.small) } else if let status {
                    Text(status).foregroundStyle(palette.color(tone, muted: true)).multilineTextAlignment(.trailing)
                }
            } label: {
                Label("把最近日志发到 Mac", icon: .uploadLocal).foregroundStyle(palette.ink)
            }
        }
        .buttonStyle(PressStyle())
        .disabled(phase == .sending)
    }
    #else
    var body: some View {
        SettingRow(
            title: "最近日志", icon: Image(.uploadLocal), tone: tone, busy: phase == .sending,
            status: Dotted(status ?? String(localized: "经你的 iCloud 送到你的 Mac")), help: Self.note
        ) {
            EmptyView()
        } fix: {
            Button("把最近日志发到 Mac", action: send).settingFix().disabled(phase == .sending)
        }
    }
    #endif
}
