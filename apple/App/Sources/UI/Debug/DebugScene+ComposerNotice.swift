#if DEBUG
import CueStore
import CueText
import Foundation

extension DebugScene {
    /// `-CuePadComposerNotice YES`（配 session、atlas）：每隔三秒显示一条命令进度与一条配置失败，1.5 秒后撤回，循环验收两行说明进出时的贴底布局。
    /// 失败由隔离执行器写回；不修改对话正文，也不接真实 Agent。
    static func composerNoticeIfAsked(_ services: AppServices) async {
        guard defaults.bool(forKey: "CuePadComposerNotice") else { return }
        let store = services.store, host = "notice-fixture"
        let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { error in
            Task { @MainActor in abandon("说明验收执行器失败", error) }
        }) { _, _ in
            .failed(.verbatim(String(localized: "模型拒绝了请求（400）", table: "Demo")))
        }
        do {
            try await executor.start()
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3))
                let name = defaults.string(forKey: "CuePadSession") ?? "atlas"
                guard let session = try await store.piSessionPage(PiSessionQuery(text: name)).items.first?.state else { throw CueStoreError.notFound }
                let config = try await store.requestConfig(PiConfig(thinking: .high), to: session.target, on: host)
                for try await failed in store.observe({ try $0.deliveryRequest(config.id)?.status == .known(.failed) }) where failed { break }
                let command = try await store.requestDelivery("/compact", to: session.target, on: session.hostID, mode: .command)
                try await Task.sleep(for: .seconds(1.5))
                try await store.deleteDelivery(config.id)
                try await store.deleteDelivery(command.id)
            }
        } catch is CancellationError {
        } catch { abandon("两行输入框说明没摆好", error) }
        await executor.stop()
    }
}
#endif
