import CueSync
import SwiftUI

/// 同步状态给人看的一句话、补充说明与图标（Mac 与 iOS 设置共用）。颜色只表达含义：正常是墨，需要处理是注意色，出错是失败色。
struct SyncSummary: Equatable {
    enum Tone { case normal, attention, failure }

    let title: String
    let detail: String?
    let symbol: String
    let tone: Tone

    init(_ status: SyncStatus) {
        switch status {
        case .idle: (title, detail, symbol, tone) = ("已同步", nil, "checkmark.icloud", .normal)
        case .syncing: (title, detail, symbol, tone) = ("正在同步…", nil, "arrow.triangle.2.circlepath.icloud", .normal)
        case .noAccount:
            (title, detail, symbol, tone) = ("没有登录 iCloud", "在系统设置里登录后自动开始同步，本机数据不受影响", "icloud.slash", .attention)
        case .accountRestricted:
            (title, detail, symbol, tone) = ("iCloud 账号受限", "家长控制或设备管理限制了 iCloud，本机数据照常可用", "lock.icloud", .attention)
        case .accountUnavailable:
            (title, detail, symbol, tone) = ("iCloud 暂时不可用", "稍后会自动重试", "exclamationmark.icloud", .attention)
        case .quotaExceeded:
            (title, detail, symbol, tone) = ("iCloud 空间不足", "本机改动都已保留，空间释放后自动上传", "exclamationmark.icloud", .attention)
        case .needsDecision(let decision):
            (title, detail, symbol, tone) = ("同步已暂停，需要你决定", Self.describe(decision), "pause.circle", .attention)
        case .failed(let message): (title, detail, symbol, tone) = ("同步出错", message, "xmark.icloud", .failure)
        }
    }

    func color(_ palette: Palette) -> Color {
        switch tone {
        case .normal: palette.ink2
        case .attention: palette.attention
        case .failure: palette.failure
        }
    }

    private static func describe(_ decision: SyncDecision) -> String {
        switch decision {
        case .accountSwitched: "iCloud 账号换了，本机数据属于上一个账号"
        case .cloudDataDeleted: "iCloud 里的 CuePad 数据被删除了"
        case .cloudDataReset: "iCloud 里的 CuePad 数据被重置了"
        }
    }
}
