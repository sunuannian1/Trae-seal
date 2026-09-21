import Foundation
import Testing
@testable import Seal

/// 覆盖“拿不到设备标识”时的根因分类与用户引导，确保不同底层错误不再被统一吞成
/// “请确认 Wi-Fi/LocalDevVPN”，而是区分配对未认可 / 握手失败 / 隧道不可达。
struct InstallChannelDiagnosticClassificationTests {
    typealias Channel = MinimuxerInstallChannel

    @Test
    func classifiesPairVerifyRejectionAsUntrusted() {
        #expect(
            Channel.classifyDiscoveryFailure(
                "minimuxer (15): UnknownErrorType(\"PairVerifyFailed\")"
            ) == .pairingNotTrusted
        )
        #expect(
            Channel.classifyDiscoveryFailure("RemotePairingError::UserDeniedPairing")
                == .pairingNotTrusted
        )
        #expect(
            Channel.classifyDiscoveryFailure("pairingRejectedWithError wrapped")
                == .pairingNotTrusted
        )
    }

    @Test
    func classifiesTlsAndRsdAsHandshake() {
        #expect(Channel.classifyDiscoveryFailure("TLS-PSK handshake failed") == .handshake)
        #expect(Channel.classifyDiscoveryFailure("RsdHandshake through tunnel failed") == .handshake)
    }

    @Test
    func classifiesSocketAndTimeoutAsTunnel() {
        #expect(Channel.classifyDiscoveryFailure("Socket: connection refused") == .tunnel)
        #expect(Channel.classifyDiscoveryFailure("operation timed out") == .tunnel)
        #expect(Channel.classifyDiscoveryFailure("network is unreachable") == .tunnel)
    }

    @Test
    func unknownDetailFallsThroughToUnknown() {
        #expect(Channel.classifyDiscoveryFailure("something completely different") == .unknown)
    }

    @Test
    func untrustedPairingProducesDedicatedRepairGuidance() {
        let failure = Channel.discoveryFailure(
            tunnelReachable: true,
            detail: "UnknownErrorType(\"PairVerifyFailed\")"
        )
        #expect(failure.code == "SEAL-PAIR-211")
        #expect(failure.reason.contains("配对助手"))
        #expect(failure.reason.contains("PairVerifyFailed"))
    }

    @Test
    func unreachableTunnelKeepsVpnGuidance() {
        let failure = Channel.discoveryFailure(tunnelReachable: false, detail: nil)
        #expect(failure.code == "SEAL-INSTALL-701")
    }

    @Test
    func reachableUnknownFailureKeepsNotRespondingCodeAndSurfacesDetail() {
        let failure = Channel.discoveryFailure(
            tunnelReachable: true,
            detail: "minimuxer (-1): weird internal state"
        )
        #expect(failure.code == "SEAL-INSTALL-708")
        #expect(failure.reason.contains("底层返回"))
        #expect(failure.reason.contains("weird internal state"))
    }

    // MARK: - 终态判定与最终归类必须同源取词

    /// 安装重试循环用 `errorDetail`、最终归类用 `diagnostic`。两者一旦取词不同，
    /// 生产路径抛的 `MinimuxerError.InstallApp(deviceError)` 经 `NSError` 桥接后
    /// 关联值（`ApplicationVerificationFailed` / `No space left on device`）全丢，
    /// 终态表就恒判「可重试」⇒ 500MB 整包被空推 3 轮。这条守卫的是「同源」本身。
    @Test
    func errorDetailAndDiagnosticReturnSameTextForNonImportFailure() {
        let errors: [Error] = [
            URLError(.timedOut),
            URLError(.networkConnectionLost),
            CocoaError(.fileWriteOutOfSpaceError)
        ]
        for error in errors {
            #expect(
                Channel.errorDetail(error) == Channel.diagnostic(error),
                "取词函数分叉：\(error)"
            )
        }
    }

    /// ImportFailure 的 `errorDescription` 是标题（「安装失败」），设备原文在 reason 里；
    /// 取词若误用 title，中文词表（「空间不足」「上限」）一条都命中不了。
    @Test
    func errorDetailReadsReasonFieldForImportFailure() {
        let failure = ImportFailure(
            title: "安装失败",
            reason: "设备返回 No space left on device",
            recovery: "清理存储空间后重试",
            code: "SEAL-INSTALL-702s"
        )
        #expect(Channel.errorDetail(failure).contains("No space left on device"))
        #expect(Channel.isTerminalInstallError(Channel.errorDetail(failure)))
    }

    /// installd 真实拒绝名必须全部落进终态表（英文走设备原文、中文走已归类文案）。
    @Test(arguments: [
        "InstallApp(ApplicationVerificationFailed)",
        "No space left on device",
        "copyfile failed: ENOSPC (28)",
        "errno 28 writing package",
        "The app could not be verified (code signature invalid)",
        "InvalidSignature",
        "ProfileExpired",
        "device is untrusted",
        "Reached maximum number of installed apps",
        "安装失败：设备存储空间不足",
        "已达免费账号设备级应用上限"
    ])
    func terminalTableRecognizesRealDeviceRejections(detail: String) {
        #expect(
            Channel.isTerminalInstallError(detail),
            "确定性拒绝被判成可重试 ⇒ 大包重传：\(detail)"
        )
    }

    /// `MissingPackagePath` 是「跨隧道会话」的可恢复错误，必须留在重试侧；
    /// 同时它不得触发 `Minimuxer.reset()`（重试循环里另有一条判据）。
    @Test
    func missingPackagePathStaysRetryable() {
        let detail = "InstallApp(MissingPackagePath)"
        #expect(Channel.isTerminalInstallError(detail) == false)
        #expect(detail.contains("MissingPackagePath"))
    }

    /// 真机实测（构建 184，源阅读）：IPA 残留的 `SC_Info` 里登记的 root sinf 路径越界时，
    /// installd 报 `ApplicationSINFCaptureFailed (Root sinf URL points outside of bundle)`。
    /// 同一份包必然同错 ⇒ 必须判为**确定性拒绝**，否则 28.7 MB 的包会被白传 3 轮
    /// （真机上确实白传了 3 轮，违反「确定性拒绝必须立即终止」）。
    @Test
    func sinfCaptureFailureIsTerminal() {
        let detail = "UnknownErrorType(\"ApplicationSINFCaptureFailed (Root sinf URL points outside of bundle)\")"
        #expect(Channel.isTerminalInstallError(detail))
    }

    // MARK: - 错误码 → 主处置动作（显式集合，不许用数字区间）

    /// 738 / 737 的 recovery 写的是「重新启动 Seal 后再试」，一旦被区间匹配算成
    /// 「重新签名」，一次点击就是全量重签 + 重传 + 并发 installd。
    @Test(arguments: [
        ("SEAL-INSTALL-738", InstallFailureAction.acknowledge),
        ("SEAL-INSTALL-737", InstallFailureAction.acknowledge),
        ("SEAL-INSTALL-702t", InstallFailureAction.acknowledge),
        ("SEAL-INSTALL-702f", InstallFailureAction.acknowledge),
        ("SEAL-INSTALL-702l", InstallFailureAction.acknowledge),
        ("SEAL-INSTALL-702s", InstallFailureAction.acknowledge),
        ("SEAL-APPID-DEVICELIMIT", InstallFailureAction.acknowledge),
        ("SEAL-INSTALL-730", InstallFailureAction.resign),
        ("SEAL-INSTALL-716", InstallFailureAction.resign),
        ("SEAL-INSTALL-735", InstallFailureAction.resign),
        ("SEAL-INSTALL-702", InstallFailureAction.reinstall),
        ("SEAL-INSTALL-705", InstallFailureAction.reinstall),
        ("SEAL-INSTALL-706b", InstallFailureAction.reinstall)
    ])
    func installCodesMapToDeclaredAction(code: String, action: InstallFailureAction) {
        #expect(InstallFailureActionPolicy.action(for: code) == action)
    }

    @Test
    func nonInstallCodesAreLeftToOtherPolicies() {
        #expect(InstallFailureActionPolicy.action(for: "SEAL-CERT-204e") == nil)
        #expect(InstallFailureActionPolicy.action(for: "SEAL-PAIR-211") == nil)
    }

    /// 每个安装族错误码只能命中一个动作； acknowledge 与 resign 两个集合不得重叠。
    @Test
    func actionSetsAreDisjoint() {
        #expect(
            InstallFailureActionPolicy.acknowledgeCodes.isDisjoint(
                with: InstallFailureActionPolicy.resignCodes
            )
        )
    }

    @Test
    func installationTransportFollowsPairingFileType() {
        #expect(pairingInstallTransport(isRemotePairing: true) == .remotePairing)
        #expect(pairingInstallTransport(isRemotePairing: false) == .lockdown)
    }
}
