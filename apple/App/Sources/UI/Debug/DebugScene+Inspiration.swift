#if DEBUG
import CryptoKit
import CueStore
import CueSync
import CueText
import Foundation
import SwiftUI

extension DebugScene {
    /// 配 `-CuePadDemo YES` 沿用正常任务、会话与已启用 Cue 的既有种子；不配则保留初始未启用场景。
    static func seedInspiration(_ services: AppServices) async {
        await seedArrivingInspiration(services)
        guard args.inspiration else { return }
        if args.demo {
            await seedRemote(services)
            await seedCue(services)
        }
        do {
            let store = services.store
            let body = try args.inspirationOpts.source.map { try String(contentsOfFile: $0, encoding: .utf8) } ?? String(localized: """
            # 让灵感，慢慢成形

            留一点空白，才看得见真正重要的东西。**重点：**让内容自己说话，把复杂留给工具，把清晰留给人。

            ## 一张纸的阅读节奏

            阅读从一个念头开始，经过 *斟酌*，变成 ***值得留下的想法***。中**「引号里的强调」**文也应自然；转义星号 \\*照原样留下\\*，行内代码 `a * b` 不参与排版。

            > 好的设计让人专注于内容，而不是学习如何使用它。

            - 把想到的写下来，不急着分类；这一条故意写得足够长，让手机窄屏上的第二行仍然和正文左边对齐。
            - 留下线索
              - 从细节里找到方向
            - [x] 记下一闪而过的想法
            - [ ] 下次再读，补上新的理解

            ## A quieter workspace

            Make room for **clear thinking**, *small discoveries*, and [a fresh perspective](https://developer.apple.com/design/).

            | 内容 | 呈现 | 进度 |
            | :--- | :---: | ---: |
            | 中文与 English | **清晰** | 100% |
            | `a \\| b` | *克制* | 80% |

            ~~~~swift
            let thought = "Keep *literal* symbols"
            // A shorter fence stays inside code:
            ~~~
            print(thought)
            ~~~~

            ---

            读到这里，完整的内容都还在。
            """, table: "Demo")
            let existing = try await store.cards(in: Project.defaultID)
            if !existing.contains(where: { $0.body.hasPrefix(body.prefix(20)) }) {
                let image = try store.files.store(widePNG())
                _ = try await store.createCard(in: Project.defaultID, body: body + "\n\n" + CueFormat.imageMarkup(key: image))
                _ = try await store.createCard(in: Project.defaultID, body: String(localized: "**把注意力还给内容**\n\n少一点干扰，多一点思考。保留 \\*字面星号\\*，读懂 **真正的强调**。", table: "Demo"))
                _ = try await store.createCard(in: Project.defaultID, body: String(localized: "纸上的一小片风景\n\n为下一版留下的配色与节奏。", table: "Demo") + "\n" + CueFormat.imageMarkup(key: image))
            }
            if let path = args.inspirationOpts.export,
               let card = try await store.cards(in: Project.defaultID).first(where: { $0.body.hasPrefix(body.prefix(20)) }) {
                let payload = try await InspirationShare.prepare(card.body, originals: args.inspirationOpts.originals, files: store.files, colorScheme: services.settings.theme == .dark ? .dark : .light)
                let target = URL(filePath: path)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: payload.urls[0], to: target)
            }
        } catch { abandon("阅读样张没写下", error) }
    }

    private static func seedArrivingInspiration(_ services: AppServices) async {
        let delay = args.inspirationOpts.arrival
        guard delay > 0 else { return }
        var bytes = widePNG()
        bytes.append(Data(UUID().uuidString.utf8))
        let picture = bytes
        let key = SHA256.hash(data: picture).map { String(format: "%02x", $0) }.joined() + ".png"
        do {
            let store = services.store
            let body = String(localized: "图片正在路上", table: "Demo") + "\n\n" + CueFormat.imageMarkup(key: key)
            if try await !store.cards(in: Project.defaultID).contains(where: { $0.body == body }) {
                _ = try await store.createCard(in: Project.defaultID, body: body)
            }
            Task {
                await Task.wait(for: .seconds(delay))
                transfers.continuation.yield([key: FileTransfer(direction: .download, fraction: 0.5)])
                await Task.wait(for: .milliseconds(500))
                do { _ = try store.files.store(picture) }
                catch { abandon("图片没落地", error) }
                transfers.continuation.yield([:])
            }
        } catch { abandon("图片到达样张没写下", error) }
    }

}
#endif
