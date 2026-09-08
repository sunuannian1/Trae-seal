import Foundation
@preconcurrency import AltSign

enum AppleAuthenticationStage: Sendable {
    case signIn
    case teamLookup
}

enum AppleAuthenticationFailure {
    static func make(stage: AppleAuthenticationStage, error: Error) -> ImportFailure {
        if AppleServiceFailurePolicy.isNetworkError(error) {
            return AppleServiceFailurePolicy.networkFailure(
                title: "无法连接 Apple",
                reason: "当前网络或 Apple 服务不可用。账号状态不会被修改。"
            )
        }
        switch stage {
        case .signIn:
            let nsError = error as NSError
            var parts: [String] = []
            parts.append("类型：\(String(describing: type(of: error)))")
            parts.append("Domain：\(nsError.domain)")
            parts.append("Code：\(nsError.code)")
            parts.append("描述：\(nsError.localizedDescription)")
            if let debugDesc = nsError.userInfo["NSDebugDescription"] as? String {
                parts.append("调试：\(debugDesc)")
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                parts.append("嵌套：\(underlying.domain)/\(underlying.code) \(underlying.localizedDescription)")
            }
            let detail = parts.joined(separator: "\n")
            return ImportFailure(
                title: "无法添加账号",
                reason: "Apple ID 验证失败。\n\(detail)",
                recovery: "重试",
                code: "SEAL-AUTH-107a"
            )
        case .teamLookup:
            return ImportFailure(
                title: "无法添加账号",
                reason: "验证码已接受，但 Apple 没有返回可用的开发团队。",
                recovery: "重试",
                code: "SEAL-AUTH-105f"
            )
        }
    }
}

@MainActor
final class AppleAccountClient {
    private let anisetteProvider: any AnisetteProvider

    /// 与 AltSign User-Agent 中 com.apple.dt.Xcode/26.0 保持一致
    nonisolated static let xcodeVersion = "26.0"

    nonisolated init(anisetteProvider: any AnisetteProvider = AnisetteV3Client()) {
        self.anisetteProvider = anisetteProvider
    }

    func authenticate(
        email: String,
        password: String,
        verificationCode: @escaping @MainActor @Sendable () async -> String?
    ) async throws -> AuthenticatedAppleAccount {
        // 认证时强制使用本地 anisette（fetchForAuthentication），不允许降级远程。
        // 用远程 machineID 认证会导致 authToken 与远程绑定，之后切回本地时
        // machineID 漂移，Apple 判定会话异常返回 1100，表现为"添加 ID 后就失效"。
        // 本地生成失败直接报错，让用户重试，不要用远程添加 ID。
        //
        // 【不要在这里清 adi.pb 重试】machineID 变化会让所有已登录账号签名时
        // 掉线（1100 需重新添加）——此路径曾被试过并造成严重回归。
        // Apple 拒绝本地 anisette 时直接报错，由用户决定是否手动重置签名环境。
        try await withTimeout(seconds: 240) {
            try await self.authenticateOnce(
                email: email,
                password: password,
                verificationCode: verificationCode
            )
        }
    }

    /// 判断认证错误是否值得"清本地指纹、换远程 Anisette"后自动重试一次。
    /// 覆盖：Apple 判 anisette 无效、认证端点返回 HTML 导致 plist 解析失败(NSCocoa 3840)、坏服务器响应。
    private nonisolated static func shouldRetryWithRemoteAnisette(_ error: Error) -> Bool {
        if case ALTAppleAPIError.invalidAnisetteData = error { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == 3840 { return true }
        if let urlError = error as? URLError, urlError.code == .badServerResponse { return true }
        // AltSign invalidResponse（Apple 返回 503/HTML 等非 plist 响应）也换远程 Anisette 重试
        if ns.domain == "AltSign.ALTServerError", ns.code == 1 { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSCocoaErrorDomain, underlying.code == 3840 { return true }
        return false
    }

    /// Apple 对认证/团队请求返回 503（国内直连 gsa.apple.com 的线路时通时断）时
    /// 自动间隔重试：隔几秒重发往往就能通过，避免用户必须挂梯子。
    private static func retryOnApple503<T>(
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        // 3 次尝试：立即 / +3s / +8s
        let backoffs: [UInt64] = [0, 3_000_000_000, 8_000_000_000]
        var lastError: Error?
        for delay in backoffs {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            do {
                return try await operation()
            } catch {
                lastError = error
                let message = (error as NSError).localizedDescription
                if message.contains("503") || message.contains("Service Temporarily Unavailable") {
                    continue
                }
                throw error
            }
        }
        throw lastError ?? URLError(.badServerResponse)
    }

    /// 给异步操作加超时，超时后抛出超时错误。
    /// 认证可能卡在无法协作取消的调用里（本地 ADI 模拟、AltSign 内部回调），
    /// 因此必须用可遗弃竞速：超时先到就抛错，未完成的认证在后台自行结束后被丢弃。
    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await HardTimeout.run(seconds: seconds, operation)
        } catch let error as HardTimeout.TimeoutError {
            // 必须以 ImportFailure 抛出，否则上层 addAccount 的兜底 catch
            // 会把超时改写成误导性的“Apple ID 验证失败”。
            throw ImportFailure(
                title: "添加账号超时",
                reason: "Apple 认证在 \(Int(error.seconds)) 秒内没有完成。常见原因：当前网络无法访问 Apple 服务器，或本地签名内核生成设备环境时卡住。",
                recovery: "检查网络后重试；如多次超时，尝试更换网络（需可访问国际网络）",
                code: "SEAL-AUTH-107t"
            )
        }
    }

