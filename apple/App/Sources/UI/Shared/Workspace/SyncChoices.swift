import CueStore
import CueSync
import Observation
import os
import SwiftUI

/// 没做成时 `failure` 是给人看的一句，就地写在那一处，下一次动作先清掉（同 `CueSettingsModel`）；
/// 这几件都只读写本机资料库，没做成就是本机读写出错，原话只进日志。
@Observable
final class SyncChoices {
    private(set) var working = false
    private(set) var failure: String?

    struct Choice {
        let title: String
        let consequence: String
    }

    static let upload = Choice(title: String(localized: "上传本机数据"), consequence: String(localized: "本机数据作为新内容传到当前账号"))
    static let erase = Choice(title: String(localized: "用云端数据替换本机…"), consequence: String(localized: "丢弃本机的灵感、任务、项目与图片，从当前账号的云端重新下载"))
    static let keep = String(localized: "保留这一份")
    static let failed = String(localized: "没做成：这台设备的资料库读写出错，再试一次")

    func resolve(_ resolution: SyncResolution, _ services: AppServices) {
        run { try await services.resolveSync(resolution) }
    }

    func keep(_ choice: ConflictChoice, of conflict: CardConflict, _ services: AppServices) {
        let copy = conflict.copy.id
        run { try await services.store.resolveConflict(copy: copy, keep: choice) }
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

struct ConflictVersion: Identifiable {
    let label: String
    let card: Card
    let keep: ConflictChoice

    var id: String { label }
}

extension CardConflict {
    /// 原卡是现在在用的那份，副本是同步时被替下的（`Card.conflictOf`），与哪台设备写的无关。
    var versions: [ConflictVersion] {
        [ConflictVersion(label: String(localized: "现在的版本"), card: original, keep: .original), ConflictVersion(label: String(localized: "另一个版本"), card: copy, keep: .copy)]
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
