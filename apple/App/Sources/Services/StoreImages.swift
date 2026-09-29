import CueEditor
import CueStore
import Foundation
import Synchronization

/// 把编辑器的同步图片接口适配到 Store：写入经 `CueStore.addImage`（校验、去重、登记附件），
/// 读取直接指向附件目录里以哈希命名的原图文件。
///
/// 编辑器在主线程同步调用 `store`，而 Store 是 actor：这里阻塞调用线程，等它完成一次写事务。
/// Store 的执行体不在主线程，也不等待主线程，所以不会死锁。
/// 风险：actor 一次只处理一件事，Store 正在执行长操作（如旧库导入、大批量写入）时，粘贴图片会让主线程
/// 短暂卡顿到它完成。等界面接好后按实际手感决定是否改成异步接口。
nonisolated struct StoreImages: CueImageStore {
    let store: CueStore
    let attachments: URL

    func store(_ data: Data) throws -> String {
        try blocking { try await store.addImage(data).hash }
    }

    func store(fileAt url: URL) throws -> String {
        try store(ImageFiles.original(at: url))
    }

    func fileURL(for id: String) -> URL? {
        let url = attachments.appending(path: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let outcome = Mutex<Result<T, any Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let result = await Result { try await work() }
            outcome.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        return try outcome.withLock { $0! }.get()
    }
}
