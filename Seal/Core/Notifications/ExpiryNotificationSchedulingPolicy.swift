import Foundation
import UserNotifications

/// 「这一次该不该真的去排到期提醒」的**纯判据**。
///
/// ## 为什么需要它（2026-09-22 真机日志）
///
/// 构建 199 的真机日志里，`SEAL-NOTIFY-002a`（通知调度失败）以 **error** 级别出现
/// **100 次**，而且**每一次都只是同一句「通知调度失败」**，不带任何底层信息 ——
/// 事后**完全无法归因**。触发点是「每次 `load()` 之后的后台重排」，
/// 所以下拉刷新一次就多一条。
///
/// 但这条路径上有一大类「失败」**根本不是失败**：iOS **没有授予通知权限**时，
/// `UNUserNotificationCenter.add` 必然抛错。那是**已知条件**
///（设置页本来就在显示授权状态），不是「我们做了事但没做成」。
/// 按项目的日志纪律，它属于第③类：**条件不满足 ⇒ 跳过，不报错**。
///
/// 于是把「要不要真的去排」抽成纯函数：授权没给就**根本不去碰** `add`，
/// 从源头消掉「每次刷新都报一条必然失败的错误」。
/// 真正的失败（`add` 抛错）仍然会以 error 级别**带着底层原因**记下来。
enum ExpiryNotificationSchedulingPolicy {
    /// `UNAuthorizationStatus` 的精简三态（只保留影响判据的差别）。
    enum Authorization: Equatable {
        /// 系统允许发通知（`authorized` / `provisional` / `ephemeral`）。
        case allowed
        /// 用户明确拒绝过。
        case denied
        /// 还没问过（或系统给出未知状态）。
        case notDetermined
    }

    /// 本次调度的处置。
    enum Decision: Equatable {
        /// 真的去排。
        case schedule
        /// Seal 内的提醒开关是关的 ⇒ 不排（正常状态，不是错误）。
        case skipDisabled
        /// 系统没给通知权限 ⇒ 不排，也**不要**去调 `add`
        ///（否则每次刷新都会拿到一条必然失败的错误）。
        case skipNotAuthorized
    }

    static func authorization(from status: UNAuthorizationStatus) -> Authorization {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .allowed
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            // 未知状态一律按「还没问过」处理：**不排**，也**不去碰** `add`。
            // 宁可少排一次（下次刷新还会再来），也不要每次刷新都写一条错误日志。
            return .notDetermined
        }
    }

    static func decision(enabled: Bool, authorization: Authorization) -> Decision {
        guard enabled else { return .skipDisabled }
        switch authorization {
        case .allowed:
            return .schedule
        case .denied, .notDetermined:
            return .skipNotAuthorized
        }
    }
}
