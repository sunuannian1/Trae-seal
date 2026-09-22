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
    static func probe(bundleIdentifier: String) async -> ProfileReclaimPolicy.InstallProbe {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.isEmpty == false else { return .unavailable }

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
