import Foundation
import Testing
@testable import Seal

/// `InstalledAppProbeRetryPolicy` 的判据测试。
///
/// 这条规则的错法**不会崩、不会编译失败**，只在真机上表现为两种现象：
///   - 重试**无上限** ⇒ 通道一直不好时下拉刷新**永远转圈**；
///   - 连「撞满 15 秒超时」也重试 ⇒ 刷新一次比一次慢，用户永远等不到结果。
/// 两个方向都要钉住，否则「修好弹窗」会换成「刷新卡死」。
@Suite("设备核验的重试判据")
struct InstalledAppProbeRetryPolicyTests {
    /// 快速失败（通道还没起来，FFI 立刻抛错）⇒ **值得**再问一次。
    /// 真机证据：2026-09-22 日志里 `SEAL-RECONCILE-003` 出现 10 次，
    /// 而**同一条通道 3 秒后就正常了**（10:21:30 中止 → 10:21:33 完成）。
    @Test
    func fastFailureIsRetried() {
        #expect(InstalledAppProbeRetryPolicy.shouldRetry(elapsed: 0.0, attemptsSoFar: 1))
        #expect(InstalledAppProbeRetryPolicy.shouldRetry(elapsed: 0.4, attemptsSoFar: 2))
    }

    /// 撞满超时（会话已经死了：隧道断了 / VPN 关了）⇒ **不**重试。
    /// 这条是「刷新变慢」的闸门：15 秒 × 3 次 = 45 秒转圈，用户会以为 App 卡死。
    @Test
    func timeoutFailureIsNotRetried() {
        #expect(InstalledAppProbeRetryPolicy.shouldRetry(elapsed: 15.0, attemptsSoFar: 1) == false)
        // 恰好落在上界上也算「慢」—— 判据是 `<`，不是 `<=`。
        #expect(
            InstalledAppProbeRetryPolicy.shouldRetry(
                elapsed: InstalledAppProbeFailurePolicy.fastFailureUpperBound,
                attemptsSoFar: 1
            ) == false
        )
    }

    /// 次数必须**有界**：问到上限就不再问，哪怕每次都快速失败。
    @Test
    func attemptsAreBounded() {
        let maxAttempts = InstalledAppProbeRetryPolicy.maxAttempts
        #expect(maxAttempts >= 2)
        #expect(InstalledAppProbeRetryPolicy.shouldRetry(elapsed: 0.0, attemptsSoFar: maxAttempts) == false)
        #expect(
            InstalledAppProbeRetryPolicy.shouldRetry(elapsed: 0.0, attemptsSoFar: maxAttempts + 5) == false
        )
        // 上限之前的最后一次仍然要重试 —— 否则 `maxAttempts` 只是个装饰，
        // 实际行为退化成「只问一次」。
        #expect(InstalledAppProbeRetryPolicy.shouldRetry(elapsed: 0.0, attemptsSoFar: maxAttempts - 1))
    }

    /// 上界与间隔必须是**有限且合理**的值。
    ///
    /// ⚠️ 「多快算快」这个阈值住在 `InstalledAppProbeFailurePolicy`（弹窗判据也要用它），
    /// 这里只**引用**它 —— 两处各写一份必然会漂移成两个阈值。
    /// 太大 ⇒ 把「会话已死」也当成快速失败，白等三轮；
    /// 太小 ⇒ 真机上那种「0.x 秒抛错」一次都重试不到，等于没修。
    @Test
    func boundsAreFiniteAndSane() {
        let bound = InstalledAppProbeFailurePolicy.fastFailureUpperBound
        #expect(bound > 0)
        #expect(bound < BlockingCall.queryTimeoutSeconds)
        #expect(InstalledAppProbeRetryPolicy.retryDelay > 0)

        // 重试全部耗尽的最坏**额外**等待，必须远小于一次超时 ——
        // 否则重试本身就变成了新的卡顿源。
        let worstRetryWait = InstalledAppProbeRetryPolicy.retryDelay
            * Double(InstalledAppProbeRetryPolicy.maxAttempts - 1)
        #expect(worstRetryWait < BlockingCall.queryTimeoutSeconds)
    }
}
