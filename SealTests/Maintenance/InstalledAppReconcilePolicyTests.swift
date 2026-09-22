import Foundation
import Testing
@testable import Seal

/// `InstalledAppReconcilePolicy` 的判据测试。
///
/// 这条规则的错法**不会崩、不会编译失败、也不会跑挂别的单测** ——
/// 它只会在真机上**静默删掉**用户的已安装列表（连 Seal 自己都没了），
/// 不弹窗、不报错、日志里一行都没有。所以这里要把每个方向都钉住：
///   1. 设备上确实没装的必须被认出来（否则功能空转，列表里堆着已卸载的 App）；
///   2. 通道不可信时**一条都不许删**（否则冷启动即清空列表）。
@Suite("已安装列表对账的删除判据")
struct InstalledAppReconcilePolicyTests {
    /// 设备上确实装着 ⇒ 保留。
    @Test
    func installedRecordIsAlwaysKept() {
        #expect(
            InstalledAppReconcilePolicy.decision(probe: .installed, positiveControlPassed: true)
                == .keepInstalled
        )
        // 阳性对照没过也一样：装着就是装着，不该被删。
        #expect(
            InstalledAppReconcilePolicy.decision(probe: .installed, positiveControlPassed: false)
                == .keepInstalled
        )
    }

    /// 设备上确实没装、且阳性对照通过 ⇒ 才允许删。
    /// 这一条与下一条**必须同时存在**：只留这条会让「通道抖动 ⇒ 全删」敞开。
    @Test
    func notInstalledWithPassedControlIsTheOnlyRemovableCase() {
        #expect(
            InstalledAppReconcilePolicy.decision(probe: .notInstalled, positiveControlPassed: true)
                == .removeRecord
        )
    }

    /// 阳性对照没过（连「Seal 自己」都答成没装）⇒ 通道不可信 ⇒ 中止整轮。
    /// 没有这一条，「隧道抖动 / 冷启动通道未就绪 ⇒ 全部答成未安装 ⇒ 全删」的路径是敞开的。
    @Test
    func failedPositiveControlNeverRemoves() {
        #expect(
            InstalledAppReconcilePolicy.decision(probe: .notInstalled, positiveControlPassed: false)
                == .abortPass
        )
    }

    /// 查询失败（超时 / 抛错）**既不是「装了」也不是「没装」** ⇒ 必须中止整轮。
    /// 把它读成「没装」正是 2026-09-21 那次「列表全没了」的根因。
    @Test
    func failedProbeAbortsTheWholePassInsteadOfRemoving() {
        #expect(
            InstalledAppReconcilePolicy.decision(probe: .unavailable, positiveControlPassed: true)
                == .abortPass
        )
        #expect(
            InstalledAppReconcilePolicy.decision(probe: .unavailable, positiveControlPassed: false)
                == .abortPass
        )
    }

    /// 中止是**全局**的，不是逐条的：调用方收到 `.abortPass` 后必须停止整个循环。
    /// 这条用例把「模拟一整轮」写出来，钉住「不会因为后面还有记录就继续删」。
    @Test
    func abortPassStopsTheWholePass() {
        // 三条记录：第一条答未安装、第二条查询失败、第三条也会答未安装。
        let probes: [ProfileReclaimPolicy.InstallProbe] = [.notInstalled, .unavailable, .notInstalled]
        var decisions: [InstalledAppReconcilePolicy.Decision] = []
        var removed: [Int] = []

        for (index, probe) in probes.enumerated() {
            let decision = InstalledAppReconcilePolicy.decision(
                probe: probe,
                positiveControlPassed: true
            )
            decisions.append(decision)
            guard decision == .abortPass else {
                if decision == .removeRecord { removed.append(index) }
                continue
            }
            break // ← 关键：中止后不再处理剩余记录
        }

        #expect(decisions == [.removeRecord, .abortPass])
        // 中止发生在第二条 ⇒ 第三条**没有被询问**，也就没有被删。
        #expect(removed == [0])
    }

    /// 阳性对照没过时，一份记录都不该走到 `.removeRecord`。
    @Test
    func noRecordIsEverRemovedWhenPositiveControlFails() {
        let allProbes: [ProfileReclaimPolicy.InstallProbe] = [.installed, .notInstalled, .unavailable]
        for probe in allProbes {
            let decision = InstalledAppReconcilePolicy.decision(
                probe: probe,
                positiveControlPassed: false
            )
            #expect(decision != .removeRecord, "对照没过时 \(probe) 不该被判为可删")
        }
    }

    /// 三态必须各有自己的日志名 —— 「删除 0」到底是「形态没匹配」还是「通道不可信」，
    /// 全靠这几个字区分（它们同时被写进中止日志里）。
    @Test
    func probeStatesHaveDistinctLogNames() {
        let names = [
            ProfileReclaimPolicy.InstallProbe.installed.logName,
            ProfileReclaimPolicy.InstallProbe.notInstalled.logName,
            ProfileReclaimPolicy.InstallProbe.unavailable.logName,
        ]
        #expect(Set(names).count == 3)
        #expect(names.allSatisfy { $0.isEmpty == false })
    }

    /// 删除前的**二次确认**：两次答案必须都是「未安装」才允许删（2026-09-22 构建 201 日志）。
    ///
    /// 阳性对照只能证明「通道整体是通的」，证明不了「它对**这一个** Bundle ID 的否定
    /// 答案是对的」—— 底层把 lookup 的 `Err` 与「没查到」折成同一个空指针，
    /// 所以**单条**查询失败也会伪装成「没装」。而删除是不可逆的。
    @Test
    func confirmationMustAgreeBeforeRemoving() {
        // 只有两次都答「未安装」才放行。
        #expect(
            InstalledAppReconcilePolicy.confirmedRemoval(
                first: .notInstalled, confirmation: .notInstalled
            )
        )
        // 复核答「装着」⇒ 第一次的否定答案不可信 ⇒ 不许删。
        #expect(
            InstalledAppReconcilePolicy.confirmedRemoval(
                first: .notInstalled, confirmation: .installed
            ) == false
        )
        // 复核**问不通**（超时 / 抛错）⇒ 同样不许删（`nil` 不能被读成「没装」）。
        #expect(
            InstalledAppReconcilePolicy.confirmedRemoval(
                first: .notInstalled, confirmation: .unavailable
            ) == false
        )
        // 第一次就不是否定答案 ⇒ 本来就不该走到删除，这里也必须为假。
        #expect(
            InstalledAppReconcilePolicy.confirmedRemoval(
                first: .installed, confirmation: .notInstalled
            ) == false
        )
    }
}
