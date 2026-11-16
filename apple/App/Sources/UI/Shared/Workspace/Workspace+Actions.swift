import CueStore

extension Workspace {
    func stop(_ session: SessionState) async {
        do {
            let request = try await services.stop(session)
            if let failure = try await services.store.outcome(of: request).failure { throw SendError.notDelivered(failure) }
        } catch { fail(error) }
    }

    /// 请会话所在的 Mac 结束它。进度（正在结束、没能结束的原因）只来自这条结束请求，界面按 `MacDelivery.endProgress` 读；
    /// 还在路上时再点不会再发一条（Store 去重）。写不进请求时提示。
    func end(_ session: SessionState) async {
        do { _ = try await services.end(session) } catch { fail(error) }
    }

    /// 让会话休眠的入口（菜单、轻扫、看板上拖回待办）。休眠不丢东西（对话留着，再说话就醒），歇着的当场做、不问；
    /// 只有它手上正做着事才先问一句（`sessionAsk`）：那一步会被打断。
    func sleep(_ session: SessionState) {
        if pulse(of: SessionListItem(state: session)).shown?.agentBusy == true { sessionAsk = .end(session) } else { Task { await end(session) } }
    }

    /// 执行一个异步操作，失败时提示。
    func attempt(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch { fail(error) }
        }
    }

    /// 执行一个 Store 写操作，失败时提示。
    func perform(_ work: @escaping @Sendable (CueStore) async throws -> Void) {
        let store = services.store
        attempt { try await work(store) }
    }
}
