import Foundation

enum InstallDiagnosticStepKind: String, Codable, Sendable {
    case pairingFile
    case vpnTunnel
    case minimuxer
    case deviceIdentifier
    case pairingMatch
    case installationService
}

struct InstallDiagnosticStep: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case pending
        case running
        case passed
        case failed(ImportFailure)
    }

    let kind: InstallDiagnosticStepKind
    var status: Status

    var title: String {
        switch kind {
        case .pairingFile: "设备配对"
        case .vpnTunnel: "VPN 通道"
        case .minimuxer: "本机连接"
        case .deviceIdentifier: "设备响应"
        case .pairingMatch: "配对匹配"
        case .installationService: "安装服务"
        }
    }

    var valueText: String {
        switch status {
        case .pending: "待检测"
        case .running: "检测中"
        case .passed: "正常"
        case .failed(let failure): failure.title
        }
    }
}

struct InstallChannelDiagnostics: Equatable, Sendable {
    var steps: [InstallDiagnosticStep]
    var deviceIdentifier: String?
    var failure: ImportFailure?

    var isReady: Bool {
        failure == nil && steps.allSatisfy { step in
            if case .passed = step.status { return true }
            return false
        }
    }

    static var empty: InstallChannelDiagnostics {
        InstallChannelDiagnostics(
            steps: InstallDiagnosticStepKind.allCasesForDisplay.map {
                InstallDiagnosticStep(kind: $0, status: .pending)
            },
            deviceIdentifier: nil,
            failure: nil
        )
    }
}

extension InstallDiagnosticStepKind {
    static let allCasesForDisplay: [InstallDiagnosticStepKind] = [
        .pairingFile,
        .vpnTunnel,
        .minimuxer,
        .deviceIdentifier,
        .pairingMatch,
        .installationService
    ]
}

/// 安装/续签失败交给用户的主处置动作。
///
/// 判据必须是**显式码集合**，不能是 `hasPrefix("SEAL-INSTALL-73")` 这类数字区间：
/// 区间会把 `SEAL-INSTALL-738`（上一笔安装仍在跑）与 735/737（需重启 Seal）一并算成
/// 「重新签名」，于是界面把用户引导去做一次全量重签 + 重传 —— 正好制造它想避免的
/// 并发 installd。同理 `SEAL-INSTALL-702t`（超时 ≠ 失败）也绝不能映射成「重新安装」。
enum InstallFailureAction: Equatable, Sendable {
    /// 确定性拒绝或需人工处理：关闭结果页，不在应用内重试。
    case acknowledge
    /// 签名包本身有问题：必须重新签名，重装同一个坏包不改变结果。
    case resign
    /// 通道 / 连接类失败：可安全重跑安装。
    case reinstall
}

enum InstallFailureActionPolicy {
    /// 立即终止、不重试（recovery 文案各自说明后续人工动作）。
    static let acknowledgeCodes: Set<String> = [
        "SEAL-INSTALL-702f",   // DRM 元数据残留（SC_Info/sinf）：该 IPA 需重新砸壳导出
        "SEAL-INSTALL-702l",   // iOS 拒绝：免费账号 3 应用上限 / 完整性校验
        "SEAL-INSTALL-702s",   // 设备存储空间不足
        "SEAL-INSTALL-702t",   // 安装超时：底下很可能仍在跑，重跑即并发安装
        "SEAL-INSTALL-737",    // 自更新事务未就绪：重新启动 Seal 后再续签
        "SEAL-INSTALL-738",    // 上一笔自替换安装仍在进行：等它结束或重启 Seal
        "SEAL-APPID-DEVICELIMIT"
    ]

    /// 需重新签名的签名包内容类失败（缺失 / 损坏 / 过期 / 设备或 Team 不符 / 结构不完整）。
    static let resignCodes: Set<String> = [
        "SEAL-INSTALL-711",
        "SEAL-INSTALL-712",
        "SEAL-INSTALL-713",
        "SEAL-INSTALL-714",
        "SEAL-INSTALL-714a",
        "SEAL-INSTALL-715",
        "SEAL-INSTALL-716",
        "SEAL-INSTALL-717",
        "SEAL-INSTALL-718",
        "SEAL-INSTALL-719",
        "SEAL-INSTALL-720",
        "SEAL-INSTALL-721",
        "SEAL-INSTALL-722",
        "SEAL-INSTALL-723",
        "SEAL-INSTALL-724",
        "SEAL-INSTALL-725",
        "SEAL-INSTALL-726",
        "SEAL-INSTALL-727",
        "SEAL-INSTALL-728",
        "SEAL-INSTALL-729",
        "SEAL-INSTALL-730",
        "SEAL-INSTALL-735"
    ]

    /// 返回 nil 表示不属于安装族（证书 / 配对 / 网络等由调用方其余判据处理）。
    static func action(for code: String) -> InstallFailureAction? {
        if acknowledgeCodes.contains(code) { return .acknowledge }
        if resignCodes.contains(code) { return .resign }
        // 同族动作相同，这一处前缀匹配是安全的；数字区间匹配才危险。
        return code.hasPrefix("SEAL-INSTALL-") ? .reinstall : nil
    }
}

