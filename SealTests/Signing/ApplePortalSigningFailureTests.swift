import Foundation
import Testing
@testable import Seal

struct ApplePortalSigningFailureTests {
    @Test
    func identifiesAppIDFailuresInsteadOfCollapsingThemIntoGenericSigningFailure() {
        let failure = ApplePortalSigningFailure.make(
            stage: .appID,
            error: NSError(
                domain: "ApplePortal",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "Bundle identifier is unavailable."]
            )
        )

        #expect(failure.code == "SEAL-APPID-302")
        // 占用语义：reason 用「其他开发者账号」表达 Bundle ID 被占，而非塌缩成通用签名失败
        // （reason 现会拼入底层 Apple 错误码便于排查，故不再断言技术细节被隐藏）
        #expect(failure.reason.contains("其他开发者账号"))
    }

    @Test
    func matchesExistingBundleIdentifiersWithoutCaseSensitivity() {
        #expect(
            ApplePortalAppIDResolver.matches(
                existingBundleIdentifier: "com.Example.Demo",
                requestedBundleIdentifier: "com.example.demo"
            )
        )
    }

    @Test
    func certificateLimitFailureDoesNotAuthorizeAutomaticRevocation() {
        let failure = ApplePortalSigningFailure.make(
            stage: .certificate,
            error: NSError(
                domain: "ApplePortal",
                code: 3022,
                userInfo: [NSLocalizedDescriptionKey: "Maximum number of certificates reached"]
            )
        )

        // 证书上限被细分为 SEAL-CERT-204a，并给出更具指导性的中文原因与恢复建议
        #expect(failure.code == "SEAL-CERT-204a")
        #expect(failure.reason.contains("证书数量已达上限"))
        #expect(failure.recovery.contains("撤销一个旧签名证书"))
    }

    @Test
    func unclassifiedAccountFailureDoesNotForceReverification() {
        let failure = ApplePortalSigningFailure.make(
            stage: .account,
            error: NSError(
                domain: "ApplePortal",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected response"]
            )
        )

        #expect(failure.code == "SEAL-VERIFY-500")
        #expect(AppleServiceFailurePolicy.shouldRequireReverification(failure) == false)
    }

    @Test
    func networkFailureIsSeparatedFromAuthenticationAndTechnicalDetailsAreHidden() {
        let failure = ApplePortalSigningFailure.make(
            stage: .provisioningProfile,
            error: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
            )
        )

        #expect(failure.code.hasPrefix("SEAL-NET-"))
        // 安抚语义保留（账号/已签应用不受影响），仅措辞随网络文案重写而更新；技术细节继续隐藏
        #expect(failure.reason.contains("不会受影响"))
        #expect(failure.reason.contains("NSURLErrorDomain") == false)
        #expect(failure.reason.contains("-1001") == false)
    }
}
