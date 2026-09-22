import Foundation
import Testing
@testable import Seal

/// `InstalledAppProbeFailurePolicy` 的判据测试。
///
/// 这条规则的错法**不会崩、不会编译失败**，只在真机上表现为两种现象：
///   - 把「快速失败」也当成「会话已死」⇒ 下拉刷新**每点一次就弹一次窗**，
///     而按钮还会把用户推进 LocalDevVPN 设置页（用户 2026-09-22 报的正是这个）；
///   - 把「撞满超时」也当成「还没起来」⇒ 会话真死了却一声不响，用户不知道要去查 VPN。
/// 两个方向都要钉住，否则「修好弹窗」会换成「坏了也没人知道」。
@Suite("设备核验失败的定性判据")
struct InstalledAppProbeFailurePolicyTests {
    /// 真机实测的两种耗时形态 —— 与 `DeviceProfileCleaner` 日志里的
    /// `查询失败(0.0s)` / `查询失败(15.0s)` 是同一对形态。
    @Test
    func fastFailureIsTransientAndTimeoutIsSessionDead() {
        #expect(InstalledAppProbeFailurePolicy.kind(elapsed: 0.0) == .transient)
        #expect(InstalledAppProbeFailurePolicy.kind(elapsed: 0.4) == .transient)
        #expect(
            InstalledAppProbeFailurePolicy.kind(elapsed: BlockingCall.queryTimeoutSeconds)
                == .sessionDead
        )
    }

    /// 恰好落在上界上算「慢」—— 与重试判据的 `<` **严格互补**。
    /// 不互补的话，同一个耗时既「值得重试」又「会话已死」，两条判据会互相打架。
    @Test
    func boundaryIsComplementaryToRetryDecision() {
        let bound = InstalledAppProbeFailurePolicy.fastFailureUpperBound
        #expect(InstalledAppProbeFailurePolicy.kind(elapsed: bound) == .sessionDead)
        #expect(InstalledAppProbeFailurePolicy.kind(elapsed: bound.nextDown) == .transient)
        #expect(InstalledAppProbeRetryPolicy.shouldRetry(elapsed: bound, attemptsSoFar: 1) == false)
        #expect(InstalledAppProbeRetryPolicy.shouldRetry(elapsed: bound.nextDown, attemptsSoFar: 1))
    }

    /// 只有「会话已死」才值得打断用户。
    /// 这是「假警报」的闸门：真机实测「通道还没起来」3 秒后自己就好了，
    /// 而弹窗的按钮会被 `settingsRoute` 路由到 LocalDevVPN 设置页 ⇒ 用户被白推一次。
    @Test
    func onlySessionDeadDeservesUserAttention() {
        #expect(InstalledAppProbeFailurePolicy.deservesUserAttention(.sessionDead))
        #expect(InstalledAppProbeFailurePolicy.deservesUserAttention(.transient) == false)
    }

    /// 上界必须**有限且远离两侧**：太大 ⇒ 把「会话已死」也当成快速失败（白等三轮）；
    /// 太小 ⇒ 真机上那种「0.x 秒抛错」一次都判不出来（等于没修）。
    @Test
    func boundIsFiniteAndSane() {
        let bound = InstalledAppProbeFailurePolicy.fastFailureUpperBound
        #expect(bound > 0)
        #expect(bound < BlockingCall.queryTimeoutSeconds)
    }
}
