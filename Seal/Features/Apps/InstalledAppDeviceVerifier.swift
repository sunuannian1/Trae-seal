import Foundation
@preconcurrency import Minimuxer

struct InstalledAppDeviceVerifier {
    /// 设备端「该 Bundle ID 装了没」的**三态**核验。
    ///
    /// ## ⚠️ 为什么**不**返回 `Bool`（2026-09-21 用户报障后改）
    ///
    /// 原来这里是 `isInstalled(bundleIdentifier:)`，返回 `Bool`。
    /// `Bool` 本身没错，错的是它**诱使调用方把失败折成 `false`** ——
    /// 一句 `try?` 加默认值就能把「查询失败」读成「没装」。
    /// 而底层那条链路**已经把「查询失败」折成了空值**
    /// （`RustInstProxy.lookup` 折 nil，正是 `isAppInstalled` 走的 `else` 分支），
    /// 于是真机上出现的正是这个形态：冷启动时通道还没就绪 ⇒ 每条都答「没装」
    /// ⇒ 整个已安装列表被删（连 Seal 自己都没了），
    /// 而且**不弹窗、不报错、日志里一行都没有**。
    ///
    /// ⇒ 把三态**交出去**，调用方**没有机会**把失败读成「否」。
    /// `.unavailable` 既不是「装了」也不是「没装」，
    /// 调用方必须按 `InstalledAppReconcilePolicy` 的约定**中止整轮**（fail closed）。
    ///
    /// 三态复用 `ProfileReclaimPolicy.InstallProbe` —— 描述文件回收路径
    /// 问的是**同一个** `Minimuxer.isAppInstalled`，三态的定义不该有两份。
    /// 一次「带重试的核验」的完整交代。
    ///
    /// 为什么要交出来：`SEAL-RECONCILE-003` 那条日志此前**只有一句「查询失败」**，
    /// 分不清「通道还没起来（快速失败）」与「会话已经死了（撞满超时）」——
    /// 而这两种情况该做的事完全不同：前者等一会儿就好，后者要用户去查 VPN。
    /// 耗时与尝试次数一并交出去，日志才有归因能力。
    struct ProbeOutcome: Equatable {
        /// 最终的三态结论。
        let probe: ProfileReclaimPolicy.InstallProbe
        /// 实际尝试了几次（`> 1` 表示是重试救回来的）。
        let attempts: Int
        /// **最后一次**尝试的耗时（秒）—— 用来区分快速失败与超时。
        let elapsed: TimeInterval
        /// 所有尝试加起来的耗时（秒）。
        let totalElapsed: TimeInterval
    }

    static func probe(bundleIdentifier: String) async -> ProfileReclaimPolicy.InstallProbe {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.isEmpty == false else { return .unavailable }
        return await singleProbe(identifier: identifier)
    }

    /// 带**有界重试**的核验 —— 只给**阳性对照**用。
    ///
    /// ## 为什么只给阳性对照
    ///
    /// 阳性对照是整条路径的**闸门**，也是**最便宜**的一次查询（一条）。它过了就说明
    /// 「这条通道此刻说真话」，后面每条记录只问一次即可 —— 那时再失败就是**真的**
    /// 失败了，重试只会把 N 条记录的耗时乘上 3。
    ///
    /// ## ⚠️ 只重试 `.unavailable`
    ///
    /// `.installed` / `.notInstalled` 是**确定性答案**。重试它们等于给同一个问题
    /// **一次改口的机会**，而「同一台设备先后给出不同答案」正是 2026-09-21 那次
    /// 「已安装列表全没了、连 Seal 自己都没了」的形态。
    /// ⇒ 这里用一个显式的 `guard probe == .unavailable else` 把话说死。
    static func probeResilient(bundleIdentifier: String) async -> ProbeOutcome {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.isEmpty == false else {
            return ProbeOutcome(probe: .unavailable, attempts: 0, elapsed: 0, totalElapsed: 0)
        }

        var attempts = 0
        var totalElapsed: TimeInterval = 0
        while true {
            let startedAt = Date()
            let probe = await singleProbe(identifier: identifier)
            let elapsed = Date().timeIntervalSince(startedAt)
            attempts += 1
            totalElapsed += elapsed

            // 确定性答案**立刻交出**，不重试（见上面的说明）。
            guard probe == .unavailable else {
                return ProbeOutcome(
                    probe: probe,
                    attempts: attempts,
                    elapsed: elapsed,
                    totalElapsed: totalElapsed
                )
            }
            // 重试判据走纯函数：单测与守卫都钉在 `InstalledAppProbeRetryPolicy` 上，
            // 不要在调用点写成字面量（否则「必须有界」「只重试快速失败」两条都失去约束）。
            guard InstalledAppProbeRetryPolicy.shouldRetry(
                elapsed: elapsed,
                attemptsSoFar: attempts
            ) else {
                return ProbeOutcome(
                    probe: .unavailable,
                    attempts: attempts,
                    elapsed: elapsed,
                    totalElapsed: totalElapsed
                )
            }
            try? await Task.sleep(
                nanoseconds: UInt64(InstalledAppProbeRetryPolicy.retryDelay * 1_000_000_000)
            )
        }
    }

    /// 单次核验（**无重试**）。`probe` 与 `probeResilient` 共用同一份实现 ——
    /// 两条路必须问的是**同一个** API，否则「阳性对照」证明不了任何事。
    private static func singleProbe(identifier: String) async -> ProfileReclaimPolicy.InstallProbe {
        // ⚠️ **必须有界**：`isAppInstalled` 是同步阻塞 FFI，在一条已死的 RSD 缓存会话上
        // **不报错、只阻塞到操作系统放弃**（与安装路径同一个失败模式）。
        // 只放到 `Task.detached` 是不够的 —— 那只是把它挪出主线程，**阻塞本身仍然无界**。
        // 超时按「不知道」处理（`.unavailable`），调用方按约定**中止整轮**（fail closed）。
        let outcome = await BlockingCall.bounded(seconds: BlockingCall.queryTimeoutSeconds) {
            // 查询前重置连接，避免使用已断开的 RSD 缓存连接导致误判
            Install.resetProvider()
            return try Minimuxer.isAppInstalled(bundleId: identifier)
        }
        guard let outcome else { return .unavailable }
        do {
            return try outcome.get() ? .installed : .notInstalled
        } catch {
            return .unavailable
        }
    }
}
