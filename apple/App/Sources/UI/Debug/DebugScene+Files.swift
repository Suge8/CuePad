#if DEBUG
import CryptoKit
import CueStore
import CueSync
import CueText
import Foundation

extension DebugScene {
    /// 没有同步，下载进度是这里写给界面的。
    static func seedFiles(_ services: AppServices) async {
        await seedInspiration(services)
        guard args.files else { return }
        let store = services.store
        let archive = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) })
        let away = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined() + ".zip"
        do {
            let title = String(localized: "交接材料", table: "Demo")
            let written = try await store.cards(in: Project.defaultID).contains { $0.body.hasPrefix(title) }
            if !written {
                let pdf = try demoPDF(store)
                let image = try store.files.store(swatch(red: 0.36, green: 0.52, blue: 0.43))
                let body = [
                    title, "",
                    String(localized: "评审要看的都在这里：复盘、首页配色，和上周导出的日志。", table: "Demo"), "",
                    pdf.markup,
                    CueFormat.fileMarkup(key: away, name: String(localized: "导出日志.zip", table: "Demo")),
                    CueFormat.imageMarkup(key: image),
                ].joined(separator: "\n")
                _ = try await store.createCard(in: Project.defaultID, body: body)
            }
        } catch {
            abandon("带附件的灵感没写下", error)
        }
        let delay = args.fileArrives
        guard delay > 0, store.files.fileURL(for: away) == nil else { return }
        Task {
            await Task.wait(for: .seconds(delay))
            for step in 1...20 {
                transfers.continuation.yield([away: FileTransfer(direction: .download, fraction: Double(step) / 20)])
                await Task.wait(for: .milliseconds(150))
            }
            let url = FileManager.default.temporaryDirectory.appending(path: "export.zip")
            do {
                try archive.write(to: url)
                _ = try store.files.store(fileAt: url)
            } catch {
                abandon("压缩包没落地", error)
            }
            transfers.continuation.yield([:])
        }
    }
}
#endif
