import SwiftUI

/// 设置里的一行"上次崩溃 · 时间"（没有诊断就不显示）：点开看摘要（异常类型、崩溃线程顶部的帧），可导出给开发者。
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

    private static var opensAtStart: Bool {
        #if DEBUG
        DebugScene.defaults.bool(forKey: "CuePadCrashSheet")
        #else
        false
        #endif
    }
}

/// 一份诊断的摘要与导出。
struct CrashReportView: View {
    let report: CrashReport
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette

    #if os(iOS)
    var body: some View {
        NavigationStack {
            list
                .navigationTitle(report.kind.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { close() } } }
        }
    }
    #else
    var body: some View {
        VStack(spacing: 10) {
            PanelHeader(report.kind.label)
            list
        }
        .padding(.top, 18)
        .frame(width: 440).frame(maxHeight: 460)
        .background(palette.desk)
    }
    #endif

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
                Text("只存在这台设备上，不会自动上传；点导出把摘要和原始诊断复制出来，发给开发者。")
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
}
