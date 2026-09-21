import Foundation
import Testing
@testable import Seal

/// R70：安装通道诊断必须**留痕**，且那行日志要能直接说出「卡在哪一步」。
///
/// 2026-09-21 真机（iOS 16.2，构建 196）：界面停在「验证中」，而用户导出的 27 行
/// 日志里**成功行与失败行都不出现** ⇒ 用户和我都无法判断是「还在跑」还是「已经死了」。
/// 根因是 `MinimuxerInstallChannel.diagnose()` 全程零日志（约 160 行里零埋点），
/// 而它恰好是本链路唯一可能长时间静默的区间。
///
/// ⚠️ 为什么这需要**单测**：守卫只能断言「源码里有 `stepsSummary` 这个符号」，
/// 证明不了「它真的把每一步的名字与状态都写出来了」—— 而那正是排障唯一的信息来源
/// （源码断言守「形状」，单测守「行为」）。
struct InstallChannelDiagnosticSummaryTests {
    typealias Channel = MinimuxerInstallChannel

    private func steps(
        _ overrides: [InstallDiagnosticStepKind: InstallDiagnosticStep.Status]
    ) -> [InstallDiagnosticStep] {
        InstallChannelDiagnostics.empty.steps.map { step in
            var copy = step
            if let status = overrides[step.kind] { copy.status = status }
            return copy
        }
    }

    @Test
    func summaryNamesEveryStepWithItsOwnStatus() {
        let text = Channel.stepsSummary(
            steps([
                .pairingFile: .passed,
                .vpnTunnel: .failed(
                    ImportFailure(
                        title: "LocalDevVPN 未就绪",
                        reason: "隧道未连接",
                        recovery: "连接 LocalDevVPN 后重试",
                        code: "SEAL-INSTALL-701"
                    )
                )
            ])
        )

        // 「已通过 / 已失败 / 还没轮到」三种状态必须**互相可区分** ——
        // 否则日志只会说一句「检测中」，等于没留痕。
        #expect(text.contains("设备配对=正常"))
        #expect(text.contains("VPN 通道=LocalDevVPN 未就绪"))
        #expect(text.contains("本机连接=待检测"))
    }

    @Test
    func summaryCoversEveryDisplayedStep() {
        let text = Channel.stepsSummary(InstallChannelDiagnostics.empty.steps)
        // ⚠️ 先断言「扫到的步数」下限：枚举漂移成空集时循环体一次都不执行 ⇒ 永远绿。
        #expect(InstallDiagnosticStepKind.allCasesForDisplay.count >= 6)
        for kind in InstallDiagnosticStepKind.allCasesForDisplay {
            let title = InstallDiagnosticStep(kind: kind, status: .pending).title
            #expect(text.contains("\(title)=待检测"), "缺少 \(title) 时日志说不出卡在哪一步")
        }
    }
}
