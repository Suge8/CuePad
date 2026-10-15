import SwiftUI

/// 分享面板的界面。`model` 负责数据，保存成功后调用 `dismiss`，取消调用 `cancel`。
enum ShareViews {
    static func root(_ model: ShareModel, dismiss: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        ShareForm(model: model, dismiss: dismiss, cancel: cancel)
    }
}

private struct ShareForm: View {
    @Bindable var model: ShareModel
    let dismiss: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if case .failed(let message) = model.state { Text(message) }
                if let content = model.content {
                    Section("内容") {
                        if let text = content.text { Text(text).lineLimit(4) }
                        ForEach(content.urls, id: \.self) { Text($0.absoluteString).lineLimit(1) }
                        if !content.images.isEmpty { Text("\(content.images.count) 张图片") }
                    }
                }
                Picker("存到", selection: $model.selectedProject) {
                    Text("未分类").tag(UUID?.none)
                    ForEach(model.projects, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
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
