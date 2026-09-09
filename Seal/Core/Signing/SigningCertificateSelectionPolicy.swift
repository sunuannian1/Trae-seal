import Foundation

enum SigningCertificateSelectionPolicy {
    static let teamMismatchTitle = "开发者团队不匹配"

    static func validateAccountAndTeam(
        for app: AppRecord,
        account: AppleAccountRecord
    ) throws {
        // Seal：能读到 Team 时校验匹配（确定错误才拦）；读不到则放行，交给续签页手选。
        if app.isSeal {
            if let teamID = normalized(app.signingTeamID) {
                guard teamID.caseInsensitiveCompare(account.teamID) == .orderedSame else {
                    throw ImportFailure(
                        title: teamMismatchTitle,
                        reason: "当前 Seal 属于其他开发者团队，所选 Apple ID 无权续签。",
                        recovery: "使用签名 Seal 时的原 Apple ID 续签，或在续签页选择正确账号",
                        code: "SEAL-SELF-103"
                    )
                }
            }
            return
        }
        guard app.state == .installed || app.isSeal else { return }
        guard let boundAccountID = app.accountID else {
            throw ImportFailure(
                title: "缺少签名账号记录",
                reason: "这个应用没有记录上次签名使用的 Apple ID，无法自动续签。",
                recovery: "重新导入 IPA 并签名安装；Seal 自身请在「我的」中添加对应 Apple ID",
                code: "SEAL-AUTH-110"
            )
        }
        guard boundAccountID == account.id else {
            throw ImportFailure(
                title: "Apple ID 不匹配",
                reason: "这个应用是用其他 Apple ID 签名的，续签必须使用原账号。",
                recovery: "在「我的」中切换到原 Apple ID，或用当前账号重新签名安装",
                code: "SEAL-AUTH-111"
            )
        }
        guard let teamID = normalized(app.signingTeamID) else {
            throw ImportFailure(
                title: "缺少团队记录",
                reason: "这个应用没有记录上次签名使用的开发者团队，无法自动续签。",
                recovery: "重新导入 IPA 并签名安装；Seal 自身请在「我的」中添加对应 Apple ID",
                code: "SEAL-AUTH-113"
            )
        }
        guard teamID.caseInsensitiveCompare(account.teamID) == .orderedSame else {
            throw ImportFailure(
                title: teamMismatchTitle,
                reason: "这个应用属于其他开发者团队，当前 Apple ID 无权续签。",
                recovery: "使用原开发者团队的 Apple ID 续签，或用当前账号重新签名安装",
                code: "SEAL-AUTH-112"
            )
        }
    }

    static func resolvedSerialNumber(
        for app: AppRecord,
        account: AppleAccountRecord,
        requestedSerialNumber: String? = nil
    ) throws -> String? {
        try validateAccountAndTeam(for: app, account: account)
        let local = normalized(account.certificateSerialNumber)
        if let requested = normalized(requestedSerialNumber),
           let local,
           requested.caseInsensitiveCompare(local) == .orderedSame {
            return local
        }
        if let selected = normalized(account.selectedCertificateSerialNumber),
           let local,
           selected.caseInsensitiveCompare(local) == .orderedSame {
            return local
        }
        return local
    }

    static func localAvailabilityMessage(
        for app: AppRecord,
        account: AppleAccountRecord
    ) -> String? {
        do {
            try validateAccountAndTeam(for: app, account: account)
        } catch let failure as ImportFailure {
            return failure.reason
        } catch {
            return "续签账号不可用"
        }
        guard let selected = normalized(account.selectedCertificateSerialNumber) else { return nil }
        guard let local = normalized(account.certificateSerialNumber),
              selected.caseInsensitiveCompare(local) == .orderedSame else {
            return "本机没有所选证书对应的私钥，将在签名时自动处理证书。"
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// 证书序列号跨来源比对前的统一归一化：只留十六进制、转大写、剥离前导 0。
    ///
    /// 根因：AltSign（`ALTCertificate.serialNumber`）走 big-number 十六进制，会剥掉最高半字节的
    /// 前导 0；而 `ProvisioningProfileReader` 走 `SecCertificateCopySerialNumberData`，按原始 DER
    /// 字节 `%02X` 拼串，会保留最高半字节的 0（如 `0E76A893…` vs `E76A893…`）。两者实为同一证书、
    /// 同一序列号，直接 `caseInsensitiveCompare` 会误判成“证书已被轮换/不在授权列表”。
    static func normalizedSerialNumber(_ serial: String) -> String {
        let hex = serial.filter(\.isHexDigit).uppercased()
        let trimmed = hex.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}
