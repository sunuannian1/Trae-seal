import Foundation
import Testing
import UserNotifications
@testable import Seal

/// `ExpiryNotificationSchedulingPolicy` 的判据测试。
///
/// 这条规则的错法**不会崩**，只在真机上表现为两个相反的极端：
///   - 系统没给权限时照样去调 `add` ⇒ 每次刷新写一条**必然失败**的 error 日志
///     （2026-09-22 实测 **100 条**，且不带任何底层信息 ⇒ 完全无法归因）；
///   - 该排的时候不排 ⇒ 用户永远收不到到期提醒，而且**没有任何日志**。
/// 两个方向都要钉住。
@Suite("到期提醒的调度判据")
struct ExpiryNotificationSchedulingPolicyTests {
    /// 开关关着 ⇒ 不排，且**与授权无关**（用户自己关的，不是错误）。
    @Test
    func disabledNeverSchedules() {
        let all: [ExpiryNotificationSchedulingPolicy.Authorization] = [.allowed, .denied, .notDetermined]
        for authorization in all {
            #expect(
                ExpiryNotificationSchedulingPolicy.decision(enabled: false, authorization: authorization)
                    == .skipDisabled
            )
        }
    }

    /// 开关开着 + 系统允许 ⇒ **必须真的去排**（否则提醒功能整个失效）。
    @Test
    func enabledWithAuthorizationSchedules() {
        #expect(
            ExpiryNotificationSchedulingPolicy.decision(enabled: true, authorization: .allowed)
                == .schedule
        )
    }

    /// 系统没给权限 ⇒ **不去碰 `add`**。
    /// 这是那 100 条 `SEAL-NOTIFY-002a` 的闸门：没有这一条，
    /// 每次刷新都会拿到一条必然失败的错误。
    @Test
    func notAuthorizedIsSkippedInsteadOfAttempted() {
        #expect(
            ExpiryNotificationSchedulingPolicy.decision(enabled: true, authorization: .denied)
                == .skipNotAuthorized
        )
        // 还没问过也一样：宁可少排一次（下次刷新还会再来），
        // 也不要每次刷新都写一条错误日志。
        #expect(
            ExpiryNotificationSchedulingPolicy.decision(enabled: true, authorization: .notDetermined)
                == .skipNotAuthorized
        )
    }

    /// `UNAuthorizationStatus` → 三态的映射：**只有**系统真的允许时才落 `.allowed`。
    @Test
    func authorizationMappingIsConservative() {
        let allowed: [UNAuthorizationStatus] = [.authorized, .provisional, .ephemeral]
        for status in allowed {
            #expect(ExpiryNotificationSchedulingPolicy.authorization(from: status) == .allowed)
        }
        #expect(ExpiryNotificationSchedulingPolicy.authorization(from: .denied) == .denied)
        #expect(ExpiryNotificationSchedulingPolicy.authorization(from: .notDetermined) == .notDetermined)
    }

    /// 穷举：**只有**「开关开着 + 系统允许」这一种组合允许真的去排。
    /// 用穷举而不是逐条断言，是为了让「以后新增一个状态忘了处理」也能被这条抓住。
    @Test
    func onlyAuthorizedEnabledCombinationSchedules() {
        let all: [ExpiryNotificationSchedulingPolicy.Authorization] = [.allowed, .denied, .notDetermined]
        for authorization in all {
            for enabled in [true, false] {
                let decision = ExpiryNotificationSchedulingPolicy.decision(
                    enabled: enabled,
                    authorization: authorization
                )
                if enabled && authorization == .allowed {
                    #expect(decision == .schedule)
                } else {
                    #expect(decision != .schedule, "只有「开关开着 + 系统允许」才允许真的去排")
                }
            }
        }
    }
}
