import CueStore
import CueSync
import Observation
import os
import SwiftUI

/// 设置里同步要你选的两件事，两端同一份说法与出错处理：同步暂停时上传本机，还是用云端替换本机（替换前再确认一次，`confirmsErase`）；
/// 同一张卡有两个版本时留哪一份。没做成时 `failure` 是给人看的一句，就地写在那一处，下一次动作先清掉（同 `CueSettingsModel`）；
/// 这几件都只读写本机资料库，没做成就是本机读写出错，原话只进日志。做成了不另说，状态那一行与冲突列表自己会变。
@Observable
final class SyncChoices {
    private(set) var working = false
    private(set) var failure: String?

    struct Choice {
        let title: String
        let consequence: String
    }

    static let upload = Choice(title: "上传本机数据", consequence: "本机数据作为新内容传到当前账号")
    static let erase = Choice(title: "用云端数据替换本机…", consequence: "丢弃本机的灵感、任务、项目与图片，从当前账号的云端重新下载")
    static let keep = "保留这一份"
    static let failed = "没做成：这台设备的资料库读写出错，再试一次"

    func resolve(_ resolution: SyncResolution, _ services: AppServices) {
        run { try await services.resolveSync(resolution) }
    }

    func keep(_ choice: ConflictChoice, of conflict: CardConflict, _ services: AppServices) {
        let copy = conflict.copy.id
        run { try await services.resolveConflict(copy: copy, keep: choice) }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do { try await work() } catch {
                AppServices.log.error("同步的选择没做成：\(String(describing: error), privacy: .public)")
                failure = Self.failed
            }
        }
    }
}

/// 冲突里并排的一个版本。
struct ConflictVersion: Identifiable {
    let label: String
    let card: Card
    let keep: ConflictChoice

    var id: String { label }
}

extension CardConflict {
    /// 原卡是现在在用的那份，副本是同步时被替下的（`Card.conflictOf`），与哪台设备写的无关。
    var versions: [ConflictVersion] {
        [ConflictVersion(label: "现在的版本", card: original, keep: .original), ConflictVersion(label: "另一个版本", card: copy, keep: .copy)]
    }
}

extension View {
    /// 用云端替换本机前再确认一次：本机数据会被删除，无法撤销。
    func confirmsErase(_ isPresented: Binding<Bool>, choices: SyncChoices, services: AppServices) -> some View {
        dialog("丢弃本机数据，改用云端的？", isPresented: isPresented, message: "本机的灵感、任务、项目与图片会被删除，无法撤销。", buttons: [
            DialogButton(title: "用云端数据替换本机", role: .destructive) { choices.resolve(.eraseLocal, services) }
        ])
    }
}
