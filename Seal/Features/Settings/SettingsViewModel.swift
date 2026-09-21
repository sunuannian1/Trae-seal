import Combine
import Foundation
@preconcurrency import AltSign

enum SettingsRoute: Hashable {
    case account
    case addAccount
    case certificates
    case accountDetail(UUID)
    case pairing
    case localDevVPN
    case storage
}

/// 自管理状态的展示模型：View 只读这里，不自己猜状态。
struct SelfManagementPresentation: Equatable, Sendable {
    let state: SelfManagementState
    let title: String
    let detail: String
    let allowsInstall: Bool
    let showsComputerRecovery: Bool

    init(_ state: SelfManagementState) {
        self.state = state
        let values: (String, String, Bool, Bool)
        switch state {
        case .externalBootstrap:
            values =
                ("电脑签名，等待本机接管", "先准备 Seal 本机可控的签名证书。", true, false)
        case .preparingLocalIdentity:
            values =
                ("正在准备本机签名身份", "请保持 Seal 在前台。", false, false)
        case .localIdentityReady:
            values =
                ("本机身份已就绪", "可以提交一次覆盖安装。", true, false)
        case .awaitingReplacementConfirmation:
            values =
                ("已提交安装，等待重新打开 Seal 确认", "请按 Home 回到主屏幕，让 iOS 用新版完成替换，再重新打开 Seal。本页会自动确认安装结果。", false, false)
        case .selfManaged:
            values =
                ("Seal 已由本机管理", "后续续签复用本机证书。", true, false)
        case .recoveryRequired:
            values =
                ("需要电脑覆盖恢复", "不要卸载 Seal。", false, true)
        }
        title = values.0
        detail = values.1
        allowsInstall = values.2
        showsComputerRecovery = values.3
    }
}

/// 证书行标签的固定含义。
enum CertificateRoleLabel: Equatable, Sendable {
    case currentSealSigner       // 当前 Seal 实际使用
    case locallyUsable           // 本机持有匹配私钥
    case external                // Apple 端存在但本机没有私钥
    case associatedOnThisDevice  // 只统计本机已安装 App
    case associationUnknown      // 无法确认

    var title: String {
        switch self {
        case .currentSealSigner: return "当前 Seal 实际使用"
        case .locallyUsable: return "本机持有私钥"
        case .external: return "仅 Apple 端存在"
        case .associatedOnThisDevice: return "本机已安装 App 在用"
        case .associationUnknown: return "关联状态无法确认"
        }
    }
}

/// 自管理状态解析：真实身份 + 未结算事务 + 签名者是否持有本机私钥。
/// 事务在进行中时优先展示事务状态；身份读不出来一律按需要恢复处理。
enum SelfManagementStateResolver {
    static func resolve(
        identity: InstalledIdentity?,
        pendingTransaction: SelfReplacementTransaction?,
        signerHasLocalPrivateKey: Bool
    ) -> SelfManagementState {
        guard let identity, identity.isComplete,
              let signer = identity.mainTarget?.signerSerialNumber,
              SigningCertificateSelectionPolicy.normalizedSerialNumber(signer).isEmpty == false
        else {
            return .recoveryRequired
        }
        if let pendingTransaction {
            switch pendingTransaction.phase {
            case .prepared:
                return .localIdentityReady
            case .submitting, .awaitingReplacementConfirmation, .installedOldIdentity, .settling:
                return .awaitingReplacementConfirmation
            case .recoveryRequired:
                return .recoveryRequired
            case .confirmed:
                // loadPending 不会返回已确认事务；防御分支按无事务处理。
                break
            }
        }
        return signerHasLocalPrivateKey ? .selfManaged : .externalBootstrap
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    struct PendingTeamSelection: Identifiable {
        let id = UUID()
        let authenticated: AuthenticatedAppleAccount

        var teams: [AppleTeamRecord] { authenticated.teams }
    }

    enum AccountPhase: Equatable {
        case idle
        case authenticating
    }

    enum DiagnosticState: Equatable {
        case idle
        case running
        case ready(deviceIdentifier: String)
        case failed(ImportFailure)
    }

    @Published private(set) var accounts: [AppleAccountRecord] = []
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var fullAccountEmails: [UUID: String] = [:]
    @Published private(set) var appIconData: [UUID: Data] = [:]
    @Published private(set) var pairingRecord: PairingRecord?
    @Published private(set) var accountPhase: AccountPhase = .idle
    @Published private(set) var diagnosticState: DiagnosticState = .idle
    @Published private(set) var installDiagnostics: InstallChannelDiagnostics = .empty
    @Published private(set) var logs: [SealLogEntry] = []
    @Published private(set) var signingHistory: [SigningHistoryRecord] = []
    @Published private(set) var signingHistoryIconData: [UUID: Data] = [:]
    @Published private(set) var certificateInventories: [UUID: ApplePortalInventory] = [:]
    @Published private(set) var certificateInventoryLoadingIDs: Set<UUID> = []
    @Published private(set) var certificateInventoryFailures: [UUID: ImportFailure] = [:]
    @Published private(set) var certificateHealthStatuses: [UUID: CertificateHealthStatus] = [:]
    @Published private(set) var isCertificateOperationRunning = false
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var reminderHours = 24
    @Published private(set) var notificationStatus = NotificationScheduleStatus.disabled
    @Published private(set) var storageUsage: SettingsStorageUsage = .empty
    @Published private(set) var logExportText = ""
    @Published var alertFailure: ImportFailure?
    @Published var requestedRoute: SettingsRoute?
    @Published private(set) var pendingTeamSelection: PendingTeamSelection?
    @Published private(set) var selfManagement: SelfManagementPresentation =
        .init(.externalBootstrap)
    /// 当前运行 Seal 的真实 CMS 签名者；读不出来时为 nil（证书行据此打标签）。
    @Published private(set) var sealActualSignerSerialNumber: String?

    let verificationBroker = VerificationCodeBroker()

    private let accountRepository: (any AccountRepository)?
    private let keychain: KeychainVault?
    private let accountClient: AppleAccountClient?
    private let pairingStore: PairingStore?
    private let installChannel: (any InstallChannel)?
    private let appStore: (any AppStore)?
    private let fileStore: AppFileStore?
    private let logStore: SealLogStore?
    private let signingHistoryStore: SigningHistoryStore?
    private let applePortalInventoryService: ApplePortalInventoryService?
    private let applePortalCertificateService: ApplePortalCertificateService?
    private let notificationScheduler: ExpiryNotificationScheduler?
    private let notificationPreferences: NotificationPreferences?
    private let anisetteEnvironment: (any AnisetteEnvironmentManaging)?
    private let signingPreferenceStore: SigningPreferenceStore?
    private let operationCoordinator: OperationCoordinator?
    private let selfReplacementStore: SelfReplacementTransactionStore?
    private var hasLoaded = false
    private var loadGeneration = 0
    private static let pairingAssistantInboxFileName = "SealPairing.mobiledevicepairing"
    private static let pairingAssistantSource = "Seal 配对助手"

    init(
        accountRepository: any AccountRepository,
        keychain: KeychainVault,
        accountClient: AppleAccountClient,
        pairingStore: PairingStore,
        installChannel: any InstallChannel,
        appStore: any AppStore,
        fileStore: AppFileStore,
        logStore: SealLogStore,
        signingHistoryStore: SigningHistoryStore,
        notificationScheduler: ExpiryNotificationScheduler,
        notificationPreferences: NotificationPreferences,
        anisetteEnvironment: any AnisetteEnvironmentManaging,
        signingPreferenceStore: SigningPreferenceStore,
        operationCoordinator: OperationCoordinator? = nil,
        selfReplacementStore: SelfReplacementTransactionStore? = nil
    ) {
        self.accountRepository = accountRepository
        self.keychain = keychain
        self.accountClient = accountClient
        self.pairingStore = pairingStore
        self.installChannel = installChannel
        self.appStore = appStore
        self.fileStore = fileStore
        self.logStore = logStore
        self.signingHistoryStore = signingHistoryStore
        self.applePortalInventoryService = ApplePortalInventoryService()
        self.applePortalCertificateService = ApplePortalCertificateService()
        self.notificationScheduler = notificationScheduler
        self.notificationPreferences = notificationPreferences
        self.anisetteEnvironment = anisetteEnvironment
        self.signingPreferenceStore = signingPreferenceStore
        self.operationCoordinator = operationCoordinator
        self.selfReplacementStore = selfReplacementStore
        notificationsEnabled = notificationPreferences.isEnabled
        reminderHours = notificationPreferences.leadHours
    }

    init(startupFailure: ImportFailure) {
        accountRepository = nil
        keychain = nil
        accountClient = nil
        pairingStore = nil
        installChannel = nil
        appStore = nil
        fileStore = nil
        logStore = nil
        signingHistoryStore = nil
        applePortalInventoryService = nil
        applePortalCertificateService = nil
        notificationScheduler = nil
        notificationPreferences = nil
        anisetteEnvironment = nil
        signingPreferenceStore = nil
        operationCoordinator = nil
        selfReplacementStore = nil
        alertFailure = startupFailure
    }

    private init() {
        accountRepository = nil
        keychain = nil
        accountClient = nil
        pairingStore = nil
        installChannel = nil
        appStore = nil
        fileStore = nil
        logStore = nil
        signingHistoryStore = nil
        applePortalInventoryService = nil
        applePortalCertificateService = nil
        notificationScheduler = nil
        notificationPreferences = nil
        anisetteEnvironment = nil
        signingPreferenceStore = nil
        operationCoordinator = nil
        selfReplacementStore = nil
        hasLoaded = true
    }

    var environment: EnvironmentSnapshot {
        EnvironmentSnapshot(
            accountCount: accounts.count,
            verifiedAccountCount: accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }.count,
            hasPairingFile: pairingRecord != nil,
            channelIsReady: {
                guard case .ready = diagnosticState else { return false }
                return true
            }()
        )
    }

