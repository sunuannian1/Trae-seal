import Foundation

enum SelfRenewalContextValidator {
    static func validate(
        currentBundleIdentifier: String,
        targetBundleIdentifier: String,
        currentSigningTeamIdentifier: String?,
        selectedAccount: AppleAccountRecord,
        boundAccountID: UUID?,
        selectedAccountID: UUID
    ) throws {
        guard currentBundleIdentifier.caseInsensitiveCompare(targetBundleIdentifier) == .orderedSame else {
            throw ImportFailure(
                title: "Seal 标识不匹配",
            reason: "Seal 自续签必须使用当前已安装的 Bundle ID，不能更换。",
            recovery: "恢复为当前安装的 Bundle ID 后续签",
                code: "SEAL-SELF-102"
            )
        }

        if let currentSigningTeamIdentifier,
           currentSigningTeamIdentifier.isEmpty == false,
           currentSigningTeamIdentifier.caseInsensitiveCompare(selectedAccount.teamID) != .orderedSame {
            throw ImportFailure(
                title: SigningCertificateSelectionPolicy.teamMismatchTitle,
            reason: "当前 Seal 属于其他开发者团队，所选 Apple ID 无权续签。",
            recovery: "使用签名 Seal 时的原 Apple ID 续签，或用当前账号重新安装 Seal",
                code: "SEAL-SELF-103"
            )
        }

        // A stale local account record ID is allowed when the installed profile's
        // Team still matches. Team identity is authoritative for self-renewal.
        _ = boundAccountID
        _ = selectedAccountID
    }
}
