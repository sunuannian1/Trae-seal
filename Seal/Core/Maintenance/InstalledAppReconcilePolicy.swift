import Foundation

/// 「已安装列表」与设备对账时的**删除判据** —— 这条路径唯一的安全边界。
///
/// ## 为什么需要它（2026-09-21 用户报障）
///
/// iOS 16.2 + Lockdown 通道下，用户报告「下拉刷新 / 杀掉 Seal 后台再打开之后，
/// 已安装列表**全没了**，**连 Seal 自己都没了**」，而且**不弹窗、不报错、
/// 日志里一行都没有**。
///
/// 根因是一条**把「查询失败」读成「没装」**的链路：
/// 1. Rust 侧 `_rust_bridge_instproxy_lookup` 把「查询失败」与「没查到」
///    返回成**同一个空指针**；
/// 2. `RustInstProxy.lookup` 再把它折成 `nil`；
/// 3. 而设备核验原来暴露的是 `Bool` 版（`!= nil` 判存在）
///    ⇒ **查询失败 = 「未安装」**（fail **open**）；
/// 4. `reconcileInstalledAppsWithDevice` 对每条 `false` 直接 `delete(app)`
///    ⇒ 删记录 **＋ 删 `Documents/Apps/<UUID>` 里的 IPA 文件**，且那个循环里
///    没有 `isSeal` 过滤 ⇒ **Seal 自己也在被删之列**。
///
/// 触发时机正好落在**冷启动**：构建 175 真机实测，探测失败集中在
/// 「冷启动后 22 秒 / 自替换重启后 60 秒」，16 秒后再跑就正常
/// ⇒ **启动早期通道还没就绪**。而这条路径恰好就在启动时跑。
///
/// ## 这不是新问题 —— 描述文件回收路径早就踩过同一个坑
///
/// 2026-09-17 维护期的描述文件回收（`ProfileReclaimPolicy` + `DeviceProfileCleaner`）
/// 踩的**完全同一个**坑，当时定下三件套：**阳性对照 / 失败即中止整轮 / 决策是纯函数**。
/// 但那套安全网只落在描述文件那条路径上 —— 两条路径调的是**同一个**
/// `Minimuxer.isAppInstalled`，却只有一条有保护。
/// 本文件补上另一半，形状与 `ProfileReclaimPolicy` 刻意保持一致，便于对照阅读。
///
/// ## 真机证据（同一台设备、同一条通道）
///
/// 守卫 `R44` 注释里留着 2026-09-19 的日志：
/// 「阳性对照未通过（`com.mjorb.seal.CT8QZ7352B` 被答成未安装）」
/// —— 也就是说这台设备**确实会把「Seal 自己」答成没装**。
/// 描述文件路径靠这句话**整轮不删**；已安装列表路径把**同一个答案**
/// 当成了「删」。「Seal 自己也被删」不是巧合，**它就是阳性对照该拦下的那个信号**。
enum InstalledAppReconcilePolicy {
    /// 对某一条已安装记录的处置。
    enum Decision: Equatable {
        /// 设备上确实没装 ⇒ 删掉本地记录与文件是安全的。
        case removeRecord
        /// 设备上装着 ⇒ 保留。
        case keepInstalled
        /// **中止整轮**（一条都不再删）。
        case abortPass
    }

    /// 对账决策 —— **这是这条功能唯一的安全边界**。
    ///
    /// 做成纯函数是因为它的错法「不崩、不编译失败、只在真机上删数据」，
    /// 只能靠单测 + 守卫断言钉住。
    ///
    /// - Parameters:
    ///   - probe: 该记录 Bundle ID 的设备端核验结果（三态，复用
    ///     `ProfileReclaimPolicy.InstallProbe` —— 两条路径问的是同一个 API，
    ///     三态的定义不该有两份）。
    ///   - positiveControlPassed: **阳性对照**是否通过 —— 即「拿一个**确定已安装**的
    ///     Bundle ID（Seal 自己，我们正在运行）去问，答的是 `.installed`」。
    ///
    /// 为什么需要阳性对照：`.unavailable` 只能抓到**抛错/超时**的失败。而
    /// `RustInstProxy.lookup` 内部把 RPC 失败也返回成 `nil`，这种**静默的**失败
    /// 在单条查询上看不出来。阳性对照就是先证明「这条通道此刻说真话」，
    /// 再去信它对其它记录的回答。
    static func decision(
        probe: ProfileReclaimPolicy.InstallProbe,
        positiveControlPassed: Bool
    ) -> Decision {
        switch probe {
        // 抛错点（`Device.getFirstDevice()` / `RustIdevice.lookupApp`）都是
        // **全局性**的，不是某个 Bundle ID 特有的 ⇒ 通道已经不健康，
        // 后续查询给出的结果一律不可信，停止整轮。
        // 代价只是「本轮不对账」，下次刷新再来。
        case .unavailable:
            return .abortPass
        case .installed:
            return .keepInstalled
        case .notInstalled:
            // 阳性对照没过 ⇒ 连「确定装着的那个」都答成没装 ⇒ 通道不可信。
            return positiveControlPassed ? .removeRecord : .abortPass
        }
    }
}
