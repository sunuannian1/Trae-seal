enum SigningStage: String, CaseIterable, Equatable, Sendable {
    case waitingForChannel
    case preparingAccount
    case preparingCertificate
    case preparingAppID
    case preparingProfiles
    case signing
    case pushing
    case installing
    case verifying

    func stageTitle(isRenewal: Bool) -> String {
        switch self {
        case .waitingForChannel:
            return "正在连接设备"
        case .preparingAccount:
            return "正在验证 Apple ID"
        case .preparingCertificate:
            return "正在申请证书"
        case .preparingAppID:
            return "正在注册 Bundle ID"
        case .preparingProfiles:
            return "正在申请描述文件"
        case .signing:
            return isRenewal ? "正在重新签名" : "正在签名"
        case .pushing:
            return "正在传输到设备"
        case .installing:
            return "正在安装"
        case .verifying:
            return "正在验证安装"
        }
    }
}
