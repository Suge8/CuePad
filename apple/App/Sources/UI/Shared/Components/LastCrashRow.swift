import SwiftUI

#if os(iOS)
/// iOS 设置里的一行"上次崩溃 · 时间"（没有诊断就不显示）：点开看摘要（异常类型、崩溃线程顶部的帧），可导出给开发者。Mac 的那一行见设置窗口的 `CrashRow`。
struct LastCrashRow: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showing = LastCrashRow.opensAtStart

    var body: some View {
        if let report = services.diagnostics.latest {
            Button { showing = true } label: {
                LabeledContent {
                    Text(report.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(palette.ink3)
                } label: {
                    Label(report.kind.label, systemImage: "exclamationmark.triangle").foregroundStyle(palette.ink)
                }
            }
            .buttonStyle(.plain)
            .panel(isPresented: $showing) { CrashReportView(report: report) }
        }
    }

    private static var opensAtStart: Bool { DebugHooks.preset.crashSheet }
}
#endif

/// 一份诊断的摘要与导出。
struct CrashReportView: View {
    let report: CrashReport
    @Environment(\.palette) private var palette

    #if os(iOS)
    @Environment(\.closePanel) private var close

    var body: some View {
        NavigationStack {
            list
                .navigationTitle(report.kind.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { close() } } }
        }
    }
    #else
    /// Mac：挂在设置那一行"查看"上的弹出框，与设置里其余弹出框同一种外观（`SettingPopover`）。
    var body: some View {
        SettingPopover(title: report.kind.label, width: 420) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(facts, id: \.0) { title, value in
                    GridRow {
                        Text(title).foregroundStyle(palette.ink3)
                        Text(value).foregroundStyle(palette.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !report.frames.isEmpty {
                Text(report.frames.joined(separator: "\n")).font(Typography.meta.monospaced()).foregroundStyle(palette.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.fill, in: .rect(cornerRadius: 8))
            }
            ExportDiagnosticsButton(text: report.diagnostics).settingButton()
            Text(Self.note).font(Typography.meta).foregroundStyle(palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var facts: [(String, String)] {
        var facts = [("时间", report.date.formatted(date: .abbreviated, time: .standard))]
        if let exception = report.exception { facts.append(("异常", exception + (report.signal.map { "（\($0)）" } ?? ""))) }
        if let reason = report.reason { facts.append(("原因", reason)) }
        if let app = report.app { facts.append(("版本", app.visible)) }
        return facts
    }
    #endif

    private static let note = "只存在这台设备上，不会自动上传；点导出把摘要和原始诊断复制出来，发给开发者。"

    #if os(iOS)
    private var list: some View {
        List {
            Section {
                row("时间", report.date.formatted(date: .complete, time: .standard))
                if let exception = report.exception { row("异常", exception + (report.signal.map { "（\($0)）" } ?? "")) }
                if let reason = report.reason { row("原因", reason) }
                if let app = report.app { row("版本", app) }
            }
            if !report.frames.isEmpty {
                Section("崩溃线程顶部") {
                    ForEach(Array(report.frames.enumerated()), id: \.offset) { _, frame in
                        Text(frame).font(.footnote.monospaced())
                    }
                }
            }
            Section {
                ExportDiagnosticsButton(text: report.diagnostics)
            } footer: {
                Text(Self.note)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listRowBackground(palette.paper)
        .scrollContentBackground(.hidden)
        .background(palette.desk)
    }

    private func row(_ title: String, _ value: String) -> some View { row(title, Dotted(value)) }

    private func row(_ title: String, _ value: Dotted) -> some View {
        LabeledContent(title) { Text(value).foregroundStyle(palette.ink3).multilineTextAlignment(.trailing).textSelection(.enabled) }
    }
    #endif
}
