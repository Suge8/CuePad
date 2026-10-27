import SwiftUI

/// 分享面板的界面。`model` 负责数据，保存成功后调用 `dismiss`，取消调用 `cancel`。
enum ShareViews {
    static func root(_ model: ShareModel, dismiss: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        ShareForm(model: model, dismiss: dismiss, cancel: cancel).withPalette()
    }
}

private struct ShareForm: View {
    @Bindable var model: ShareModel
    let dismiss: () -> Void
    let cancel: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            Form {
                if case .failed(let message) = model.state { Text(message).foregroundStyle(palette.failure).listRowBackground(palette.paper) }
                if let content = model.content {
                    Section("内容") {
                        if let text = content.text { Text(text).lineLimit(4) }
                        ForEach(content.urls, id: \.self) { Text($0.absoluteString).lineLimit(1) }
                        ForEach(content.files, id: \.url) { Text(verbatim: $0.name).lineLimit(1) }
                    }
                    .listRowBackground(palette.paper)
                }
                // 从没打开过主 App 时没有项目快照：存进默认项目，不给空的选择
                if !model.projects.isEmpty {
                    Picker("存到", selection: $model.selectedProject) {
                        ForEach(model.projects, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .listRowBackground(palette.paper)
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.desk)
            .foregroundStyle(palette.ink)
            .navigationTitle("存为灵感")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存入") { Task { if await model.save() { dismiss() } } }
                        .disabled(model.state != .ready)
                }
            }
        }
    }
}
