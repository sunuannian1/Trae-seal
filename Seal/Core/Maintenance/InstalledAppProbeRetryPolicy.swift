import Foundation

/// 「设备核验失败之后，还要不要再问一次」的**纯判据**。
///
/// ## 为什么需要它（2026-09-22 用户报障）
///
/// 用户：「下拉刷新**有时候**还是弹窗让去检测 VPN。」
///
/// 真机日志（构建 199）显示这条路径**一点都不罕见**：
/// `SEAL-RECONCILE-003`（阳性对照未通过 ⇒ 整轮不删）在 **90 分钟里出现 10 次**，
/// 每次都是 `com.mjorb.seal.CT8QZ7352B：查询失败`；而**同一条通道 3 秒后就恢复正常**
///（10:21:30 中止 → 10:21:33 完成「探测 2 条，删除 0 条」）。
/// ⇒ 那是**通道还没起来**，不是「设备上没有这个 App」。
///
/// 对照只问一次，就必然把「还没起来」判成「通道不可信」⇒ 用户每下拉一次刷新
/// 就吃一个弹窗 ✗。重试一次（或两次）就能把这一类**假警报**消掉。
///
/// ## 两种失败必须分开（这是本判据的全部内容）
///
/// 底层是一条同步阻塞 FFI（`Minimuxer.isAppInstalled`，上限 `queryTimeoutSeconds`）。
/// 真机上它有两种**形态完全不同**的失败，`DeviceProfileCleaner` 早就按耗时区分过
///（日志里的 `查询失败(0.0s)` 与 `查询失败(15.0s)`）：
///
/// - **快速失败**（≈0 秒就抛）：RSD 会话**还没建好**，FFI 立刻返回错误
///   ⇒ 等一会儿再问多半就好了 ⇒ **值得重试**；
/// - **慢速失败**（撞满 15 秒超时）：会话**已经死了**（隧道断了 / VPN 关了）
///   ⇒ 再问一次只是**再等一个 15 秒** ⇒ **不值得重试**。
///
/// 做成纯函数是因为它的错法同样是「不崩、不编译失败，只在真机上表现为
/// 弹窗变多或刷新变慢」，只能靠单测 + 守卫断言钉住。
enum InstalledAppProbeRetryPolicy {
    /// 最多问几次（**含第一次**）。
    ///
    /// 必须有界：否则「通道一直不好」会让下拉刷新永远转圈。
    static let maxAttempts = 3

    /// 两次尝试之间的间隔（秒）。
    static let retryDelay: TimeInterval = 1.0

    /// 「快速失败」的耗时上界（秒）。达到或超过它，说明这次是**撞满超时**。
    static let fastFailureUpperBound: TimeInterval = 3.0

    /// 刚刚那次失败之后，还要不要再问一次。
    ///
    /// - Parameters:
    ///   - elapsed: **刚刚那一次**尝试的耗时（秒）。
    ///   - attemptsSoFar: 已经尝试过的次数（含刚刚那一次）。
    /// - Returns: `true` 表示值得再问一次。
    static func shouldRetry(elapsed: TimeInterval, attemptsSoFar: Int) -> Bool {
        // ① 次数上限：必须有界。
        guard attemptsSoFar < maxAttempts else { return false }
        // ② 只有**快速失败**才值得重试：慢速失败 = 会话已经死了，
        //    再问一次只是再等一个 15 秒超时（用户看到的就是「刷新一直转圈」）。
        return elapsed < fastFailureUpperBound
    }
}