    func load(force: Bool = false) async {
        guard force || hasLoaded == false else { return }
        guard let accountRepository, let pairingStore else { return }
        loadGeneration &+= 1
        let generation = loadGeneration

        do {
            let fetchedAccounts = try await accountRepository.fetchAll()
            guard generation == loadGeneration else { return }
            let repairedAccounts = try await repairLegacyAccountStatuses(fetchedAccounts)
            guard generation == loadGeneration else { return }
            let displayedAccounts = try await refreshedAccountDisplayNames(repairedAccounts)
            guard generation == loadGeneration else { return }

            let loadedPairing: PairingRecord?
            do {
                loadedPairing = try await pairingStore.current()
            } catch {
                loadedPairing = PairingRecord(
                    deviceIdentifier: nil,
                    isRemotePairing: false,
                    validationStatus: .fileUnreadable
                )
            }
            guard generation == loadGeneration else { return }

            let preferredAccountID: UUID?
            if let signingPreferenceStore {
                preferredAccountID = await signingPreferenceStore.activeAccountID()
            } else {
                preferredAccountID = nil
            }
            guard generation == loadGeneration else { return }

            let selectableAccounts = displayedAccounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
            let resolvedAccountID: UUID?
            if let preferredAccountID, displayedAccounts.contains(where: { $0.id == preferredAccountID }) {
                resolvedAccountID = preferredAccountID
            } else if let current = activeAccountID, displayedAccounts.contains(where: { $0.id == current }) {
                resolvedAccountID = current
            } else {
                resolvedAccountID = selectableAccounts.first?.id
                if preferredAccountID == nil {
                    await signingPreferenceStore?.setActiveAccountID(resolvedAccountID)
                }
            }

            // 快速显示核心数据
            accounts = displayedAccounts
            pairingRecord = loadedPairing
            activeAccountID = resolvedAccountID
            hasLoaded = true

            // 后台加载非关键数据
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }

                _ = await self.importPairingAssistantInboxIfPresent()

                let emails = await self.loadFullAccountEmails(for: displayedAccounts)
                await MainActor.run { self.fullAccountEmails = emails }

                let storedApps = (try? await self.appStore?.fetchAll()) ?? []
                let appIcons = await self.loadAppIcons(for: storedApps)
                await MainActor.run { self.appIconData = appIcons }

                await MainActor.run {
                    self.loadCertificateInventoryCache(for: displayedAccounts)
                }

                let loadedLogs = (try? await self.logStore?.entries()) ?? []
                let loadedHistory = (try? await self.signingHistoryStore?.records()) ?? []
                let historyIcons = await self.loadSigningHistoryIcons(for: loadedHistory)
                await MainActor.run {
                    self.logs = loadedLogs
                    self.signingHistory = loadedHistory
                    self.signingHistoryIconData = historyIcons
                }

                var loadedNotificationsEnabled = await MainActor.run { self.notificationsEnabled }
                var loadedReminderHours = await MainActor.run { self.reminderHours }
                var loadedNotificationStatus = await MainActor.run { self.notificationStatus }
                let prefsEnabled = await MainActor.run { self.notificationPreferences?.isEnabled }
                let prefsLeadHours = await MainActor.run { self.notificationPreferences?.leadHours }
                if let prefsEnabled, let prefsLeadHours {
                    loadedNotificationsEnabled = prefsEnabled
                    loadedReminderHours = prefsLeadHours
                    if let notificationScheduler = self.notificationScheduler {
                        loadedNotificationStatus = await notificationScheduler.status(sealEnabled: loadedNotificationsEnabled)
                    }
                }
                await MainActor.run {
                    self.notificationsEnabled = loadedNotificationsEnabled
                    self.reminderHours = loadedReminderHours
                    self.notificationStatus = loadedNotificationStatus
                }

                let loadedStorageUsage: SettingsStorageUsage
                if let fileStore = self.fileStore {
                    loadedStorageUsage = (try? await fileStore.storageUsage()) ?? .empty
                } else {
                    loadedStorageUsage = .empty
                }
                await MainActor.run {
                    self.storageUsage = loadedStorageUsage
                    self.refreshLogExportText()
                }
            }
        } catch {
            guard generation == loadGeneration else { return }
            alertFailure = Self.failure(
                title: "无法读取设置",
                reason: "本地配置不可用，设置项无法加载。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-SET-001"
            )
        }
    }

    func performLightweightLaunchCheck() async {
        await load(force: true)
        guard pairingRecord != nil, diagnosticState != .running else { return }
        await runInstallChannelCheck(successMessage: "LocalDevVPN 正常")
    }

    var activeAccount: AppleAccountRecord? {
        guard let activeAccountID else { return nil }
        return accounts.first { $0.id == activeAccountID }
    }

    func fullEmail(for account: AppleAccountRecord) -> String {
        fullAccountEmails[account.id] ?? account.maskedEmail
    }

    func selectActiveAccount(_ account: AppleAccountRecord) async {
        guard AccountAvailabilityPolicy.isSelectable(account),
              accounts.contains(where: { $0.id == account.id }) else { return }
        activeAccountID = account.id
        await signingPreferenceStore?.setActiveAccountID(account.id)
    }

    func selectCertificate(
        serialNumber: String,
        for account: AppleAccountRecord
    ) async {
        guard let accountRepository, let keychain else { return }
        let secret: AccountSecret?
        do {
            secret = try await keychain.load(accountID: account.id)
        } catch {
            alertFailure = Self.failure(
                title: "证书不可用",
                reason: "Seal 无法读取本地证书私钥。",
                recovery: "重新验证 Apple ID",
                code: "SEAL-CERT-206"
            )
            return
        }
        guard let inventory = certificateInventories[account.id],
              inventory.certificates.contains(where: {
                  $0.serialNumber == serialNumber && $0.hasLocalPrivateKey
              }),
              let secret,
              // 私钥判定与签名链路一致：按 serial 查 keychain 里保存的全部 P12（含历史 map），
              // 不要求它正是当前绑定的那张——选中即完成切换。
              secret.p12(for: serialNumber) != nil else {
            alertFailure = Self.failure(
                title: "证书不可用",
                reason: "Seal 本地没有此证书对应的私钥，未更改当前签名证书。",
                recovery: "选择其他证书；或重新验证 Apple ID 以获取对应私钥",
                code: "SEAL-CERT-206a"
            )
            return
        }

        var updated = account
        updated.selectedCertificateSerialNumber = serialNumber
        do {
            try await accountRepository.save(updated)
            await load(force: true)
            try? await logStore?.append(
                category: .account,
                message: "已选择签名证书，完整 Serial：\(serialNumber)"
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
        } catch {
            alertFailure = Self.failure(
                title: "无法选择证书",
                reason: "证书选择未能保存。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试；如持续失败请重新验证 Apple ID",
                code: "SEAL-CERT-102"
            )
        }
    }

    func createLocalCertificate(for account: AppleAccountRecord) async {
        guard isCertificateOperationRunning == false,
              let keychain,
              let accountRepository,
              let applePortalCertificateService else { return }
        guard let operationLease = await acquireOperation(.managingCertificate) else { return }
        defer { releaseOperation(operationLease) }

        isCertificateOperationRunning = true
        defer { isCertificateOperationRunning = false }

        do {
            guard let originalSecret = try await keychain.load(accountID: account.id) else {
                await persistVerificationFailure(.localCredentialsMissing, for: account)
                throw Self.failure(
                    title: "无法创建证书",
                    reason: "本机没有当前 Apple ID 的登录凭据。",
                    recovery: "重新验证 Apple ID",
                    code: "SEAL-AUTH-105b"
                )
            }

            let material = try await applePortalCertificateService.createLocalCertificate(
                account: account,
                secret: originalSecret
            )
            try await persistCreatedCertificate(
                material,
                originalSecret: originalSecret,
                originalAccount: account,
                keychain: keychain,
                accountRepository: accountRepository,
                certificateService: applePortalCertificateService
            )
            await load(force: true)
            await refreshCertificateInventory(for: account, force: true)
            try? await logStore?.append(
                category: .account,
                message: "已创建并保存本机签名证书。完整 Serial：\(material.serialNumber)"
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
        } catch let failure as ImportFailure {
            alertFailure = failure
        } catch {
            alertFailure = Self.failure(
                title: "创建签名证书失败",
                reason: "Apple 未返回签名证书，可能网络不稳定或 Apple 服务异常。",
                recovery: "检查网络后重试",
                code: "SEAL-CERT-211"
            )
        }
    }

    func revokeCertificate(
        serialNumber: String,
        for account: AppleAccountRecord
    ) async {
        guard isCertificateOperationRunning == false,
              let keychain,
              let accountRepository,
              let applePortalCertificateService else { return }
        guard let operationLease = await acquireOperation(.managingCertificate) else { return }
        defer { releaseOperation(operationLease) }

        isCertificateOperationRunning = true
        defer { isCertificateOperationRunning = false }

        do {
            guard let originalSecret = try await keychain.load(accountID: account.id) else {
                await persistVerificationFailure(.localCredentialsMissing, for: account)
                throw Self.failure(
                    title: "无法撤销证书",
                    reason: "本机没有当前 Apple ID 的登录凭据。",
                    recovery: "重新验证 Apple ID",
                    code: "SEAL-AUTH-105c"
                )
            }

            // 真实签名者 A 永远不可撤销：撤了当前运行的 Seal 立刻「不再可用」。
            // 身份读不出来时无法证明目标不是 A，一律拒绝（只相信真实 CMS 签名者）。
            let runningIdentity = SelfAppMetadata.current()?.installedIdentity
            guard runningIdentity?.isComplete == true,
                  let sealActualSigner = runningIdentity?.mainTarget?.signerSerialNumber else {
                throw Self.failure(
                    title: "无法撤销证书",
                    reason: "无法确认当前 Seal 的真实签名证书，为保护 Seal 已停止撤销。",
                    recovery: "重启 Seal 后重试",
                    code: "SEAL-CERT-230"
                )
            }
            if CertificateRevocationImpact.isActualSealSigner(
                serialNumber: serialNumber,
                actualSealSignerSerialNumber: sealActualSigner
            ) {
                throw Self.failure(
                    title: "不能撤销这张证书",
                    reason: "这张证书正在给当前运行的 Seal 签名，撤销后 Seal 会立即无法打开。",
                    recovery: "如需更换签名身份，请用电脑按相同 Bundle ID 重新签名安装 Seal",
                    code: "SEAL-CERT-230a"
                )
            }

            try await applePortalCertificateService.revokeCertificate(
                serialNumber: serialNumber,
                account: account,
                secret: originalSecret
            )

            // 真实永久删除：撤销成功后，本机 keychain 中该序列号的 P12 材料一并移除
            // （含非本机在用的孤儿证书）；账号记录若正绑定该证书，则清空其序列号。
            var clearedSecret = originalSecret
            clearedSecret.removeStoredCertificateMaterial(serialNumber: serialNumber)
            try await keychain.save(clearedSecret, for: account.id)

            var clearedAccount = account
            if CertificateRevocationImpact.isLocalCertificate(serialNumber: serialNumber, account: account) {
                clearedAccount.certificateSerialNumber = nil
                clearedAccount.selectedCertificateSerialNumber = nil
            }
            try await accountRepository.save(clearedAccount)

            // 立即从内存清单移除已撤销证书，UI 同步无需等网络回读。
            removeRevokedCertificateFromInventory(serialNumber: serialNumber, accountID: account.id)
            certificateHealthStatuses[account.id] = await localCertificateHealthStatus(
                account: clearedAccount,
                portalState: .unknown
            )

            try? await logStore?.append(
                category: .account,
                message: "用户已明确撤销证书。完整 Serial：\(serialNumber)"
            )
            await load(force: true)
            if let refreshedAccount = accounts.first(where: { $0.id == account.id }) {
                await refreshCertificateInventory(for: refreshedAccount, force: true)
            }
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
        } catch let failure as ImportFailure {
            await load(force: true)
            await refreshCertificateInventory(for: account, force: true)
            alertFailure = failure
        } catch {
            await load(force: true)
            await refreshCertificateInventory(for: account, force: true)
            alertFailure = Self.failure(
                title: "证书撤销失败",
                reason: "Apple 服务器未能撤销指定证书。可能原因：网络不稳定、或该证书已被撤销。",
                recovery: "检查网络后重试；如持续失败请在「我的」中重新同步证书状态",
                code: "SEAL-CERT-216"
            )
        }
    }

    /// 用户确认撤销候选 C 后的接管流程：重拉远端清单、重读真实签名者 A，再撤 C；
    /// 撤完重新拉清单确认出现空位，才创建本机身份 B。B 创建失败不清除 A 的任何记录。
    func revokeCertificateAndCreateLocal(
        serialNumber: String,
        for account: AppleAccountRecord
    ) async {
        guard isCertificateOperationRunning == false,
              let keychain,
              let accountRepository,
              let applePortalCertificateService,
              let applePortalInventoryService else { return }
        guard let operationLease = await acquireOperation(.managingCertificate) else { return }
        defer { releaseOperation(operationLease) }

        isCertificateOperationRunning = true
        defer { isCertificateOperationRunning = false }

        do {
            guard let originalSecret = try await keychain.load(accountID: account.id) else {
                await persistVerificationFailure(.localCredentialsMissing, for: account)
                throw Self.failure(
                    title: "无法更换证书",
                    reason: "本机没有当前 Apple ID 的登录凭据。",
                    recovery: "重新验证 Apple ID",
                    code: "SEAL-AUTH-105d"
                )
            }

            // 用户确认后、撤销前：重新拉远端清单 + 重新读取真实签名者 A。
            // 确认与执行之间状态可能已变化，撤销不可逆，绝不复用旧快照。
            let runningIdentity = SelfAppMetadata.current()?.installedIdentity
            guard runningIdentity?.isComplete == true,
                  let sealActualSigner = runningIdentity?.mainTarget?.signerSerialNumber else {
                throw Self.failure(
                    title: "无法更换证书",
                    reason: "无法确认当前 Seal 的真实签名证书，为保护 Seal 已停止撤销。",
                    recovery: "重启 Seal 后重试",
                    code: "SEAL-CERT-230"
                )
            }
            if CertificateRevocationImpact.isActualSealSigner(
                serialNumber: serialNumber,
                actualSealSignerSerialNumber: sealActualSigner
            ) {
                throw Self.failure(
                    title: "不能撤销这张证书",
                    reason: "这张证书正在给当前运行的 Seal 签名，撤销后 Seal 会立即无法打开。",
                    recovery: "如需更换签名身份，请用电脑按相同 Bundle ID 重新签名安装 Seal",
                    code: "SEAL-CERT-230a"
                )
            }
            let preRevokeInventory = try await applePortalInventoryService.fetchInventory(
                account: account,
                secret: originalSecret,
                scope: .certificates
            )
            guard preRevokeInventory.certificates.contains(where: {
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber)
                    == SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
            }) else {
                throw Self.failure(
                    title: "证书状态已变化",
                    reason: "这张证书已不在 Apple 的生效列表里（可能刚被撤销）。未创建新证书。",
                    recovery: "重新同步证书后确认当前状态",
                    code: "SEAL-CERT-219"
                )
            }

            try await applePortalCertificateService.revokeCertificate(
                serialNumber: serialNumber,
                account: account,
                secret: originalSecret
            )

            // 撤销成功后重新拉清单确认出现空位，才创建 B；确认不了空位就不创建，
            // 避免在仍旧满员的账号上再撞一次确定性 3022/7460。
            let postRevokeInventory = try await applePortalInventoryService.fetchInventory(
                account: account,
                secret: originalSecret,
                scope: .certificates
            )
            let targetStillActive = postRevokeInventory.certificates.contains(where: {
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber)
                    == SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
            })
            guard targetStillActive == false else {
                throw Self.failure(
                    title: "未能确认证书槽位已释放",
                    reason: "撤销请求已提交，但 Apple 生效列表里仍能看到这张证书。未创建新证书。",
                    recovery: "稍后重新同步证书再试",
                    code: "SEAL-CERT-231"
                )
            }

            var clearedSecret = originalSecret
            var clearedAccount = account
            if originalSecret.certificateSerialNumber?.caseInsensitiveCompare(serialNumber) == .orderedSame {
                clearedSecret.certificateP12 = nil
                clearedSecret.certificateSerialNumber = nil
                clearedSecret.certificateMachineIdentifier = nil
                clearedAccount.certificateSerialNumber = nil
                clearedAccount.selectedCertificateSerialNumber = nil
                try await keychain.save(clearedSecret, for: account.id)
                try await accountRepository.save(clearedAccount)
            }

            let material = try await applePortalCertificateService.createLocalCertificate(
                account: clearedAccount,
                secret: clearedSecret
            )
            try await persistCreatedCertificate(
                material,
                originalSecret: clearedSecret,
                originalAccount: clearedAccount,
                keychain: keychain,
                accountRepository: accountRepository,
                certificateService: applePortalCertificateService
            )
            await load(force: true)
            if let refreshedAccount = accounts.first(where: { $0.id == account.id }) {
                await refreshCertificateInventory(for: refreshedAccount, force: true)
            }
            try? await logStore?.append(
                category: .account,
                message: "用户已更新证书 Serial：\(serialNumber) -> \(material.serialNumber)"
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
        } catch let failure as ImportFailure {
            await load(force: true)
            await refreshCertificateInventory(for: account, force: true)
            alertFailure = failure
        } catch {
            await load(force: true)
            await refreshCertificateInventory(for: account, force: true)
            alertFailure = Self.failure(
                title: "无法完成证书处理",
                reason: "已按用户选择处理证书，但 Apple 或本地保存阶段没有返回明确失败原因。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重新同步证书后确认当前状态",
                code: "SEAL-CERT-212"
            )
        }
    }

    /// 清理不可用证书 · 第一步：分析并给出计划（只读，不撤销任何证书）。
    /// 返回 nil 表示分析失败（已弹错误）。plan.revocable 为空时由 UI 提示「无需清理」。
    func prepareCertificateCleanup(
        for account: AppleAccountRecord,
        apps: [AppRecord]
    ) async -> CertificateCleanupPlan? {
        guard isCertificateOperationRunning == false,
              let keychain,
              let applePortalInventoryService else { return nil }
        guard let operationLease = await acquireOperation(.managingCertificate) else { return nil }
        defer { releaseOperation(operationLease) }

        isCertificateOperationRunning = true
        defer { isCertificateOperationRunning = false }

        do {
            guard let secret = try await keychain.load(accountID: account.id) else {
                throw Self.failure(
                    title: "无法分析证书",
                    reason: "本机没有当前 Apple ID 的登录凭据。",
                    recovery: "重新验证 Apple ID",
                    code: "SEAL-AUTH-105g"
                )
            }
            // 撤销决策必须基于当下远端清单，不能用缓存。
            let inventory = try await applePortalInventoryService.fetchInventory(
                account: account,
                secret: secret,
                scope: .certificates
            )

            // 「本机有可用私钥」必须查 keychain 里按 serial 保存的全部 P12（含历史 map），
            // 与签名链路 secret.p12(for:) 的无感复用口径一致；只看当前绑定会把仍可复用的
            // 历史证书误判成可撤销。
            var localUsableSerials = Set<String>()
            for certificate in inventory.certificates {
                guard let data = secret.p12(for: certificate.serialNumber),
                      let local = try? ALTCertificate(p12Data: data, password: nil) else { continue }
                let localSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(local.serialNumber)
                let remoteSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
                if localSerial == remoteSerial {
                    localUsableSerials.insert(remoteSerial)
                }
            }

            let deviceReferenced = await DeviceProfileInspector.referencedCertificateSerials()
            // Seal 自保护：真实签名证书永远不撤，避免手动清理把 Seal 自己变砖。
            // 只相信真实 CMS 签名者（installedIdentity），不信描述文件授权列表、不信 DB 记录。
            // 身份读不出来时无法证明任何一张证书不是 Seal 的命，计划整体阻断。
            let runningIdentity = SelfAppMetadata.current()?.installedIdentity
            guard runningIdentity?.isComplete == true,
                  let sealActualSigner = runningIdentity?.mainTarget?.signerSerialNumber else {
                return CertificateCleanupPlan.blocked(reason: "无法确认当前 Seal 的真实签名证书")
            }
            let plan = CertificateCleanupPolicy.makePlan(
                certificates: inventory.certificates,
                apps: apps,
                localUsableSerials: localUsableSerials,
                deviceReferencedSerials: deviceReferenced,
                sealActualSignerSerialNumber: sealActualSigner,
                identityConfidence: .complete
            )
            try? await logStore?.append(
                category: .account,
                message: "证书清理分析：远端 \(inventory.certificates.count) 张，可撤销 \(plan.revocable.count) 张，保留 \(plan.kept.count) 张，设备核验\(plan.deviceVerified ? "已完成" : "不可用")"
            )
            return plan
        } catch let failure as ImportFailure {
            alertFailure = failure
            return nil
        } catch {
            alertFailure = Self.failure(
                title: "无法分析证书",
                reason: "从 Apple 获取证书清单失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "检查网络后重试；如持续失败请在「我的」中重新验证 Apple ID",
                code: "SEAL-CERT-217"
            )
            return nil
        }
    }

    /// 清理不可用证书 · 第二步：执行已确认的计划 —— 先批量撤销，全部撤完再新建一张并绑定。
    /// 执行前会重拉远端清单求交集：确认后的这段时间内状态可能变化，撤销不可逆，
    /// 不复用更早的快照（与 C 包「删除前复核」同一条纪律）。
    func executeCertificateCleanup(
        _ plan: CertificateCleanupPlan,
        for account: AppleAccountRecord,
        apps: [AppRecord]
    ) async {
        guard plan.revocable.isEmpty == false,
              isCertificateOperationRunning == false,
              let keychain,
              let accountRepository,
              let applePortalCertificateService,
              let applePortalInventoryService else { return }
        guard let operationLease = await acquireOperation(.managingCertificate) else { return }
        defer { releaseOperation(operationLease) }

        isCertificateOperationRunning = true
        defer { isCertificateOperationRunning = false }

        do {
            guard let secret = try await keychain.load(accountID: account.id) else {
                throw Self.failure(
                    title: "无法清理证书",
                    reason: "本机没有当前 Apple ID 的登录凭据。",
                    recovery: "重新验证 Apple ID",
                    code: "SEAL-AUTH-105h"
                )
            }

            // 复核：只对「仍在最新计划的可撤销集合里」的证书执行撤销。
            let freshInventory = try await applePortalInventoryService.fetchInventory(
                account: account,
                secret: secret,
                scope: .certificates
            )
            var localUsableSerials = Set<String>()
            for certificate in freshInventory.certificates {
                guard let data = secret.p12(for: certificate.serialNumber),
                      let local = try? ALTCertificate(p12Data: data, password: nil) else { continue }
                let localSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(local.serialNumber)
                let remoteSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
                if localSerial == remoteSerial {
                    localUsableSerials.insert(remoteSerial)
                }
            }
            // 执行时重新核验设备引用，不能用空集合冒充之前核验过的真实清单。
            // 执行撤销前必须重新读取一次真实身份：signer 读不出来，或 signer 与生成计划时
            // 相比发生了变化（这段时间内 Seal 被换签），整批撤销停止。
            let runningIdentity = SelfAppMetadata.current()?.installedIdentity
            guard runningIdentity?.isComplete == true,
                  let sealActualSigner = runningIdentity?.mainTarget?.signerSerialNumber else {
                throw Self.failure(
                    title: "无法撤销证书",
                    reason: "无法确认当前 Seal 的真实签名证书，为保护 Seal 已停止撤销，未撤销任何证书。",
                    recovery: "重启 Seal 后重新分析再试",
                    code: "SEAL-CERT-219b"
                )
            }
            if let planSigner = plan.sealActualSignerSerialNumber,
               SigningCertificateSelectionPolicy.normalizedSerialNumber(planSigner)
                != SigningCertificateSelectionPolicy.normalizedSerialNumber(sealActualSigner) {
                throw Self.failure(
                    title: "证书状态已变化",
                    reason: "Seal 的签名证书在确认后发生了变化，先前的清理计划已作废。未撤销任何证书。",
                    recovery: "重新分析后再试",
                    code: "SEAL-CERT-219"
                )
            }
            let freshDeviceReferenced = await DeviceProfileInspector.referencedCertificateSerials()
            let freshPlan = CertificateCleanupPolicy.makePlan(
                certificates: freshInventory.certificates,
                apps: apps,
                localUsableSerials: localUsableSerials,
                deviceReferencedSerials: freshDeviceReferenced,
                sealActualSignerSerialNumber: sealActualSigner,
                identityConfidence: .complete
            )
            let confirmedSerials = Set(plan.revocable.map {
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber)
            })
            let targets = freshPlan.revocable.filter {
                confirmedSerials.contains(
                    SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber)
                )
            }
            guard targets.isEmpty == false else {
                throw Self.failure(
                    title: "证书状态已变化",
                    reason: "重新核验后，先前选中的证书已不再满足可撤销条件（可能刚被 App 使用或已在本机恢复私钥）。未撤销任何证书。",
                    recovery: "重新分析后再试",
                    code: "SEAL-CERT-219"
                )
            }

            var revokedSerials: [String] = []
            var failedSerials: [String] = []
            for certificate in targets {
                do {
                    try await applePortalCertificateService.revokeCertificate(
                        serialNumber: certificate.serialNumber,
                        account: account,
                        secret: secret
                    )
                    revokedSerials.append(certificate.serialNumber)
                } catch {
                    // 单张失败不中断：其余候选继续撤，名额尽量释放；失败明细进最终结果。
                    failedSerials.append(certificate.serialNumber)
                    try? await logStore?.append(
                        category: .account,
                        level: .error,
                        message: "清理撤销失败：序列号 …\(SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber).suffix(12))：\(error.localizedDescription)"
                    )
                }
            }

            // 被撤销的可能正是账号当前绑定的证书（无钥匙的旧绑定）：清掉失效绑定，
            // 让新建后的 persistCreatedCertificate 落到干净状态。
            var workingSecret = secret
            var workingAccount = account
            if let current = secret.certificateSerialNumber,
               revokedSerials.contains(where: {
                   SigningCertificateSelectionPolicy.normalizedSerialNumber($0)
                       == SigningCertificateSelectionPolicy.normalizedSerialNumber(current)
               }) {
                workingSecret.certificateP12 = nil
                workingSecret.certificateSerialNumber = nil
                workingSecret.certificateMachineIdentifier = nil
                workingAccount.certificateSerialNumber = nil
                workingAccount.selectedCertificateSerialNumber = nil
                try await keychain.save(workingSecret, for: account.id)
                try await accountRepository.save(workingAccount)
            }

            do {
                let material = try await applePortalCertificateService.createLocalCertificate(
                    account: workingAccount,
                    secret: workingSecret
                )
                try await persistCreatedCertificate(
                    material,
                    originalSecret: workingSecret,
                    originalAccount: workingAccount,
                    keychain: keychain,
                    accountRepository: accountRepository,
                    certificateService: applePortalCertificateService
                )
            } catch {
                throw Self.failure(
                    title: "已撤销旧证书，但新证书创建失败",
                    reason: "已撤销 \(revokedSerials.count) 张不可用证书，但新建证书失败：\(error.localizedDescription)",
                    recovery: "检查网络后重试签名，或在证书页手动创建",
                    code: "SEAL-CERT-218"
                )
            }

            try? await logStore?.append(
                category: .account,
                message: "证书清理完成：撤销 \(revokedSerials.count) 张（失败 \(failedSerials.count)），已新建并绑定新证书"
            )
            await load(force: true)
            if let refreshedAccount = accounts.first(where: { $0.id == account.id }) {
                await refreshCertificateInventory(for: refreshedAccount, force: true)
            }
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()

            if failedSerials.isEmpty == false {
                alertFailure = Self.failure(
                    title: "清理部分完成",
                    reason: "新证书已创建并绑定；但有 \(failedSerials.count) 张旧证书撤销失败（序列号末尾 \(failedSerials.map { "…" + SigningCertificateSelectionPolicy.normalizedSerialNumber($0).suffix(6) }.joined(separator: "、"))），仍占用 Apple 侧名额。",
                    recovery: "稍后在证书列表中逐张重试撤销",
                    code: "SEAL-CERT-218a"
                )
            }
        } catch let failure as ImportFailure {
            await load(force: true)
            await refreshCertificateInventory(for: account, force: true)
            alertFailure = failure
        } catch {
            await load(force: true)
            await refreshCertificateInventory(for: account, force: true)
            alertFailure = Self.failure(
                title: "证书清理失败",
                reason: "清理过程未能完成。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "检查网络后重试；如持续失败请重新验证 Apple ID",
                code: "SEAL-CERT-218b"
            )
        }
    }

    private func persistCreatedCertificate(
        _ material: CreatedCertificateMaterial,
        originalSecret: AccountSecret,
        originalAccount: AppleAccountRecord,
        keychain: KeychainVault,
        accountRepository: any AccountRepository,
        certificateService: ApplePortalCertificateService
    ) async throws {
        do {
            try await keychain.save(material.updatedSecret, for: originalAccount.id)
            guard let reloaded = try await keychain.load(accountID: originalAccount.id),
                  reloaded.certificateSerialNumber?.caseInsensitiveCompare(material.serialNumber) == .orderedSame,
                  let p12 = reloaded.certificateP12,
                  let parsed = try? ALTCertificate(p12Data: p12, password: nil),
                  parsed.serialNumber.caseInsensitiveCompare(material.serialNumber) == .orderedSame else {
                throw Self.failure(
                    title: "本机证书校验失败",
                    reason: "证书已由 Apple 创建，但从 Keychain 重新读取后，P12 或完整 Serial 校验不一致。",
                    recovery: "重新同步证书",
                    code: "SEAL-CERT-208"
                )
            }

            var updatedAccount = originalAccount
            updatedAccount.certificateSerialNumber = material.serialNumber
            updatedAccount.selectedCertificateSerialNumber = material.serialNumber
            updatedAccount.status = .verified
            updatedAccount.verificationFailureReason = nil
            updatedAccount.lastVerifiedAt = Date()
            try await accountRepository.save(updatedAccount)
        } catch {
            let originalError = error
            var rollbackFailures: [String] = []
            do {
                try await certificateService.revokeCertificate(
                    serialNumber: material.serialNumber,
                    account: originalAccount,
                    secret: material.updatedSecret
                )
            } catch {
                rollbackFailures.append("Apple 远程证书")
            }
            do {
                try await keychain.save(originalSecret, for: originalAccount.id)
            } catch {
                rollbackFailures.append("Keychain")
            }
            do {
                try await accountRepository.save(originalAccount)
            } catch {
                rollbackFailures.append("账号记录")
            }
            if rollbackFailures.isEmpty == false {
                throw Self.failure(
                    title: "证书补偿未完成",
                    reason: "证书创建后的补偿未完整完成（\(rollbackFailures.joined(separator: "、"))）。",
                    recovery: "重新同步证书并检查 Apple ID 状态",
                    code: "SEAL-CERT-215a"
                )
            }
            if let failure = originalError as? ImportFailure { throw failure }
            throw Self.failure(
                title: "签名证书保存失败",
                reason: "签名证书已由 Apple 创建，但保存到本机失败；已自动回滚远程证书。",
                recovery: "重试",
                code: "SEAL-CERT-208a"
            )
        }
    }

    private func refreshedAccountDisplayNames(
        _ storedAccounts: [AppleAccountRecord]
    ) async throws -> [AppleAccountRecord] {
        guard let keychain, let accountRepository else { return storedAccounts }
        var refreshedAccounts: [AppleAccountRecord] = []

        for var account in storedAccounts {
            var changed = false
            do {
                if let secret = try await keychain.load(accountID: account.id) {
                    let readableMaskedEmail = AppleAccountClient.mask(secret.email)
                    if account.maskedEmail != readableMaskedEmail {
                        account.maskedEmail = readableMaskedEmail
                        changed = true
                    }

                    if let serial = secret.certificateSerialNumber,
                       secret.certificateP12 != nil {
                        if account.certificateSerialNumber != serial {
                            account.certificateSerialNumber = serial
                            changed = true
                        }
                        // 账号可能按 serial 存有多张证书的 P12（certificateP12BySerial）：
                        // 用户选中的证书只要本机确有私钥就保留其选择；
                        // 选中证书已无私钥（如 P12 被清理）时才回退到当前绑定。
                        let selectedSerial = account.selectedCertificateSerialNumber
                        let selectionHasKey = selectedSerial.map { secret.p12(for: $0) != nil } ?? false
                        if selectionHasKey == false, account.selectedCertificateSerialNumber != serial {
                            account.selectedCertificateSerialNumber = serial
                            changed = true
                        }
                    } else {
                        if account.certificateSerialNumber != nil {
                            account.certificateSerialNumber = nil
                            changed = true
                        }
                        if account.selectedCertificateSerialNumber != nil {
                            account.selectedCertificateSerialNumber = nil
                            changed = true
                        }
                    }
                }
            } catch {
                changed = false
            }

            if changed {
                try await accountRepository.save(account)
            }
            refreshedAccounts.append(account)
        }

        return refreshedAccounts
    }

    private func loadFullAccountEmails(
        for accounts: [AppleAccountRecord]
    ) async -> [UUID: String] {
        guard let keychain else { return [:] }
        var values: [UUID: String] = [:]
        for account in accounts {
            do {
                if let secret = try await keychain.load(accountID: account.id) {
                    values[account.id] = secret.email
                }
            } catch {
                continue
            }
        }
        return values
    }

    private func loadAppIcons(for apps: [AppRecord]) async -> [UUID: Data] {
        guard let fileStore else { return [:] }
        var values: [UUID: Data] = [:]
        for app in apps {
            guard let path = app.displayIconRelativePath,
                  let data = try? await fileStore.read(relativePath: path) else {
                continue
            }
            values[app.id] = data
        }
        return values
    }

    func signingHistory(for accountID: UUID) -> [SigningHistoryRecord] {
        signingHistory.filter { $0.accountID == accountID }
    }

    func signingHistorySummary(for accountID: UUID) -> SigningHistorySummary {
        SigningHistorySummary(records: signingHistory(for: accountID))
    }

    func certificateInventory(for accountID: UUID) -> ApplePortalInventory? {
        certificateInventories[accountID]
    }

    func certificateInventoryFailure(for accountID: UUID) -> ImportFailure? {
        certificateInventoryFailures[accountID]
    }

    func certificateHealthStatus(for accountID: UUID) -> CertificateHealthStatus? {
        certificateHealthStatuses[accountID]
    }

    func isCertificateInventoryLoading(accountID: UUID) -> Bool {
        certificateInventoryLoadingIDs.contains(accountID)
    }

    func refreshAppIDInventories() async {
        for account in accounts where AccountAvailabilityPolicy.isSelectable(account) {
            await refreshAppIDInventory(for: account, force: true)
        }
    }

    func refreshAppIDInventory(
        for account: AppleAccountRecord,
        force: Bool = true
    ) async {
        guard let keychain, let applePortalInventoryService else { return }
        if force == false, certificateInventories[account.id]?.appIDs.isEmpty == false { return }
        if certificateInventoryLoadingIDs.contains(account.id) { return }

        certificateInventoryLoadingIDs.insert(account.id)
        defer { certificateInventoryLoadingIDs.remove(account.id) }

        do {
            guard let secret = try await keychain.load(accountID: account.id) else {
                // 后台同步不改变账号验证状态：Keychain 瞬时不可读不应把 ID 标为失效。
                // 凭据缺失只记录同步失败，用户主动验证时才会标记 needsVerification。
                throw Self.failure(
                    title: "Apple ID 同步失败",
                    reason: "本机没有此 Apple ID 的登录凭据。",
                    recovery: "重新验证 Apple ID",
                    code: "SEAL-INVENTORY-100"
                )
            }
            let fetched = try await applePortalInventoryService.fetchInventory(
                account: account,
                secret: secret,
                scope: .appIDs
            )
            let merged = ApplePortalInventory(
                accountID: fetched.accountID,
                teamID: fetched.teamID,
                teamName: fetched.teamName,
                appIDs: fetched.appIDs,
                certificates: certificateInventories[account.id]?.certificates ?? [],
                fetchedAt: fetched.fetchedAt
            )
            certificateInventories[account.id] = merged
            certificateInventoryFailures[account.id] = nil
            saveCertificateInventoryCache(merged)
            try? await logStore?.append(
                category: .account,
                // `usedBundleIDCount` 是**已注册存活**的 App ID 数量，不是剩余名额。
                // 旧文案写成「N 个可用 App ID」语义正好相反：用户看到「10 个可用」会以为
                // 还剩 10 个名额，实际是已经用满 10 个（免费账号上限）。
                // 这直接导致「id 有足够的名额」的误判，进而把多扩展 App 的失败原因找错方向。
                // 与 CertificatesRootView 的「已签名 N / 10」保持同一口径。
                message: "Apple App ID 已同步：已注册 \(merged.usedBundleIDCount) / 10 个 App ID"
            )
        } catch is CancellationError {
            // 任务取消不是错误：不污染失败标记，静默返回。
            return
        } catch let failure as ImportFailure {
            certificateInventoryFailures[account.id] = failure
        } catch {
            certificateInventoryFailures[account.id] = Self.failure(
                title: "Apple ID 同步失败",
                reason: "App ID 状态同步失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重新同步",
                code: "SEAL-INVENTORY-900"
            )
        }
        logs = (try? await logStore?.entries()) ?? logs
        refreshLogExportText()
    }

    func refreshCertificateInventories() async {
        for account in accounts where AccountAvailabilityPolicy.isSelectable(account) {
            await refreshCertificateInventory(for: account, force: true)
        }
    }

    /// 汇总 Seal 自管理状态：真实签名身份 + 未结算事务 + 签名者是否持有本机私钥。
    /// 只依赖本地数据（运行包 / 事务文件 / keychain），不访问网络。
    func refreshSelfManagementState() async {
        let identity = SelfAppMetadata.current()?.installedIdentity
        let signer = (identity?.isComplete == true)
            ? identity?.mainTarget?.signerSerialNumber
            : nil
        sealActualSignerSerialNumber = signer
        // 事务文件读不出来按「无事务」处理；身份不可读已由 resolver 兜到恢复态。
        let transaction = try? await selfReplacementStore?.loadPending()
        var signerIsLocal = false
        if let signer, let keychain {
            for account in accounts {
                guard let secret = try? await keychain.load(accountID: account.id),
                      secret.p12(for: signer) != nil else { continue }
                signerIsLocal = true
                break
            }
        }
        selfManagement = SelfManagementPresentation(
            SelfManagementStateResolver.resolve(
                identity: identity,
                pendingTransaction: transaction,
                signerHasLocalPrivateKey: signerIsLocal
            )
        )
    }

    func refreshCertificateInventory(
        for account: AppleAccountRecord,
        force: Bool = true
    ) async {
        guard let keychain, let applePortalInventoryService else { return }
        // 证书清单刷新时同步自管理状态；本地数据即可判定，网络失败不影响。
        await refreshSelfManagementState()
        if force == false, certificateInventories[account.id] != nil { return }
        if certificateInventoryLoadingIDs.contains(account.id) { return }

        certificateInventoryLoadingIDs.insert(account.id)
        defer { certificateInventoryLoadingIDs.remove(account.id) }

        do {
            guard let secret = try await keychain.load(accountID: account.id) else {
                // 后台同步不改变账号验证状态，同上。
                throw Self.failure(
                    title: "Apple 侧同步失败",
                    reason: "本机没有此 Apple ID 的登录凭据。",
                    recovery: "重新验证 Apple ID",
                    code: "SEAL-INVENTORY-100a"
                )
            }
            let fetched = try await applePortalInventoryService.fetchInventory(
                account: account,
                secret: secret,
                scope: .certificates
            )
            let inventory = ApplePortalInventory(
                accountID: fetched.accountID,
                teamID: fetched.teamID,
                teamName: fetched.teamName,
                appIDs: certificateInventories[account.id]?.appIDs ?? [],
                certificates: fetched.certificates,
                fetchedAt: fetched.fetchedAt
            )
            certificateInventories[account.id] = inventory
            certificateInventoryFailures[account.id] = nil
            certificateHealthStatuses[account.id] = await makeCertificateHealthStatus(
                account: account,
                secret: secret,
                inventory: inventory
            )
            saveCertificateInventoryCache(inventory)
            try? await logStore?.append(
                category: .account,
                message: "Apple 侧证书状态已同步"
            )
        } catch let failure as ImportFailure {
            certificateInventoryFailures[account.id] = failure
            // authToken失效(SEAL-AUTH-107)时证书标无效，避免显示"有效但实际用不了"的矛盾
            let portalState: CertificateHealthStatus.CheckState =
                failure.code == "SEAL-AUTH-107" ? .invalid : .unknown
            certificateHealthStatuses[account.id] = await localCertificateHealthStatus(
                account: account,
                portalState: portalState
            )
            try? await logStore?.append(
                category: .account,
                level: .error,
                message: failure.reason,
                code: failure.code
            )
        } catch is CancellationError {
            // 任务取消不是错误：不污染证书健康状态/失败标记，静默返回。
            return
        } catch {
            let failure = Self.failure(
                title: "Apple 侧同步失败",
                reason: "证书状态同步失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重新同步",
                code: "SEAL-INVENTORY-900a"
            )
            certificateInventoryFailures[account.id] = failure
            certificateHealthStatuses[account.id] = await localCertificateHealthStatus(
                account: account,
                portalState: .unknown
            )
            try? await logStore?.append(
                category: .account,
                level: .error,
                message: failure.reason,
                code: failure.code
            )
        }
        logs = (try? await logStore?.entries()) ?? logs
        refreshLogExportText()
    }

    /// 立即用本机凭据 + 缓存清单刷新证书健康状态（不触发网络请求），
    /// 避免「签名完回来证书卡片长时间停留在『检查中』」。
    func refreshCertificateHealthLocally(for account: AppleAccountRecord) async {
        guard let keychain else { return }
        do {
            guard let secret = try await keychain.load(accountID: account.id) else { return }
            let status = await makeCertificateHealthStatus(
                account: account,
                secret: secret,
                inventory: certificateInventories[account.id],
                portalStateOverride: .unknown
            )
            if let status {
                certificateHealthStatuses[account.id] = status
            }
        } catch {
            // 本地读取失败不置空，保留现有（若有）健康状态。
        }
    }

    private func localCertificateHealthStatus(
        account: AppleAccountRecord,
        portalState: CertificateHealthStatus.CheckState
    ) async -> CertificateHealthStatus? {
        guard let keychain else { return nil }
        do {
            guard let secret = try await keychain.load(accountID: account.id) else {
                return nil
            }
            return await makeCertificateHealthStatus(
                account: account,
                secret: secret,
                inventory: nil,
                portalStateOverride: portalState
            )
        } catch {
            guard let serial = account.selectedCertificateSerialNumber
                    ?? account.certificateSerialNumber else {
                return nil
            }
            return CertificateHealthStatus(
                serialNumber: serial,
                portalPresence: portalState,
                p12Readable: .unknown,
                localPrivateKey: .unknown,
                keychainReadable: .invalid,
                appleIDMatch: .unknown,
                teamMatch: .unknown,
                expirationDate: nil,
                lastSignedAt: nil,
                relatedAppCount: 0,
                usableOnCurrentDeviceAppIDCount: nil
            )
        }
    }

    private func makeCertificateHealthStatus(
        account: AppleAccountRecord,
        secret: AccountSecret,
        inventory: ApplePortalInventory?,
        portalStateOverride: CertificateHealthStatus.CheckState? = nil
    ) async -> CertificateHealthStatus? {
        guard let serial = account.selectedCertificateSerialNumber
                ?? account.certificateSerialNumber
                ?? secret.certificateSerialNumber,
              serial.isEmpty == false else {
            return nil
        }

        let localCertificate: ALTCertificate? = {
            guard let p12 = secret.certificateP12 else { return nil }
            return try? ALTCertificate(p12Data: p12, password: nil)
        }()
        let localSerialMatches = localCertificate?.serialNumber.caseInsensitiveCompare(serial) == .orderedSame
        let storedSerialMatches = secret.certificateSerialNumber?.caseInsensitiveCompare(serial) == .orderedSame
        let portalCertificate = inventory?.certificates.first {
            $0.serialNumber.caseInsensitiveCompare(serial) == .orderedSame
        }

        let portalPresence = portalStateOverride
            ?? (portalCertificate == nil ? .invalid : .valid)
        let localValidity = localCertificate?.data
            .flatMap(X509CertificateValidityReader.validity(from:))
        // Apple 已明确找不到这张证书时，不能再拿本机旧 P12 的 notAfter 当作有效期。
        // 否则会出现「卡片显示无效，下面却显示一个已撤销的未来日期」的误导。
        let expirationDate = portalPresence == .invalid
            ? nil
            : (portalCertificate?.expirationDate ?? localValidity?.notAfter)

        var relatedApps: [AppRecord] = []
        if let appStore {
            do {
                relatedApps = try await appStore.fetchAll().filter { app in
                    app.accountID == account.id
                        && app.signingTeamID == account.teamID
                        && app.certificateSerialNumber?.caseInsensitiveCompare(serial) == .orderedSame
                }
            } catch {
                try? await logStore?.append(
                    category: .account,
                    level: .error,
                    message: "无法读取使用当前 Serial 的应用记录",
                    code: "SEAL-CERT-HEALTH-001"
                )
            }
        }

        let normalizedSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(serial)
        let usableAppIDCount = Set(relatedApps.compactMap { app -> String? in
            let signedBundleID = app.mappedBundleIdentifier ?? app.preferredBundleIdentifier ?? app.originalBundleIdentifier
            guard let deviceID = app.signedDeviceIdentifier, deviceID.isEmpty == false else { return nil }
            guard app.signingTargets.contains(where: { target in
                target.bundleIdentifier.caseInsensitiveCompare(signedBundleID) == .orderedSame
                    && target.teamIdentifier.caseInsensitiveCompare(account.teamID) == .orderedSame
                    && target.profileExpirationDate > Date()
                    && target.deviceIdentifiers.contains(where: { $0.caseInsensitiveCompare(deviceID) == .orderedSame })
                    && target.certificateSerialNumbers.contains(where: { SigningCertificateSelectionPolicy.normalizedSerialNumber($0) == normalizedSerial })
            }) else { return nil }
            return signedBundleID.lowercased()
        }).count

        return CertificateHealthStatus(
            serialNumber: serial,
            portalPresence: portalPresence,
            p12Readable: localCertificate == nil ? .invalid : .valid,
            localPrivateKey: localCertificate?.privateKey != nil
                && localSerialMatches
                && storedSerialMatches ? .valid : .invalid,
            keychainReadable: .valid,
            appleIDMatch: secret.accountIdentifier == account.accountIdentifier ? .valid : .invalid,
            teamMatch: inventory.map { $0.teamID == account.teamID ? .valid : .invalid } ?? .unknown,
            expirationDate: expirationDate,
            lastSignedAt: relatedApps.compactMap(\AppRecord.lastSignedAt).max(),
            relatedAppCount: relatedApps.count,
            usableOnCurrentDeviceAppIDCount: usableAppIDCount
        )
    }

    private func loadCertificateInventoryCache(for accounts: [AppleAccountRecord]) {
        let validIDs = Set(accounts.map(\.id))
        var cached: [UUID: ApplePortalInventory] = [:]
        for account in accounts {
            guard let data = UserDefaults.standard.data(forKey: certificateInventoryCacheKey(account.id)),
                  let inventory = try? JSONDecoder().decode(ApplePortalInventory.self, from: data) else {
                continue
            }
            cached[account.id] = inventory
        }
        certificateInventories = certificateInventories.filter { validIDs.contains($0.key) }
        for (id, inventory) in cached where certificateInventories[id] == nil {
            certificateInventories[id] = inventory
        }
    }

    private func saveCertificateInventoryCache(_ inventory: ApplePortalInventory) {
        guard let data = try? JSONEncoder().encode(inventory) else { return }
        UserDefaults.standard.set(data, forKey: certificateInventoryCacheKey(inventory.accountID))
    }

    /// 撤销成功后立即从内存与缓存清单中移除该证书，UI 无需等网络回读即可同步。
    private func removeRevokedCertificateFromInventory(serialNumber: String, accountID: UUID) {
        guard let inventory = certificateInventories[accountID] else { return }
        let normalized = SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
        let remaining = inventory.certificates.filter {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber) != normalized
        }
        guard remaining.count != inventory.certificates.count else { return }
        let updated = ApplePortalInventory(
            accountID: inventory.accountID,
            teamID: inventory.teamID,
            teamName: inventory.teamName,
            appIDs: inventory.appIDs,
            certificates: remaining,
            fetchedAt: inventory.fetchedAt
        )
        certificateInventories[accountID] = updated
        saveCertificateInventoryCache(updated)
    }

    private func certificateInventoryCacheKey(_ accountID: UUID) -> String {
        "settings.applePortalInventory.\(accountID.uuidString)"
    }

    func clearSigningHistory(for accountID: UUID) async {
        guard let signingHistoryStore else { return }
        do {
            try await signingHistoryStore.clear(accountID: accountID)
            signingHistory = (try? await signingHistoryStore.records()) ?? []
            signingHistoryIconData = await loadSigningHistoryIcons(for: signingHistory)
            try? await logStore?.append(
                category: .system,
                message: "已清除 Apple ID 的签名历史"
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
        } catch {
            alertFailure = Self.failure(
                title: "无法清除签名历史",
                reason: "本地签名历史记录不可写入。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-HISTORY-001"
            )
        }
    }

    private func loadSigningHistoryIcons(
        for records: [SigningHistoryRecord]
    ) async -> [UUID: Data] {
        guard let fileStore else { return [:] }
        var values: [UUID: Data] = [:]
        for record in records {
            guard let path = record.iconRelativePath,
                  let data = try? await fileStore.read(relativePath: path) else {
                continue
            }
            values[record.id] = data
        }
        return values
    }

    func requestInitialPermissionsIfNeeded() async {
        // 通知权限只在用户主动开启“到期前 24 小时提醒”时请求。
    }

    func resetSigningEnvironment() async {
        guard let anisetteEnvironment else { return }
        guard let operationLease = await acquireOperation(.managingAccount) else { return }
        defer { releaseOperation(operationLease) }
        await anisetteEnvironment.resetProvisioning()
        try? await logStore?.append(
            category: .system,
            message: "Signing environment reset"
        )
        logs = (try? await logStore?.entries()) ?? logs
    }

    func addAccount(
        email: String,
        password: String,
        replacing existingAccount: AppleAccountRecord? = nil
    ) async -> Bool {
        guard accountPhase == .idle,
              let accountClient else { return false }
        guard let operationLease = await acquireOperation(.managingAccount) else { return false }
        defer { releaseOperation(operationLease) }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedEmail.isEmpty == false, password.isEmpty == false else {
            alertFailure = Self.failure(
                title: "信息不完整",
                reason: "请输入 Apple ID 和密码",
                recovery: "知道了",
                code: "SEAL-AUTH-100"
            )
            return false
        }

        pendingTeamSelection = nil
        accountPhase = .authenticating
        defer { accountPhase = .idle }
        do {
            let authenticated = try await accountClient.authenticate(
                email: normalizedEmail,
                password: password,
                verificationCode: { [weak self] in
                    await self?.verificationBroker.request()
                }
            )
            try Task.checkCancellation()

            guard authenticated.teams.isEmpty == false else {
                throw Self.failure(
                    title: "没有可用开发者团队",
                reason: "这个 Apple ID 下没有可用于签名的开发者团队。",
                recovery: "确认该 Apple ID 可正常登录且已同意 Apple 开发者协议（免费账号即可），或更换其他 Apple ID",
                    code: "SEAL-AUTH-114"
                )
            }

            if let existingAccount {
                guard existingAccount.accountIdentifier == authenticated.accountIdentifier else {
                    throw Self.failure(
                        title: "Apple ID 不匹配",
                        reason: "重新验证返回的 Apple ID（\(authenticated.maskedEmail)）与当前保存的（\(existingAccount.maskedEmail)）不一致。",
                        recovery: "重新验证 Apple ID",
                        code: "SEAL-AUTH-108"
                    )
                }
                guard let existingTeam = authenticated.teams.first(where: { $0.id == existingAccount.teamID }) else {
                    throw Self.failure(
                        title: "原 Team 不可用",
                        reason: "重新验证后没有找到原 Team（\(TeamNameDisplayFormatter.string(from: existingAccount.teamName)) / \(existingAccount.teamID)）。Seal 不会静默切换到其他 Team。",
                        recovery: "重新验证 Apple ID",
                        code: "SEAL-AUTH-109a"
                    )
                }
                return try await persistAuthenticatedAccount(
                    authenticated,
                    team: existingTeam,
                    replacing: existingAccount
                )
            }

            if authenticated.teams.count == 1, let team = authenticated.teams.first {
                return try await persistAuthenticatedAccount(authenticated, team: team, replacing: nil)
            }

            pendingTeamSelection = PendingTeamSelection(authenticated: authenticated)
            return false
        } catch is CancellationError {
            pendingTeamSelection = nil
            return false
        } catch let failure as ImportFailure {
            pendingTeamSelection = nil
            alertFailure = failure
            try? await logStore?.append(
                category: .account,
                level: .error,
                message: failure.reason,
                code: failure.code
            )
            logs = (try? await logStore?.entries()) ?? logs
            return false
        } catch {
            pendingTeamSelection = nil
            let failure = AppleServiceFailurePolicy.isNetworkError(error)
                ? AppleServiceFailurePolicy.networkFailure(underlying: error)
                : Self.failure(
                    title: "无法添加账号",
                    reason: "Apple ID 验证失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                    recovery: "重试；如持续失败请核对 Apple ID 与密码",
                    code: "SEAL-AUTH-102"
                )
            alertFailure = failure
            try? await logStore?.append(
                category: .account,
                level: .error,
                message: failure.reason,
                code: failure.code
            )
            logs = (try? await logStore?.entries()) ?? logs
            return false
        }
    }

    func completeTeamSelection(_ team: AppleTeamRecord) async -> Bool {
        guard accountPhase == .idle,
              let pending = pendingTeamSelection,
              pending.teams.contains(team) else { return false }
        guard let operationLease = await acquireOperation(.managingAccount) else { return false }
        defer { releaseOperation(operationLease) }
        accountPhase = .authenticating
        defer { accountPhase = .idle }
        do {
            let result = try await persistAuthenticatedAccount(
                pending.authenticated,
                team: team,
                replacing: nil
            )
            if result { pendingTeamSelection = nil }
            return result
        } catch let failure as ImportFailure {
            alertFailure = failure
            return false
        } catch {
            alertFailure = Self.failure(
                title: "无法保存 Team",
                reason: "账号信息保存失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试；如持续失败请重新验证 Apple ID",
                code: "SEAL-AUTH-110b"
            )
            return false
        }
    }

    func cancelTeamSelection() {
        pendingTeamSelection = nil
    }

    private func persistAuthenticatedAccount(
        _ authenticated: AuthenticatedAppleAccount,
        team: AppleTeamRecord,
        replacing existingAccount: AppleAccountRecord?
    ) async throws -> Bool {
        guard let accountRepository, let keychain else { return false }
        let storedAccounts = try await accountRepository.fetchAll()
        let canReplaceExisting = existingAccount.map { account in
            account.accountIdentifier == authenticated.accountIdentifier && account.teamID == team.id
        } ?? false
        let replacingAccountID = canReplaceExisting ? existingAccount?.id : nil
        let duplicateAccount = storedAccounts.first { candidate in
            if let replacingAccountID, candidate.id == replacingAccountID { return false }
            return candidate.accountIdentifier == authenticated.accountIdentifier && candidate.teamID == team.id
        }
        let baseAccount = canReplaceExisting ? existingAccount : duplicateAccount
        let baseRecord = authenticated.record(team: team, id: baseAccount?.id ?? UUID())
        let record = baseAccount.map { old in
            AppleAccountRecord(
                id: old.id,
                maskedEmail: baseRecord.maskedEmail,
                accountIdentifier: baseRecord.accountIdentifier,
                teamID: baseRecord.teamID,
                teamName: baseRecord.teamName,
                isFreeTeam: baseRecord.isFreeTeam,
                status: .verified,
                certificateSerialNumber: old.certificateSerialNumber,
                selectedCertificateSerialNumber: old.selectedCertificateSerialNumber,
                lastVerifiedAt: baseRecord.lastVerifiedAt
            )
        } ?? baseRecord

        let previousSecret = try await keychain.load(accountID: record.id)
        let mergedSecret = authenticated.secret.preservingSigningMaterial(from: previousSecret)
        try await keychain.save(mergedSecret, for: record.id)
        do {
            try await accountRepository.save(record)
        } catch {
            let originalError = error
            do {
                if let previousSecret {
                    try await keychain.save(previousSecret, for: record.id)
                } else {
                    try await keychain.delete(accountID: record.id)
                }
            } catch {
                throw Self.failure(
                    title: "账号保存补偿未完成",
                    reason: "账号记录保存失败，且 Keychain 无法恢复到修改前状态。",
                    recovery: "重新验证 Apple ID 后检查账号状态",
                    code: "SEAL-AUTH-DB-002"
                )
            }
            throw originalError
        }

        await load(force: true)
        if let saved = accounts.first(where: { $0.id == record.id }) {
            await refreshCertificateInventory(for: saved, force: true)
            if activeAccountID == nil || existingAccount == nil && duplicateAccount == nil {
                await selectActiveAccount(saved)
            }
        }
        try? await logStore?.append(
            category: .account,
            message: duplicateAccount == nil
                ? "Apple ID 已添加（Team: \(TeamNameDisplayFormatter.string(from: team.name))）"
                : "Apple ID 已重新绑定到现有账号记录（Team: \(TeamNameDisplayFormatter.string(from: team.name))）"
        )
        return true
    }

    func deleteAccount(_ account: AppleAccountRecord) async {
        guard let accountRepository, let keychain else { return }
        guard let operationLease = await acquireOperation(.managingAccount) else { return }
        defer { releaseOperation(operationLease) }
        let relatedApps = (try? await appStore?.fetchAll())?
            .filter { $0.accountID == account.id } ?? []
        let storedSecret: AccountSecret?
        do {
            storedSecret = try await keychain.load(accountID: account.id)
        } catch {
            alertFailure = Self.failure(
                title: "无法删除 Apple ID",
                reason: "删除 \(account.maskedEmail) 前无法读取其本机 Keychain 凭据，已中止删除以避免数据丢失。",
                recovery: "重启应用后重试；仍失败请先重新验证该 Apple ID 再删除",
                code: "SEAL-AUTH-DB-003"
            )
            return
        }
        do {
            try await accountRepository.delete(id: account.id)
            try await keychain.delete(accountID: account.id)
            if activeAccountID == account.id {
                activeAccountID = nil
                await signingPreferenceStore?.setActiveAccountID(nil)
            }
            await load(force: true)
            try? await logStore?.append(
                category: .account,
                message: "Apple ID 已移除；关联应用保留原账号绑定，用于防止误用其他账号续签。关联应用数：\(relatedApps.count)"
            )
        } catch {
            var rollbackFailures: [String] = []
            do {
                try await accountRepository.save(account)
            } catch {
                rollbackFailures.append("账号记录")
            }
            if let storedSecret {
                do {
                    try await keychain.save(storedSecret, for: account.id)
                } catch {
                    rollbackFailures.append("Keychain")
                }
            }
            await load(force: true)
            alertFailure = Self.failure(
                title: "无法移除账号",
                reason: rollbackFailures.isEmpty
                    ? "删除 \(account.maskedEmail) 时本地数据未能更新，原账号已恢复。"
                    : "删除失败，且本地补偿未完整完成（\(rollbackFailures.joined(separator: "、"))）。",
                recovery: rollbackFailures.isEmpty ? "重试" : "重新验证 Apple ID 后检查账号状态",
                code: rollbackFailures.isEmpty ? "SEAL-AUTH-106" : "SEAL-AUTH-DB-002"
            )
        }
    }

    func email(for account: AppleAccountRecord) async -> String {
        guard let keychain else { return "" }
        return (try? await keychain.load(accountID: account.id))?.email ?? ""
    }

    @discardableResult
    func importPairingAssistantInboxIfPresent() async -> Bool {
        guard let pairingStore else { return false }
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return false
        }

        let inboxURL = documentsURL.appendingPathComponent(
            Self.pairingAssistantInboxFileName,
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: inboxURL.path) else {
            return false
        }

        // 只有文件确实存在时才获取锁，避免无意义的互斥冲突
        guard let operationLease = await acquireOperation(.resettingPairing) else { return false }
        defer { releaseOperation(operationLease) }

        // 二次检查，防止竞态条件
        guard FileManager.default.fileExists(atPath: inboxURL.path) else {
            return false
        }

        do {
            pairingRecord = try await pairingStore.importFile(at: inboxURL)
            await installChannel?.reset()
            diagnosticState = .idle
            installDiagnostics = .empty
            try? FileManager.default.removeItem(at: inboxURL)
            try? await logStore?.append(
                category: .pairing,
                message: "\(Self.pairingAssistantSource)已自动写入配对信息，等待真实设备连接验证"
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
            await runInstallChannelCheck(successMessage: "LocalDevVPN 通道正常（需连接 Wi-Fi）")
            return true
        } catch let failure as ImportFailure {
            try? FileManager.default.removeItem(at: inboxURL)
            alertFailure = failure
            try? await logStore?.append(
                category: .pairing,
                level: .error,
                message: "\(Self.pairingAssistantSource)写入的配对信息无法导入",
                code: failure.code
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
            return false
        } catch {
            try? FileManager.default.removeItem(at: inboxURL)
            alertFailure = Self.failure(
                title: "无法接收配对信息",
                reason: "Seal 配对助手已发送数据，但本机无法读取。",
                recovery: "重新配对",
                code: "SEAL-PAIR-207"
            )
            try? await logStore?.append(
                category: .pairing,
                level: .error,
                message: "\(Self.pairingAssistantSource)写入的配对信息读取失败",
                code: "SEAL-PAIR-207a"
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
            return false
        }
    }

    /// 手动导入用户选择的配对文件。
    /// 支持 iOS 17.4+ RemotePairing（.mobiledevicepairing / JSON）和
    /// iOS 17.3.1 及以下 Lockdown（.plist，含 iOS 16）——
    /// ⚠️ 分界是 **17.4**（`CoreDeviceProxy` 从 17.4 才引入），**不是 17.0**：
    /// 17.0–17.3.1 与 iOS 16 都走 Lockdown ✓。
    @discardableResult
    func importPairingFile(at sourceURL: URL) async -> Bool {
        guard let pairingStore else { return false }
        guard let operationLease = await acquireOperation(.resettingPairing) else { return false }
        defer { releaseOperation(operationLease) }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            pairingRecord = try await pairingStore.importFile(at: sourceURL)
            await installChannel?.reset()
            diagnosticState = .idle
            installDiagnostics = .empty
            try? await logStore?.append(
                category: .pairing,
                message: "手动导入配对文件成功，等待真实设备连接验证"
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
            await runInstallChannelCheck(successMessage: "LocalDevVPN 通道正常（需连接 Wi-Fi）")
            return true
        } catch let failure as ImportFailure {
            alertFailure = failure
            try? await logStore?.append(
                category: .pairing,
                level: .error,
                message: "手动导入配对文件失败",
                code: failure.code
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
            return false
        } catch {
            alertFailure = Self.failure(
                title: "无法读取配对文件",
                reason: "所选文件无法读取或不是有效的配对文件。",
                recovery: "重新选择文件",
                code: "SEAL-PAIR-208"
            )
            try? await logStore?.append(
                category: .pairing,
                level: .error,
                message: "手动导入配对文件读取失败",
                code: "SEAL-PAIR-208a"
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
            return false
        }
    }

    func testConnection() async {
        await load(force: true)
        guard diagnosticState != .running, installChannel != nil else { return }
        guard accounts.isEmpty == false,
              let accountClient,
              let keychain,
              let accountRepository else {
            diagnosticState = .failed(
                Self.failure(
                    title: "缺少签名账号",
                    reason: "尚未添加 Apple ID",
                    recovery: "添加账号",
                    code: "SEAL-AUTH-104e"
                )
            )
            return
        }
        guard pairingRecord != nil else {
            diagnosticState = .failed(
                Self.failure(
                    title: "设备未配对",
                    reason: "尚未完成当前设备配对",
                    recovery: "连接设备",
                    code: "SEAL-PAIR-203"
                )
            )
            return
        }

        let selected = activeAccount
            ?? accounts.first(where: { AccountAvailabilityPolicy.isSelectable($0) })
            ?? accounts.first
        guard var account = selected else { return }
        if activeAccountID != account.id {
            activeAccountID = account.id
            await signingPreferenceStore?.setActiveAccountID(account.id)
        }

        diagnosticState = .running
        do {
            guard let secret = try await keychain.load(accountID: account.id) else {
                await persistVerificationFailure(.localCredentialsMissing, for: account)
                throw Self.failure(
                    title: "账号需要验证",
                    reason: "本机没有当前 Apple ID 的登录凭据。",
                    recovery: "重新验证 Apple ID",
                    code: "SEAL-AUTH-105e"
                )
            }

            do {
                try await accountClient.validate(account: account, secret: secret)
                account.status = .verified
                account.verificationFailureReason = nil
                account.maskedEmail = AppleAccountClient.mask(secret.email)
                account.lastVerifiedAt = Date()
                try await accountRepository.save(account)
            } catch let failure as ImportFailure {
                if let reason = AppleServiceFailurePolicy.verificationFailureReason(for: failure) {
                    await persistVerificationFailure(reason, for: account)
                }
                throw failure
            } catch {
                if AppleServiceFailurePolicy.isNetworkError(error) {
                    throw AppleServiceFailurePolicy.networkFailure(
                        title: "无法连接 Apple",
                        reason: "当前网络或 Apple 服务不可用。Apple ID 状态未改变。"
                    )
                }
                throw Self.failure(
                    title: "无法验证 Apple ID",
                    reason: "Apple 验证返回了无法分类的错误。账号状态未改变。\n[\((error as NSError).domain) \((error as NSError).code)]",
                    recovery: "稍后重试；如持续失败再重新验证 Apple ID",
                    code: "SEAL-VERIFY-500"
                )
            }

            await refreshCertificateInventory(for: account, force: true)
            if let failure = certificateInventoryFailures[account.id] {
                throw failure
            }
            await runInstallChannelCheck(successMessage: "签名环境检测正常")
        } catch let failure as ImportFailure {
            await finishInstallChannelCheckWithFailure(
                failure,
                logMessage: "签名环境检测失败"
            )
        } catch {
            await finishInstallChannelCheckWithFailure(
                Self.localDevVPNUnavailableFailure,
                logMessage: "签名环境检测失败"
            )
        }
    }

    /// 只检查配对+VPN+Minimuxer，不需要 Apple ID 账号
    func testPairingConnection() async {
        await load(force: true)
        guard installChannel != nil else {
            diagnosticState = .failed(
                Self.failure(
                    title: "连接通道未就绪",
                    reason: "LocalDevVPN 未启动或未安装。请先连接 Wi-Fi 并打开 LocalDevVPN。",
                    recovery: "打开 LocalDevVPN 后重试",
                    code: "SEAL-PAIR-204"
                )
            )
            return
        }
        guard pairingRecord != nil else {
            diagnosticState = .failed(
                Self.failure(
                    title: "设备未配对",
                    reason: "尚未完成当前设备配对",
                    recovery: "连接设备",
                    code: "SEAL-PAIR-203"
                )
            )
            return
        }
        // 强制重置状态，确保每次点击都能重新验证（避免失败后卡住）
        diagnosticState = .idle
        installDiagnostics = .empty
        await installChannel?.reset()
        await runInstallChannelCheck(successMessage: "设备连接正常")
    }

    private func persistVerificationFailure(
        _ reason: AccountVerificationFailureReason,
        for account: AppleAccountRecord
    ) async {
        guard let accountRepository else { return }
        var updated = account
        updated.status = .needsVerification
        updated.verificationFailureReason = reason
        try? await accountRepository.save(updated)
    }

    private func repairLegacyAccountStatuses(
        _ records: [AppleAccountRecord]
    ) async throws -> [AppleAccountRecord] {
        guard let accountRepository, let keychain else { return records }
        var repaired = records
        for index in repaired.indices where repaired[index].status == .needsVerification {
            let hasLocalSecret = try await keychain.load(accountID: repaired[index].id) != nil
            let status = AccountAvailabilityPolicy.repairedStatus(
                for: repaired[index],
                hasLocalSecret: hasLocalSecret
            )
            guard status != repaired[index].status else { continue }
            repaired[index].status = status
            try await accountRepository.save(repaired[index])
        }
        return repaired
    }

    func testLocalDevVPN() async {
        await load(force: true)
        guard diagnosticState != .running, installChannel != nil else { return }
        guard pairingRecord != nil else {
            diagnosticState = .failed(
                Self.failure(
                    title: "设备未配对",
                    reason: "检测连接前需要先完成当前设备配对",
                    recovery: "连接设备",
                    code: "SEAL-PAIR-203a"
                )
            )
            return
        }
        await runInstallChannelCheck(successMessage: "LocalDevVPN 正常")
    }

    private func runInstallChannelCheck(successMessage: String) async {
        guard let installChannel else { return }
        diagnosticState = .running
        // 与 `MinimuxerInstallChannel.diagnose()` 的入口日志**配对**：两者之间只隔
        // `markValidating()`，于是这段的耗时能直接从两条日志的时间戳读出（2026-09-21）。
        // ⚠️ 这条不能省：`diagnose()` 的入口日志写在 `markValidating()` **之后**，
        // 若卡在 `markValidating()`，日志里会一条都没有 ⇒ 又回到「无法区分」✗。
        try? await logStore?.append(
            category: .installation,
            message: "开始检测安装通道：配对状态 → LocalDevVPN → 设备响应"
        )
        logs = (try? await logStore?.entries()) ?? logs
        refreshLogExportText()
        if let pairingStore, pairingRecord != nil {
            do {
                pairingRecord = try await pairingStore.markValidating()
            } catch {
                let failure = Self.failure(
                    title: "配对验证失败",
                    reason: "无法保存设备配对的验证中状态。",
                    recovery: "重新配对设备",
                    code: "SEAL-PAIR-206"
                )
                diagnosticState = .failed(failure)
                alertFailure = failure
                // ⚠️ 这个出口此前**只有弹窗、没有日志**（2026-09-21）：真机日志里于是
                // 「既无成功行、也无失败行」，与「卡在 `diagnose()` 里」完全同形 ✗ ——
                // 用户看到的弹窗不会随日志发回来，所以它等于静默。
                try? await logStore?.append(
                    category: .installation,
                    level: .error,
                    message: "安装通道检测中止：无法保存配对的验证中状态",
                    code: "SEAL-PAIR-206"
                )
                logs = (try? await logStore?.entries()) ?? logs
                refreshLogExportText()
                return
            }
        }
        let diagnostics = await installChannel.diagnose()
        installDiagnostics = diagnostics
        if diagnostics.isReady, let deviceIdentifier = diagnostics.deviceIdentifier {
            if let pairingStore {
                do {
                    pairingRecord = try await pairingStore.markValidated(
                        deviceIdentifier: deviceIdentifier
                    )
                } catch let failure as ImportFailure {
                    await finishInstallChannelCheckWithFailure(
                        failure,
                        diagnostics: diagnostics,
                        logMessage: "设备配对校验失败"
                    )
                    return
                } catch {
                    await finishInstallChannelCheckWithFailure(
                        Self.failure(
                            title: "配对验证失败",
                            reason: "无法保存当前设备的配对验证结果。",
                            recovery: "重新配对设备",
                            code: "SEAL-PAIR-207b"
                        ),
                        diagnostics: diagnostics,
                        logMessage: "设备配对校验失败"
                    )
                    return
                }
            }
            diagnosticState = .ready(deviceIdentifier: deviceIdentifier)
            await load(force: true)
            installDiagnostics = diagnostics
            try? await logStore?.append(
                category: .installation,
                message: successMessage
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
            return
        }
        await finishInstallChannelCheckWithFailure(
            diagnostics.failure ?? Self.localDevVPNUnavailableFailure,
            diagnostics: diagnostics,
            logMessage: "LocalDevVPN 检测失败"
        )
    }

    private static func shouldRollbackPairing(after failure: ImportFailure) -> Bool {
        ["SEAL-PAIR-205", "SEAL-PAIR-206", "SEAL-INSTALL-703"].contains(failure.code)
    }

    private func finishInstallChannelCheckWithFailure(
        _ failure: ImportFailure,
        diagnostics: InstallChannelDiagnostics? = nil,
        logMessage: String
    ) async {
        var effectiveFailure = failure
        var effectiveDiagnostics = diagnostics
        if Self.shouldRollbackPairing(after: failure), let pairingStore {
            do {
                if let restored = try await pairingStore.restoreBackupIfPresent() {
                    pairingRecord = restored
                    await installChannel?.reset()
                    try? await logStore?.append(
                        category: .pairing,
                        message: "新配对信息验证失败，已自动恢复上一份可用配对信息"
                    )
                    if let installChannel {
                        let recoveryDiagnostics = await installChannel.diagnose()
                        effectiveDiagnostics = recoveryDiagnostics
                        if recoveryDiagnostics.isReady,
                           let deviceIdentifier = recoveryDiagnostics.deviceIdentifier {
                            do {
                                pairingRecord = try await pairingStore.markValidated(
                                    deviceIdentifier: deviceIdentifier
                                )
                                diagnosticState = .ready(deviceIdentifier: deviceIdentifier)
                                installDiagnostics = recoveryDiagnostics
                                try? await logStore?.append(
                                    category: .pairing,
                                    message: "上一份配对信息已恢复并重新验证成功"
                                )
                                logs = (try? await logStore?.entries()) ?? logs
                                refreshLogExportText()
                                return
                            } catch let restoreFailure as ImportFailure {
                                effectiveFailure = restoreFailure
                            } catch {
                                effectiveFailure = Self.failure(
                                    title: "配对恢复验证失败",
                                    reason: "上一份配对信息已恢复，但验证结果无法保存。",
                                    recovery: "重新检测",
                                    code: "SEAL-PAIR-210"
                                )
                            }
                        } else if let recoveryFailure = recoveryDiagnostics.failure {
                            effectiveFailure = recoveryFailure
                        }
                    }
                }
            } catch {
                effectiveFailure = Self.failure(
                    title: "配对恢复失败",
                    reason: "新配对信息不可用，且上一份配对信息未能自动恢复。",
                    recovery: "重新配对",
                    code: "SEAL-PAIR-209"
                )
                alertFailure = effectiveFailure
            }
        }
        if let pairingStore {
            do {
                if let deviceIdentifier = effectiveDiagnostics?.deviceIdentifier {
                    pairingRecord = try await pairingStore.markValidated(
                        deviceIdentifier: deviceIdentifier
                    )
                } else {
                    pairingRecord = try await pairingStore.markPendingValidation()
                }
            } catch {
                alertFailure = Self.failure(
                    title: "配对状态保存失败",
                    reason: "LocalDevVPN 检测失败后，配对状态未能写入本机存储。",
                    recovery: "重新配对设备后再检测",
                    code: "SEAL-PAIR-208b"
                )
            }
        }
        await load(force: true)
        if let effectiveDiagnostics { installDiagnostics = effectiveDiagnostics }
        diagnosticState = .failed(effectiveFailure)
        try? await logStore?.append(
            category: .installation,
            level: .error,
            message: "\(logMessage)｜\(effectiveFailure.title)｜\(effectiveFailure.reason)",
            code: effectiveFailure.code
        )
        logs = (try? await logStore?.entries()) ?? logs
        refreshLogExportText()
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        guard let notificationScheduler,
              let notificationPreferences,
              let appStore else { return }
        do {
            if enabled {
                let granted = try await notificationScheduler.requestAuthorization()
                guard granted else {
                    notificationPreferences.isEnabled = true
                    notificationsEnabled = true
                    notificationStatus = await notificationScheduler.status(sealEnabled: true)
                    throw Self.failure(
                        title: "通知未开启",
                        reason: "Seal 内提醒已开启，但系统没有授予通知权限。",
                        recovery: "检查系统通知权限",
                        code: "SEAL-NOTIFY-001"
                    )
                }
            }
            notificationPreferences.isEnabled = enabled
            notificationsEnabled = enabled
            try await notificationScheduler.reschedule(
                apps: try await appStore.fetchAll(),
                enabled: enabled,
                leadHours: reminderHours
            )
            notificationStatus = await notificationScheduler.status(sealEnabled: enabled)
        } catch let failure as ImportFailure {
            notificationStatus = await notificationScheduler.status(
                sealEnabled: notificationPreferences.isEnabled,
                schedulingFailure: failure.reason
            )
            alertFailure = failure
            try? await logStore?.append(category: .system, level: .error, message: failure.reason, code: failure.code)
        } catch {
            let failure = Self.failure(
                title: "无法设置提醒",
                reason: "通知调度失败，提醒未能更新。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "在系统设置中确认通知权限已开启后重试",
                code: "SEAL-NOTIFY-002a"
            )
            notificationStatus = await notificationScheduler.status(
                sealEnabled: notificationPreferences.isEnabled,
                schedulingFailure: failure.reason
            )
            alertFailure = failure
            try? await logStore?.append(category: .system, level: .error, message: failure.reason, code: failure.code)
        }
    }

    func setReminderHours(_ hours: Int) async {
        guard let notificationPreferences,
              let notificationScheduler,
              let appStore else { return }
        reminderHours = NotificationPreferences.fixedLeadHours
        notificationPreferences.leadHours = NotificationPreferences.fixedLeadHours
        do {
            try await notificationScheduler.reschedule(
                apps: try await appStore.fetchAll(),
                enabled: notificationsEnabled,
                leadHours: NotificationPreferences.fixedLeadHours
            )
            notificationStatus = await notificationScheduler.status(sealEnabled: notificationsEnabled)
        } catch {
            alertFailure = Self.failure(
                title: "无法设置提醒",
                reason: "通知配置失败，提醒时间未能更新。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "在系统设置中确认通知权限已开启后重试",
                code: "SEAL-NOTIFY-002b"
            )
        }
    }

    func refreshStorageUsage() async {
        guard let fileStore else {
            storageUsage = .empty
            return
        }
        do {
            let apps: [AppRecord]
            if let appStore {
                apps = (try? await appStore.fetchAll()) ?? []
            } else {
                apps = []
            }
            let history: [SigningHistoryRecord]
            if let signingHistoryStore {
                history = (try? await signingHistoryStore.records()) ?? []
            } else {
                history = []
            }
            storageUsage = try await fileStore.storageUsage(apps: apps, signingHistory: history)
        } catch {
            storageUsage = .empty
        }
    }

    func clearTemporaryFiles() async {
        guard let fileStore else { return }
        guard let operationLease = await acquireOperation(.maintainingStorage) else { return }
        defer { releaseOperation(operationLease) }
        do {
            try await fileStore.clearTemporaryFiles()
            await refreshStorageUsage()
            try? await logStore?.append(
                category: .system,
                message: "临时缓存与签名工作区已清理"
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
        } catch {
            alertFailure = Self.failure(
                title: "无法清理缓存",
                reason: "临时文件仍在使用，无法清理。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "稍后重试",
                code: "SEAL-STORAGE-001a"
            )
        }
    }

    func clearUnusedStorageFiles() async {
        guard let fileStore, let appStore else { return }
        guard let operationLease = await acquireOperation(.maintainingStorage) else { return }
        defer { releaseOperation(operationLease) }
        do {
            let apps = try await appStore.fetchAll()
            try await fileStore.clearTemporaryFiles()
            // 这里是用户主动清理，且整个清理期间持有 .maintainingStorage 租约
            // （OperationCoordinator 单槽 ⇒ 不会有并发导入新建目录），
            // 因此不需要「新建保护期」——用户就是要立刻把空间释放出来。
            try await fileStore.clearOrphanedAppFiles(
                validAppIDs: Set(apps.map(\.id)),
                minimumAge: 0
            )
            await refreshStorageUsage()
            try? await logStore?.append(
                category: .system,
                message: "临时缓存和未使用文件已清理；签名缓存、Apple ID 凭据和设备配对信息已保留"
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
        } catch {
            alertFailure = Self.failure(
                title: "无法清理未使用文件",
                reason: "部分文件仍在使用或本地记录无法读取。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "稍后重试",
                code: "SEAL-STORAGE-002"
            )
        }
    }

    func clearIPAAndSigningCache() async {
        await clearUnusedStorageFiles()
    }

    /// Legacy API retained for call-site compatibility.
    /// This now only clears transient workspaces.
    func clearSignedIPACache() async {
        await clearTemporaryFiles()
    }

    func clearLogs() async {
        guard let logStore else { return }
        do {
            try await logStore.clear()
            logs = []
            refreshLogExportText()
        } catch {
            alertFailure = Self.failure(
                title: "无法清理日志",
                reason: "日志文件仍在使用，无法清理。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-LOG-001"
            )
        }
    }

    func resetCertificate(for account: AppleAccountRecord) async {
        guard let accountRepository else { return }
        guard let operationLease = await acquireOperation(.managingCertificate) else { return }
        defer { releaseOperation(operationLease) }
        var updated = account
        updated.certificateSerialNumber = nil
        updated.selectedCertificateSerialNumber = nil
        do {
            try await accountRepository.save(updated)
            try await keychain?.clearSigningMaterial(accountID: account.id)
            certificateInventories[account.id] = nil
            await load(force: true)
            try? await logStore?.append(
                category: .account,
                message: "本地签名证书缓存已清除，下次签名会重新申请证书"
            )
            logs = (try? await logStore?.entries()) ?? logs
            refreshLogExportText()
        } catch {
            alertFailure = Self.failure(
                title: "无法更新证书",
                reason: "清除 \(account.maskedEmail) 的证书状态时，证书记录或 Keychain 缓存保存失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试；仍失败请重新验证 Apple ID",
                code: "SEAL-CERT-101"
            )
        }
    }

    private func acquireOperation(
        _ kind: OperationCoordinator.Kind,
        appID: UUID? = nil
    ) async -> OperationCoordinator.Lease? {
        guard let operationCoordinator else {
            return .uncoordinated(kind, appID: appID)
        }
        // 自动等待当前操作完成，不弹"暂时无法执行"弹窗
        return await operationCoordinator.beginWaiting(kind, appID: appID)
    }

    private func releaseOperation(_ lease: OperationCoordinator.Lease) {
        operationCoordinator?.end(lease)
    }

    private func refreshLogExportText() {
        logExportText = SealLogTextFormatter.exportText(logs)
    }

    static func preview() -> SettingsViewModel {
        let model = SettingsViewModel()
        model.accounts = [
            AppleAccountRecord(
                maskedEmail: "d***@icloud.com",
                accountIdentifier: "preview-account",
                teamID: "PREVIEWTEAM",
                teamName: "个人团队",
                isFreeTeam: true,
                status: .verified,
                certificateSerialNumber: "PREVIEW-CERTIFICATE",
                selectedCertificateSerialNumber: "PREVIEW-CERTIFICATE",
                lastVerifiedAt: Date()
            )
        ]
        model.activeAccountID = model.accounts.first?.id
        model.fullAccountEmails[model.accounts[0].id] = "demo@icloud.com"
        model.pairingRecord = PairingRecord(
            deviceIdentifier: "PREVIEW-DEVICE",
            isRemotePairing: true
        )
        return model
    }

    private static let localDevVPNUnavailableFailure = ImportFailure(
        title: "LocalDevVPN 未就绪",
        reason: "LocalDevVPN 未就绪。请先连接 Wi-Fi 并确认 LocalDevVPN 已连接。",
        recovery: "一键检测",
        code: "SEAL-INSTALL-706a"
    )


    private static func failure(
        title: String,
        reason: String,
        recovery: String,
        code: String
    ) -> ImportFailure {
        ImportFailure(
            title: title,
            reason: reason,
            recovery: recovery,
            code: code
        )
    }
}
