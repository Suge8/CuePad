#if DEBUG && os(macOS)
import CueStore
import CueSync
import CueText
import Foundation

extension SyncBench {
    /// 带文件的同步（`sync-bench.py files`）：同一刻写下三样，量大文件挡不挡别的。两端一样的打点：
    /// - `card-new id= kind=`：默认项目里第一次出现的灵感（启动时已在的不记；`kind` 从正文认：带文件的 file、只有字的 text）。
    ///   本机写下的时刻取 `createdAt`、同步来的取读到那一刻，脚本只拿收的那一端的。
    /// - `file-arrived key=`：`watch-file` 等的文件到了本机。
    enum Files {
        static func start(_ services: AppServices) {
            let store = services.store
            Task {
                var last: [String: FileTransfer] = [:]
                for await transfers in Observations({ services.fileTransfers }) {
                    for (key, transfer) in transfers where last[key] != transfer {
                        mark("transfer", ["key": key, "dir": transfer.direction == .upload ? "up" : "down", "f": transfer.fraction])
                    }
                    last = transfers
                }
            }
            Task {
                for await over in Observations({ services.syncFilesOverQuota }) { mark("files-over-quota", ["v": over]) }
            }
            Task {
                var known: Set<UUID>?
                do {
                    for try await cards in store.observe({ try $0.cards(in: Project.defaultID) }) {
                        for card in cards where known?.contains(card.id) == false {
                            let kind = card.body.hasPrefix(bigPrefix) ? "file" : card.body.hasPrefix(textPrefix) ? "text" : "other"
                            mark("card-new", ["id": card.id.uuidString.lowercased(), "kind": kind])
                        }
                        known = (known ?? []).union(cards.map(\.id))
                    }
                } catch {
                    mark("bench-error", ["what": "读灵感：\(error.localizedDescription)"])
                }
            }
        }

        private static let bigPrefix = "同步测量 带文件"
        private static let textPrefix = "同步测量 只有字"

        /// 认得的命令做了返回 true：
        /// - `burst <标记> <文件>`：同一刻写下带这个文件的灵感、只有字的灵感、对 Cue 说的一句，记 `burst big= text= key= stored= at=`
        ///   （`stored` 是文件存进本机用了几秒，在写下之前；`at` 是开始写下的时刻）。
        /// - `watch-file <key>`：这个文件到了本机记 `file-arrived`。
        static func command(_ words: [String], _ workspace: Workspace) async -> Bool {
            let store = workspace.services.store
            switch words.first {
            case "burst":
                guard words.count > 2 else { mark("bench-error", ["what": "burst 要标记与文件"]); return true }
                let tag = words[1], file = URL(filePath: words[2])
                do {
                    let began = ContinuousClock.now
                    let key = try await Task.detached { try store.files.store(fileAt: file) }.value
                    let stored = (ContinuousClock.now - began).seconds, at = Date.now
                    let big = try await store.createCard(body: "\(bigPrefix) \(tag)\n\(CueFormat.imageMarkup(id: key))")
                    let text = try await store.createCard(body: "\(textPrefix) \(tag)")
                    workspace.speak("同步测量 \(tag)", to: .cue)
                    mark("burst", ["big": big.id.uuidString.lowercased(), "text": text.id.uuidString.lowercased(), "key": key, "stored": stored, "at": at.timeIntervalSince1970])
                } catch {
                    mark("bench-error", ["what": "burst：\(error.localizedDescription)"])
                }
                return true
            case "watch-file":
                guard let key = words.dropFirst().first else { mark("bench-error", ["what": "watch-file 要 key"]); return true }
                guard let sync = workspace.services.sync else { mark("bench-error", ["what": "没有同步"]); return true }
                Task {
                    // 文件取完、放进附件目录之后它才离开在路上的那一张
                    for await _ in sync.fileTransfers where store.files.fileURL(for: key) != nil {
                        return mark("file-arrived", ["key": key])
                    }
                }
                return true
            default:
                return false
            }
        }
    }
}
#endif