    /// 自动重新登录（authToken 失效 1100 时使用）
    /// verificationCode 闭包在需要双重验证码时被调用，返回用户输入的验证码；返回 nil 表示取消
    func reauthenticate(
        email: String,
        password: String,
        verificationCode: @escaping @MainActor @Sendable () async -> String?
    ) async throws -> AccountSecret {
        let anisetteData = try await anisetteProvider.fetchForAuthentication()
        let auth = try await authenticate(
            email: email,
            password: password,
            anisetteData: anisetteData,
            verificationCode: verificationCode
        ).value
        return AccountSecret(
            email: email,
            accountIdentifier: auth.account.identifier,
            dsid: auth.session.dsid,
            authToken: auth.session.authToken,
            password: password
        )
    }

    private func authenticateOnce(
        email: String,
        password: String,
        verificationCode: @escaping @MainActor @Sendable () async -> String?
    ) async throws -> AuthenticatedAppleAccount {
        var stage: AppleAuthenticationStage = .signIn
        do {
            try Task.checkCancellation()
            let anisetteData = try await anisetteProvider.fetchForAuthentication()
            let auth = try await Self.retryOnApple503 {
                try await self.authenticate(
                    email: email,
                    password: password,
                    anisetteData: anisetteData,
                    verificationCode: verificationCode
                ).value
            }
            try Task.checkCancellation()
            stage = .teamLookup
            let teams = try await Self.retryOnApple503 {
                try await self.fetchTeams(
                    account: auth.account,
                    session: auth.session
                )
            }
            try Task.checkCancellation()
            let availableTeams = teams
                .filter { $0.type != .unknown }
                .map {
                    AppleTeamRecord(
                        id: $0.identifier,
                        name: $0.name,
                        isFreeTeam: $0.type == .free
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isFreeTeam != rhs.isFreeTeam { return lhs.isFreeTeam == false }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            guard availableTeams.isEmpty == false else {
                throw ImportFailure(
                    title: "未找到开发者团队",
                    reason: "这个 Apple ID 没有可用的开发者团队（免费账号也会自动创建免费团队）。",
                    recovery: "确认该 Apple ID 已在 Apple 开发者网站同意协议，或更换其他 Apple ID",
                    code: "SEAL-AUTH-103"
                )
            }

            let secret = AccountSecret(
                email: email,
                accountIdentifier: auth.account.identifier,
                dsid: auth.session.dsid,
                authToken: auth.session.authToken,
                password: password
            )
            return AuthenticatedAppleAccount(
                maskedEmail: Self.mask(email),
                accountIdentifier: auth.account.identifier,
                teams: availableTeams,
                secret: secret,
                verifiedAt: Date()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch ALTAppleAPIError.incorrectVerificationCode {
            throw ImportFailure(
                title: "无法添加账号",
                reason: "Apple 拒绝了当前验证码（验证码无效或已过期）。",
                recovery: "获取最新验证码后重新输入",
                code: "SEAL-AUTH-101"
            )
        } catch ALTAppleAPIError.incorrectCredentials {
            throw ImportFailure(
                title: "无法添加账号",
                reason: "Apple 拒绝了账号 \(Self.mask(email)) 的登录凭据（Apple ID 不存在或密码错误）。",
                recovery: "核对 Apple ID 与密码后重试；忘记密码请先到 Apple 官网重置",
                code: "SEAL-AUTH-102a"
            )
        } catch ALTAppleAPIError.invalidAnisetteData {
            throw ALTAppleAPIError(.invalidAnisetteData)
        } catch let failure as ImportFailure {
            throw failure
        } catch {
            // Apple 判 anisette 无效 / 认证端点返回 HTML(3840) / 坏服务器响应：
            // 不做任何自动重置（machineID 变化会让已登录账号全部掉线），
            // 以明确的错误呈现，由用户决定是否手动重置签名环境。
            if Self.shouldRetryWithRemoteAnisette(error) {
                let underlying = (error as NSError).localizedDescription
                throw ImportFailure(
                    title: "无法添加账号",
                    reason: "Apple 拒绝了本次认证使用的设备环境数据（Anisette）。\n底层错误：\(underlying)",
                    recovery: "重试；如持续失败，到「我的」页面手动重置签名环境（会导致已登录 ID 需重新验证）",
                    code: "SEAL-ANI-115"
                )
            }
            // Apple 拒绝认证握手，通常与 Anisette 设备环境数据无效有关，
            // 而不是用户网络问题，必须与“验证失败/网络”区分开。
            if let apiError = error as? ALTAppleAPIError,
               case .authenticationHandshakeFailed = apiError {
                let underlying = (apiError as NSError).localizedDescription
                throw ImportFailure(
                    title: "无法添加账号",
                    reason: "Apple 拒绝了本次认证请求。常见原因：设备环境数据（Anisette）无效或系统时间偏差。\n底层错误：\(underlying)",
                    recovery: "稍后重试；如持续失败，尝试更换网络或核对系统时间",
                    code: "SEAL-AUTH-107h"
                )
            }
            if error is AnisetteV3Error {
                throw Self.failure(from: error)
            }
            throw AppleAuthenticationFailure.make(stage: stage, error: error)
        }
    }

    func validate(
        account: AppleAccountRecord,
        secret: AccountSecret
    ) async throws {
        do {
            try Task.checkCancellation()
            let anisetteData = try await anisetteProvider.fetch()
            let session = ALTAppleAPISession(
                dsid: secret.dsid,
                authToken: secret.authToken,
                anisetteData: anisetteData,
                xcodeVersion: Self.xcodeVersion
            )
            let altAccount = ALTAccount()
            altAccount.appleID = secret.email
            altAccount.identifier = secret.accountIdentifier
            let teams = try await fetchTeams(account: altAccount, session: session)
            try Task.checkCancellation()
            guard teams.contains(where: { $0.identifier == account.teamID }) else {
                throw ImportFailure(
                    title: "Team 不可用",
                    reason: "当前 Apple ID 已无法访问之前保存的 Team（Apple 返回的团队列表中已找不到该 Team）。",
                    recovery: "选择 Team",
                    code: "SEAL-AUTH-112a"
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch ALTAppleAPIError.incorrectCredentials {
            throw ImportFailure(
                title: "Apple ID 需要重新验证",
                reason: "Apple 已明确拒绝当前登录凭据。",
                recovery: "重新验证 Apple ID",
                code: "SEAL-AUTH-102b"
            )
        } catch let failure as ImportFailure {
            throw failure
        } catch {
            if AppleServiceFailurePolicy.isNetworkError(error) {
                throw AppleServiceFailurePolicy.networkFailure(
                    title: "无法连接 Apple",
                    reason: "当前网络或 Apple 服务不可用。已保存的 Apple ID 仍可继续选择。"
                )
            }
            let nsError = error as NSError
            throw ImportFailure(
                title: "无法验证 Apple ID",
                reason: "Apple 验证返回了无法分类的错误，账号状态未改变。\n[\(nsError.domain) \(nsError.code)]",
                recovery: "稍后重试；如持续失败再重新验证 Apple ID",
                code: "SEAL-VERIFY-500a"
            )
        }
    }

    nonisolated static func mask(_ appleID: String) -> String {
        let trimmedAppleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAppleID.isEmpty == false else { return "***" }

        if trimmedAppleID.contains("@") {
            return maskEmail(trimmedAppleID)
        }

        if isPhoneNumber(trimmedAppleID) {
            return maskPhone(trimmedAppleID)
        }

        return maskPlainIdentifier(trimmedAppleID)
    }

    private nonisolated static func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return maskPlainIdentifier(email) }

        let localPart = parts[0]
        let domain = parts[1]
        guard localPart.isEmpty == false, domain.isEmpty == false else {
            return maskPlainIdentifier(email)
        }
        return "\(maskPlainIdentifier(localPart))@\(domain)"
    }

    private nonisolated static func maskPhone(_ value: String) -> String {
        let hasCountryPrefix = value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+")
        let digits = String(value.filter { $0.isNumber })
        guard digits.count >= 6 else { return maskPlainIdentifier(value) }

        if hasCountryPrefix,
           let countryCodeLength = countryCodeLength(in: digits),
           digits.count > countryCodeLength {
            let countryCode = String(digits.prefix(countryCodeLength))
            let nationalNumber = String(digits.dropFirst(countryCodeLength))
            return "+\(countryCode) \(maskPhoneNationalNumber(nationalNumber))"
        }

        return maskPhoneNationalNumber(digits)
    }

    private nonisolated static func maskPhoneNationalNumber(_ digits: String) -> String {
        let characters = Array(digits)
        switch characters.count {
        case 0:
            return "***"
        case 1...5:
            return maskPlainIdentifier(digits)
        case 6...7:
            let prefix = String(characters.prefix(2))
            let suffix = String(characters.suffix(2))
            return "\(prefix)****\(suffix)"
        case 8:
            let prefix = String(characters.prefix(3))
            let suffix = String(characters.suffix(3))
            return "\(prefix)****\(suffix)"
        default:
            let prefix = String(characters.prefix(3))
            let suffix = String(characters.suffix(4))
            return "\(prefix)****\(suffix)"
        }
    }

    private nonisolated static func maskPlainIdentifier(_ identifier: String) -> String {
        let characters = Array(identifier)
        switch characters.count {
        case 0:
            return "***"
        case 1...3:
            return "\(characters[0])***"
        case 4...5:
            let prefix = String(characters.prefix(2))
            let suffix = String(characters.suffix(1))
            return "\(prefix)***\(suffix)"
        default:
            let prefix = String(characters.prefix(3))
            let suffix = String(characters.suffix(2))
            return "\(prefix)***\(suffix)"
        }
    }

    private nonisolated static func isPhoneNumber(_ value: String) -> Bool {
        let digits = value.filter { $0.isNumber }
        guard digits.count >= 6 else { return false }

        let allowedCharacters = CharacterSet(charactersIn: "+0123456789 -()")
        return value.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private nonisolated static func countryCodeLength(in digits: String) -> Int? {
        let knownCountryCodes: Set<String> = [
            "1", "7",
            "20", "27", "30", "31", "32", "33", "34", "36", "39", "40", "41", "43", "44", "45", "46", "47", "48", "49",
            "52", "55", "60", "61", "62", "63", "64", "65", "66", "81", "82", "84", "86", "90", "91", "92", "93", "94", "95", "98",
            "212", "213", "216", "218", "234", "351", "352", "353", "354", "355", "356", "357", "358", "359",
            "370", "371", "372", "373", "374", "375", "376", "377", "380", "381", "382", "383", "385", "386", "387", "389",
            "420", "421", "852", "853", "855", "856", "886", "960", "961", "962", "963", "964", "965", "966", "967", "968",
            "971", "972", "973", "974", "975", "976", "977", "992", "993", "994", "995", "996", "998"
        ]

        for length in stride(from: min(3, digits.count - 1), through: 1, by: -1) {
            let candidate = String(digits.prefix(length))
            if knownCountryCodes.contains(candidate) {
                return length
            }
        }

        guard digits.count > 10 else { return nil }
        return min(3, max(1, digits.count - 10))
    }

    private func authenticate(
        email: String,
        password: String,
        anisetteData: ALTAnisetteData,
        verificationCode: @escaping @MainActor @Sendable () async -> String?
    ) async throws -> LegacyBox<AuthObjects> {
        try await Self.authenticateWithAPI(
            email: email,
            password: password,
            anisetteData: anisetteData,
            verificationCode: verificationCode
        )
    }

    private nonisolated static func authenticateWithAPI(
        email: String,
        password: String,
        anisetteData: ALTAnisetteData,
        verificationCode: @escaping @MainActor @Sendable () async -> String?
    ) async throws -> LegacyBox<AuthObjects> {
        try await withCheckedThrowingContinuation { continuation in
            let callback = LegacyCallbackBox(continuation)
            ALTAppleAPI.shared.authenticate(
                appleID: email,
                password: password,
                anisetteData: anisetteData,
                xcodeVersion: Self.xcodeVersion,
                verificationHandler: { response in
                    let reply = VerificationReply(response)
                    Task { @MainActor in
                        reply.send(await verificationCode())
                    }
                }
            ) { account, session, error in
                if let account, let session {
                    callback.resume(
                        returning: LegacyBox(
                            AuthObjects(account: account, session: session)
                        )
                    )
                } else {
                    callback.resume(
                        throwing: error ?? URLError(.userAuthenticationRequired)
                    )
                }
            }
        }
    }

    private func fetchTeams(
        account: ALTAccount,
        session: ALTAppleAPISession
    ) async throws -> [ALTTeam] {
        try await Self.fetchTeamsWithAPI(account: account, session: session)
    }

    private nonisolated static func fetchTeamsWithAPI(
        account: ALTAccount,
        session: ALTAppleAPISession
    ) async throws -> [ALTTeam] {
        let box: LegacyBox<[ALTTeam]> = try await withCheckedThrowingContinuation {
            continuation in
            let callback = LegacyCallbackBox(continuation)
            ALTAppleAPI.shared.fetchTeams(for: account, session: session) { teams, error in
                if let teams {
                    callback.resume(returning: LegacyBox(teams))
                } else {
                    callback.resume(
                        throwing: error ?? URLError(.badServerResponse)
                    )
                }
            }
        }
        return box.value
    }

    /// 纯函数：只做错误分类，不加锁不碰 UI 状态；
    /// 需要 nonisolated 以便从 withTimeout 的 @Sendable 闭包调用
    private nonisolated static func failure(from error: Error) -> ImportFailure {
        if let anisetteError = error as? AnisetteV3Error {
            let code: String
            let reason: String
            switch anisetteError {
            case .invalidIdentifier, .invalidServerResponse:
                code = "SEAL-ANI-110"
                reason = "Apple 拒绝了当前的设备标识（Anisette 无效或服务器响应异常）。"
            case .provisioningFailed:
                code = "SEAL-ANI-111"
                reason = "Anisette 设备信息（provisioning）生成失败。"
            case .staleProvisioning:
                code = "SEAL-ANI-112"
                reason = "Anisette 设备信息（provisioning）已过期，请重新生成。"
            case .unavailable:
                code = "SEAL-ANI-113"
                reason = "Anisette 服务当前不可用。"
            case .localGenerationFailed(let d):
                code = "SEAL-ANI-114"
                reason = "本机生成设备环境数据（Anisette）失败。\n\(d)"
            }
            return ImportFailure(
                title: "无法获取设备环境",
                reason: reason,
                recovery: "重试",
                code: code
            )
        }
        if AppleServiceFailurePolicy.isNetworkError(error) {
            return AppleServiceFailurePolicy.networkFailure(
                title: "无法连接 Apple",
                reason: "当前网络或 Apple 服务不可用。账号状态不会被修改。"
            )
        }
        let nsError = error as NSError
        let isVerificationFailure = nsError.localizedDescription
            .localizedCaseInsensitiveContains("verification")
        var detailParts: [String] = []
        detailParts.append("类型：\(String(describing: type(of: error)))")
        detailParts.append("Domain：\(nsError.domain)")
        detailParts.append("Code：\(nsError.code)")
        detailParts.append("描述：\(nsError.localizedDescription)")
        if let debugDesc = nsError.userInfo["NSDebugDescription"] as? String {
            detailParts.append("调试：\(debugDesc)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            detailParts.append("嵌套：\(underlying.domain)/\(underlying.code) \(underlying.localizedDescription)")
        }
        let detail = detailParts.joined(separator: "\n")
        let baseReason = isVerificationFailure ? "Apple 拒绝了当前验证码（验证码无效或已过期）" : "Apple ID 验证失败"
        return ImportFailure(
            title: "无法添加账号",
            reason: "\(baseReason)\n\(detail)",
            recovery: isVerificationFailure ? "获取最新验证码后重试" : "重试；如持续失败请核对 Apple ID 与密码",
            code: isVerificationFailure ? "SEAL-AUTH-101" : "SEAL-AUTH-107a"
        )
    }
}

private struct AuthObjects {
    let account: ALTAccount
    let session: ALTAppleAPISession
}

struct LegacyBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class VerificationReply: @unchecked Sendable {
    private let response: (String?) -> Void

    init(_ response: @escaping (String?) -> Void) {
        self.response = response
    }

    func send(_ code: String?) {
        response(code)
    }
}

private final class LegacyCallbackBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}
