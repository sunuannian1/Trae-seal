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
        operationCoordinator: OperationCoordinator? = nil
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
              secret.certificateSerialNumber == serialNumber,
              secret.certificateP12 != nil else {
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
                try await persistVerificationFailure(.localCredentialsMissing, for: account)
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
                try await persistVerificationFailure(.localCredentialsMissing, for: account)
                throw Self.failure(
                    title: "无法撤销证书",
                    reason: "本机没有当前 Apple ID 的登录凭据。",
                    recovery: "重新验证 Apple ID",
                    code: "SEAL-AUTH-105c"
                )
            }

            try await applePortalCertificateService.revokeCertificate(
                serialNumber: serialNumber,
                account: account,
                secret: originalSecret
            )

            if originalSecret.certificateSerialNumber?.caseInsensitiveCompare(serialNumber) == .orderedSame {
                var clearedSecret = originalSecret
                clearedSecret.certificateP12 = nil
                clearedSecret.certificateSerialNumber = nil
                clearedSecret.certificateMachineIdentifier = nil
                var clearedAccount = account
                clearedAccount.certificateSerialNumber = nil
                clearedAccount.selectedCertificateSerialNumber = nil
                try await keychain.save(clearedSecret, for: account.id)
                try await accountRepository.save(clearedAccount)
            }

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

    func revokeCertificateAndCreateLocal(
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
                try await persistVerificationFailure(.localCredentialsMissing, for: account)
                throw Self.failure(
                    title: "无法更换证书",
                    reason: "本机没有当前 Apple ID 的登录凭据。",
                    recovery: "重新验证 Apple ID",
                    code: "SEAL-AUTH-105d"
                )
            }

            try await applePortalCertificateService.revokeCertificate(
                serialNumber: serialNumber,
                account: account,
                secret: originalSecret
            )

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
                        // 当前账号架构只保存一份本地 P12，因此可选证书必须
                        // 与这份私钥严格一致，避免界面显示旧 Serial。
                        if account.selectedCertificateSerialNumber != serial {
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
                message: "Apple App ID 已同步：\(merged.usedBundleIDCount) 个可用 App ID"
            )
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

    func refreshCertificateInventory(
        for account: AppleAccountRecord,
        force: Bool = true
    ) async {
        guard let keychain, let applePortalInventoryService else { return }
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
        let expirationDate = portalCertificate?.expirationDate ?? localValidity?.notAfter

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

        let normalizedSerial = serial.filter(\.isHexDigit).uppercased()
        let usableAppIDCount = Set(relatedApps.compactMap { app -> String? in
            let signedBundleID = app.mappedBundleIdentifier ?? app.preferredBundleIdentifier ?? app.originalBundleIdentifier
            guard let deviceID = app.signedDeviceIdentifier, deviceID.isEmpty == false else { return nil }
            guard app.signingTargets.contains(where: { target in
                target.bundleIdentifier.caseInsensitiveCompare(signedBundleID) == .orderedSame
                    && target.teamIdentifier.caseInsensitiveCompare(account.teamID) == .orderedSame
                    && target.profileExpirationDate > Date()
                    && target.deviceIdentifiers.contains(where: { $0.caseInsensitiveCompare(deviceID) == .orderedSame })
                    && target.certificateSerialNumbers.contains(where: { $0.filter(\.isHexDigit).uppercased() == normalizedSerial })
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
                recovery: "确认该 Apple ID 已注册开发者账号（免费账号即可），或更换其他 Apple ID",
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
        var mergedSecret = authenticated.secret
        if let previousSecret,
           previousSecret.accountIdentifier == authenticated.secret.accountIdentifier {
            mergedSecret.certificateP12 = previousSecret.certificateP12
            mergedSecret.certificateSerialNumber = previousSecret.certificateSerialNumber
            mergedSecret.certificateMachineIdentifier = previousSecret.certificateMachineIdentifier
        }
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
    /// 支持 iOS 17+ RemotePairing（.mobiledevicepairing / JSON）和 iOS 17- Lockdown（.plist）。
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
                try await persistVerificationFailure(.localCredentialsMissing, for: account)
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
                // 不标记 ID 失效：添加后永久保留，只抛出错误提示
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
    ) async throws {
        // 不标记 ID 失效：添加后永久保留，只记录日志
        // 调用方会抛出对应错误提示用户
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

    func testSealTunnelChannel() async {
        await load(force: true)
        guard diagnosticState != .running, let installChannel else { return }
        guard pairingRecord != nil else {
            diagnosticState = .failed(
                Self.failure(
                    title: "尚未配对",
                    reason: "验证 Seal 内置通道前，需要先完成当前 iPhone 的首次配对。",
                    recovery: "使用 Seal 配对助手完成首次配对",
                    code: "SEAL-TUNNEL-001"
                )
            )
            return
        }

        diagnosticState = .running
        let diagnostics = await installChannel.diagnose()
        installDiagnostics = diagnostics

        if diagnostics.isReady, let deviceIdentifier = diagnostics.deviceIdentifier {
            diagnosticState = .ready(deviceIdentifier: deviceIdentifier)
            try? await logStore?.append(
                category: .installation,
                message: "LocalDevVPN 已通过验证"
            )
        } else {
            let failure = diagnostics.failure ?? Self.failure(
                title: "LocalDevVPN 不可用",
                reason: "LocalDevVPN 已开启，但当前状态尚未就绪。",
                recovery: "重新验证 LocalDevVPN",
                code: "SEAL-TUNNEL-002"
            )
            diagnosticState = .failed(failure)
            try? await logStore?.append(
                category: .installation,
                level: .error,
                message: "LocalDevVPN 验证失败",
                code: failure.code
            )
        }

        logs = (try? await logStore?.entries()) ?? logs
        refreshLogExportText()
    }

    private func runInstallChannelCheck(successMessage: String) async {
        guard let installChannel else { return }
        diagnosticState = .running
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
            try await fileStore.clearOrphanedAppFiles(validAppIDs: Set(apps.map(\.id)))
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
        let formatter = ISO8601DateFormatter()
        logExportText = logs.map { entry in
            let code = entry.code.map { " [\($0)]" } ?? ""
            return "\(formatter.string(from: entry.timestamp)) \(entry.level.rawValue.uppercased()) \(entry.category.rawValue)\(code) \(entry.message)"
        }.joined(separator: "\n")
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
