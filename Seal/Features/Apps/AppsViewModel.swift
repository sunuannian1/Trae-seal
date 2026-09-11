import Combine
import Foundation
@preconcurrency import Minimuxer

@MainActor
final class AppsViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case committing
    }

    enum SigningChannelStatus: Equatable {
        case idle
        case connecting
        case ready
        case unavailable
    }

    @Published private(set) var apps: [AppRecord]
    @Published private(set) var accounts: [AppleAccountRecord]
    @Published private(set) var fullAccountEmails: [UUID: String] = [:]
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var iconData: [UUID: Data]
    @Published private(set) var phase: Phase
    @Published var isImporterPresented = false
    @Published var isImportSheetPresented: Bool
    @Published private(set) var sheetDraft: ImportDraft?
    @Published private(set) var sheetFailure: ImportFailure?
    @Published var alertFailure: ImportFailure?
    @Published var accountSelectionApp: AppRecord?
    @Published var selectedOperationApp: AppRecord?
    @Published var signingSession: SigningSession?
    @Published var batchRefreshSession: BatchRefreshSession?
    @Published private(set) var importCompletionCount = 0
    @Published private(set) var lastImportCompletedInstalledApp = false
    @Published var shouldOpenSettings = false
    @Published var requestedSettingsRoute: SettingsRoute?
    @Published private(set) var signingChannelStatus: SigningChannelStatus = .idle
    @Published private(set) var installingCachedPackageAppID: UUID?

    private let workflow: ImportWorkflow?
    private let appStore: (any AppStore)?
    private let fileStore: AppFileStore?
    private let accountRepository: (any AccountRepository)?
    private let keychain: KeychainVault?
    private let signingCoordinator: SigningCoordinator?
    private let installChannel: (any InstallChannel)?
    private let renewalCoordinator: RenewalCoordinator?
    private let appRecordRecovery: AppRecordRecovery?
    private let selfAppRegistrar: SelfAppRegistrar?
    private let logStore: SealLogStore?
    private let signingHistoryStore: SigningHistoryStore?
    private let notificationScheduler: ExpiryNotificationScheduler?
    private let notificationPreferences: NotificationPreferences?
    private let signingPreferenceStore: SigningPreferenceStore?
    private let operationCoordinator: OperationCoordinator?
    let signingVerificationBroker: VerificationCodeBroker
    private var signingTask: Task<Void, Never>?
    private var batchRefreshTask: Task<Void, Never>?
    private var channelTask: Task<Bool, Never>?
    private var pendingVPNAction: PendingVPNAction?
    private var hasLoaded = false
    private var loadGeneration = 0
    // 自更新下载导入完成后，自动打开签名抽屉（仅 Seal 自身更新触发）
    private var autoOpenSigningAfterImport = false

    private enum PendingVPNAction {
        case signing(
            AppRecord,
            accountID: UUID?,
            requestedBundleIdentifier: String?,
            completionMode: SigningCompletionMode
        )
        case batch
    }

    init(
        workflow: ImportWorkflow,
        appStore: any AppStore,
        fileStore: AppFileStore,
        accountRepository: any AccountRepository,
        keychain: KeychainVault,
        signingCoordinator: SigningCoordinator,
        installChannel: any InstallChannel,
        renewalCoordinator: RenewalCoordinator,
        appRecordRecovery: AppRecordRecovery,
        selfAppRegistrar: SelfAppRegistrar?,
        logStore: SealLogStore,
        signingHistoryStore: SigningHistoryStore,
        notificationScheduler: ExpiryNotificationScheduler,
        notificationPreferences: NotificationPreferences,
        signingPreferenceStore: SigningPreferenceStore,
        operationCoordinator: OperationCoordinator? = nil,
        signingVerificationBroker: VerificationCodeBroker
    ) {
        self.workflow = workflow
        self.appStore = appStore
        self.fileStore = fileStore
        self.accountRepository = accountRepository
        self.keychain = keychain
        self.signingCoordinator = signingCoordinator
        self.installChannel = installChannel
        self.renewalCoordinator = renewalCoordinator
        self.appRecordRecovery = appRecordRecovery
        self.selfAppRegistrar = selfAppRegistrar
        self.logStore = logStore
        self.signingHistoryStore = signingHistoryStore
        self.notificationScheduler = notificationScheduler
        self.notificationPreferences = notificationPreferences
        self.signingPreferenceStore = signingPreferenceStore
        self.operationCoordinator = operationCoordinator
        self.signingVerificationBroker = signingVerificationBroker
        apps = []
        accounts = []
        iconData = [:]
        phase = .idle
        isImportSheetPresented = false
    }

    init(startupFailure: ImportFailure) {
        self.signingVerificationBroker = VerificationCodeBroker()
        workflow = nil
        appStore = nil
        fileStore = nil
        accountRepository = nil
        keychain = nil
        signingCoordinator = nil
        installChannel = nil
        renewalCoordinator = nil
        appRecordRecovery = nil
        selfAppRegistrar = nil
        logStore = nil
        signingHistoryStore = nil
        notificationScheduler = nil
        notificationPreferences = nil
        signingPreferenceStore = nil
        operationCoordinator = nil
        apps = []
        accounts = []
        iconData = [:]
        phase = .idle
        isImportSheetPresented = false
        alertFailure = startupFailure
    }

    private init(apps: [AppRecord], draft: ImportDraft?) {
        self.signingVerificationBroker = VerificationCodeBroker()
        alertFailure = nil
        workflow = nil
        appStore = nil
        fileStore = nil
        accountRepository = nil
        keychain = nil
        signingCoordinator = nil
        installChannel = nil
        renewalCoordinator = nil
        appRecordRecovery = nil
        selfAppRegistrar = nil
        logStore = nil
        signingHistoryStore = nil
        notificationScheduler = nil
        notificationPreferences = nil
        signingPreferenceStore = nil
        operationCoordinator = nil
        self.apps = apps
        accounts = []
        iconData = [:]
        phase = .idle
        sheetDraft = draft
        isImportSheetPresented = draft != nil
        hasLoaded = true
    }

    var unsignedApps: [AppRecord] {
        let installedKeys = installedAppIdentityKeys
        return apps
            .filter(\.belongsInUnsignedList)
            .filter { $0.userIdentityKeys.isDisjoint(with: installedKeys) }
            .sorted { lhs, rhs in
                if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }


    private var installedAppIdentityKeys: Set<String> {
        apps
            .filter(\.belongsInInstalledList)
            .reduce(into: Set<String>()) { result, app in
                result.formUnion(app.userIdentityKeys)
            }
    }

    var installedApps: [AppRecord] {
        apps.filter(\.belongsInInstalledList)
            .sorted { lhs, rhs in
                if lhs.isSeal != rhs.isSeal { return lhs.isSeal }
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }

                let lhsRank = installedSortRank(for: lhs)
                let rhsRank = installedSortRank(for: rhs)
                if lhsRank != rhsRank { return lhsRank > rhsRank }

                let lhsExpiry = lhs.expiryDate ?? .distantPast
                let rhsExpiry = rhs.expiryDate ?? .distantPast
                if lhsExpiry != rhsExpiry { return lhsExpiry > rhsExpiry }

                if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var hasPendingVPNRecovery: Bool {
        pendingVPNAction != nil
    }

    var isBatchRefreshActive: Bool {
        batchRefreshTask != nil
    }

    var availableAccounts: [AppleAccountRecord] {
        accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
    }

    // Kept for existing call sites; locally available accounts remain selectable
    // while offline even if a fresh Portal validation has not run yet.
    var verifiedAccounts: [AppleAccountRecord] { availableAccounts }

    func selectActiveAccount(id: UUID) async {
        guard availableAccounts.contains(where: { $0.id == id }) else { return }
        activeAccountID = id
        await signingPreferenceStore?.setActiveAccountID(id)
    }

    func refreshActiveAccountSelection() async {
        guard let signingPreferenceStore else { return }
        let storedID = await signingPreferenceStore.activeAccountID()
        if let storedID, accounts.contains(where: { $0.id == storedID }) {
            activeAccountID = storedID
        } else if let current = activeAccountID, accounts.contains(where: { $0.id == current }) {
            // Keep the in-memory choice. Do not clear it because connectivity changed.
        } else if activeAccountID == nil {
            activeAccountID = availableAccounts.first?.id
            if storedID == nil {
                await signingPreferenceStore.setActiveAccountID(activeAccountID)
            }
        }
    }

    private func installedSortRank(for app: AppRecord, now: Date = Date()) -> Int {
        guard let expiryDate = app.expiryDate else { return 1 }
        return expiryDate > now ? 2 : 0
    }

    func presentOperation(for app: AppRecord) {
        selectedOperationApp = app
    }

    func dismissOperation() {
        guard signingTask == nil else { return }
        selectedOperationApp = nil
        signingSession = nil
    }

    func beginRenewalDirectly(for app: AppRecord, overrideAccountID: UUID? = nil) async {
        guard app.belongsInInstalledList else {
            presentOperation(for: app)
            return
        }
        // 选择优先级：用户手动覆盖 > 记录账号 > Seal 按 Team 匹配 > 当前活跃账号 > 第一个可选账号
        let accountID: UUID
        if let overrideAccountID,
           accounts.contains(where: { $0.id == overrideAccountID && AccountAvailabilityPolicy.isSelectable($0) }) {
            accountID = overrideAccountID
        } else if let recordedAccountID = app.accountID {
            accountID = recordedAccountID
        } else if app.isSeal, let teamID = app.signingTeamID,
                  let matchedID = accounts.first(where: {
                      $0.teamID.caseInsensitiveCompare(teamID) == .orderedSame
                          && AccountAvailabilityPolicy.isSelectable($0)
                  })?.id {
            accountID = matchedID
        } else if let activeID = activeAccountID, accounts.contains(where: { $0.id == activeID && AccountAvailabilityPolicy.isSelectable($0) }) {
            accountID = activeID
        } else if let fallbackID = accounts.first(where: { AccountAvailabilityPolicy.isSelectable($0) })?.id {
            accountID = fallbackID
        } else {
            alertFailure = ImportFailure(
                title: "缺少签名账号",
                reason: "尚未添加可用的 Apple ID，无法续签。",
                recovery: "在「我的」中添加 Apple ID",
                code: "SEAL-AUTH-104"
            )
            return
        }
        await beginSigning(
            for: app,
            accountID: accountID,
            requestedBundleIdentifier: nil,
            completionMode: .signAndInstall
        )
        if signingSession?.app.id == app.id {
            selectedOperationApp = signingSession?.app ?? app
        }
    }

    @discardableResult
    func refreshSigningChannel() async -> Bool {
        if let channelTask {
            return await channelTask.value
        }
        guard let installChannel else {
            signingChannelStatus = .unavailable
            return false
        }

        signingChannelStatus = .connecting
        let task = Task {
            do {
                _ = try await installChannel.start()
                return true
            } catch {
                return false
            }
        }
        channelTask = task
        let ready = await task.value
        channelTask = nil
        signingChannelStatus = ready ? .ready : .unavailable
        return ready
    }

    func load(force: Bool = false) async {
        guard force || hasLoaded == false, let appStore else { return }
        loadGeneration &+= 1
        let generation = loadGeneration

        do {
            // 优化：先快速显示数据，自注册等耗时操作移到后台
            try await appRecordRecovery?.restoreMissingRecords()
            guard generation == loadGeneration else { return }

            let fetched = try await appStore.fetchAll()
            guard generation == loadGeneration else { return }

            var fetchedAccounts = try await accountRepository?.fetchAll() ?? []
            guard generation == loadGeneration else { return }
            fetchedAccounts = try await repairLegacyAccountStatuses(fetchedAccounts)
            guard generation == loadGeneration else { return }

            let preferredAccountID: UUID?
            if let signingPreferenceStore {
                preferredAccountID = await signingPreferenceStore.activeAccountID()
            } else {
                preferredAccountID = nil
            }
            guard generation == loadGeneration else { return }

            let selectableAccounts = fetchedAccounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
            let resolvedAccountID: UUID?
            if let preferredAccountID, fetchedAccounts.contains(where: { $0.id == preferredAccountID }) {
                resolvedAccountID = preferredAccountID
            } else if let current = activeAccountID, fetchedAccounts.contains(where: { $0.id == current }) {
                resolvedAccountID = current
            } else {
                resolvedAccountID = selectableAccounts.first?.id
                if preferredAccountID == nil {
                    await signingPreferenceStore?.setActiveAccountID(resolvedAccountID)
                }
            }

            // 快速显示应用列表
            apps = fetched
            accounts = fetchedAccounts
            activeAccountID = resolvedAccountID
            hasLoaded = true
            restorePendingBatchResultIfNeeded()

            // 后台执行耗时操作
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }

                // Seal 自身注册后，重新获取最新数据，确保后续操作用最新列表
                var latestApps = fetched
                if let selfAppRegistrar = self.selfAppRegistrar {
                    do {
                        try await selfAppRegistrar.ensureRegistered()
                        if let refreshed = try? await self.appStore?.fetchAll() {
                            latestApps = refreshed
                            await MainActor.run { self.apps = refreshed }
                        }
                    } catch {
                        try? await self.logStore?.append(category: .system, level: .error, message: "Seal 自身记录同步失败", code: "SEAL-SELF-REG-001")
                    }
                }

                // 用最新数据清理孤儿文件，避免误删新创建的 Seal 文件夹
                if let fileStore = self.fileStore {
                    try? await fileStore.clearOrphanedAppFiles(validAppIDs: Set(latestApps.map { $0.id }))
                }

                let emails = await self.loadFullAccountEmails(for: fetchedAccounts)
                await MainActor.run { self.fullAccountEmails = emails }

                // 用最新数据加载图标
                var icons: [UUID: Data] = [:]
                if let fileStore = self.fileStore {
                    for app in latestApps {
                        guard let path = app.displayIconRelativePath,
                              let data = try? await fileStore.read(relativePath: path) else { continue }
                        icons[app.id] = data
                    }
                }
                await MainActor.run { self.iconData = icons }

                await self.seedSigningHistoryIfNeeded(apps: latestApps, accounts: fetchedAccounts)

                // 用最新数据调度通知
                if let notificationScheduler = self.notificationScheduler,
                   let notificationPreferences = self.notificationPreferences {
                    do {
                        try await notificationScheduler.reschedule(apps: latestApps, enabled: notificationPreferences.isEnabled, leadHours: notificationPreferences.leadHours)
                    } catch {
                        try? await self.logStore?.append(category: .system, level: .error, message: "通知调度失败", code: "SEAL-NOTIFY-002a")
                    }
                }
            }
        } catch let failure as ImportFailure {
            guard generation == loadGeneration else { return }
            alertFailure = failure
        } catch {
            guard generation == loadGeneration else { return }
            alertFailure = ImportFailure(
                title: "无法读取应用",
                reason: "本地应用数据读取失败，应用列表无法加载。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-APP-002"
            )
        }
    }

    func fullEmail(for account: AppleAccountRecord) -> String {
        fullAccountEmails[account.id] ?? "未记录"
    }

    private func loadFullAccountEmails(
        for accounts: [AppleAccountRecord]
    ) async -> [UUID: String] {
        guard let keychain else { return [:] }
        var values: [UUID: String] = [:]
        for account in accounts {
            guard let secret = try? await keychain.load(accountID: account.id) else { continue }
            values[account.id] = secret.email
        }
        return values
    }

    func performLightweightLaunchCheck() async {
        await load(force: true)
    }

    func refreshUnsignedApps() async {
        await load(force: true)
    }

    func refreshInstalledApps(userInitiated: Bool = true) async {
        await load(force: true)
        await reconcileInstalledAppsWithDevice(userInitiated: userInitiated)
    }

    private func reconcileInstalledAppsWithDevice(userInitiated: Bool) async {
        let installedRecords = installedApps
        guard installedRecords.isEmpty == false else { return }

        // 导入与已安装 IPA 相同（签名后的 Bundle ID 一致）会残留多条相同身份的记录，
        // iOS 无法并存同 Bundle ID 的应用，这里按身份合并去重，只保留真实存在的一条。
        await removeDuplicateInstalledRecords(installedRecords)

        do {
            for app in installedRecords {
                guard let bundleIdentifier = installedBundleIdentifier(for: app) else { continue }

                let existsOnDevice = try await InstalledAppDeviceVerifier.isInstalled(
                    bundleIdentifier: bundleIdentifier
                )

                if existsOnDevice == false {
                    _ = await delete(app)
                }
            }
        } catch {
            if userInitiated {
                alertFailure = ImportFailure(
                    title: "\u{65E0}\u{6CD5}\u{5237}\u{65B0}\u{5DF2}\u{5B89}\u{88C5}\u{5E94}\u{7528}",
                    reason: "\u{672A}\u{80FD}\u{4ECE}\u{8BBE}\u{5907}\u{8BFB}\u{53D6}\u{771F}\u{5B9E}\u{5DF2}\u{5B89}\u{88C5}\u{5E94}\u{7528}\u{72B6}\u{6001}\u{3002}",
                    recovery: "\u{91CD}\u{65B0}\u{8FDE}\u{63A5}\u{624B}\u{673A}\u{5E76}\u{5B8C}\u{6210}\u{914D}\u{5BF9}\u{540E}\u{91CD}\u{8BD5}",
                    code: "SEAL-INSTALL-707"
                )
            }
        }
    }

    private func installedBundleIdentifier(for app: AppRecord) -> String? {
        if let mapped = app.mappedBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           mapped.isEmpty == false {
            return mapped
        }
        if let preferred = app.preferredBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           preferred.isEmpty == false {
            return preferred
        }
        return nil
    }

    /// 合并本机已安装列表中「签名后 Bundle ID 相同」的重复记录，只保留最可信的一条，
    /// 删除其余重复记录及其文件夹。仅处理非 Seal 的第三方应用；Seal 自身由 SelfAppRegistrar 管理。
    private func removeDuplicateInstalledRecords(_ records: [AppRecord]) async {
        var bestByBundle: [String: AppRecord] = [:]
        var duplicates: [AppRecord] = []
        for record in records where record.isSeal == false {
            guard let bundle = installedBundleIdentifier(for: record)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  bundle.isEmpty == false else {
                continue
            }
            if let existing = bestByBundle[bundle] {
                if preferKeeping(record, over: existing) {
                    duplicates.append(existing)
                    bestByBundle[bundle] = record
                } else {
                    duplicates.append(record)
                }
            } else {
                bestByBundle[bundle] = record
            }
        }
        for duplicate in duplicates {
            _ = await delete(duplicate)
        }
    }

    private func preferKeeping(_ lhs: AppRecord, over rhs: AppRecord) -> Bool {
        if lhs.hasSignedArtifact != rhs.hasSignedArtifact {
            return lhs.hasSignedArtifact
        }
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned
        }
        // 设备上只有一个应用，保留 state == .installed 的那条更接近真实状态。
        if lhs.state == .installed && rhs.state != .installed { return true }
        if rhs.state == .installed && lhs.state != .installed { return false }
        let lhsDate = lhs.lastInstalledAt ?? lhs.importedAt
        let rhsDate = rhs.lastInstalledAt ?? rhs.importedAt
        return lhsDate >= rhsDate
    }

    private func seedSigningHistoryIfNeeded(
        apps: [AppRecord],
        accounts: [AppleAccountRecord]
    ) async {
        guard let signingHistoryStore else { return }
        let existingRecords: [SigningHistoryRecord]
        do {
            existingRecords = try await signingHistoryStore.records()
        } catch {
            surfaceHistoryWarning(
                title: "签名历史读取失败",
                reason: "无法读取历史记录，已跳过本次历史回填。",
                code: "SEAL-HISTORY-004"
            )
            return
        }
        let existingKeys = Set(
            existingRecords.compactMap { record -> String? in
                guard let appID = record.appID else { return nil }
                return "\(record.accountID.uuidString)-\(appID.uuidString)"
            }
        )

        for app in apps where app.belongsInInstalledList {
            guard let accountID = app.accountID,
                  let account = accounts.first(where: { $0.id == accountID }) else {
                continue
            }
            let key = "\(accountID.uuidString)-\(app.id.uuidString)"
            guard existingKeys.contains(key) == false else { continue }
            let record = SigningHistoryRecord(
                app: app,
                account: account,
                action: .imported,
                result: .success,
                signedAt: app.importedAt,
                attemptedBundleIdentifier: app.preferredBundleIdentifier,
                finalSignedBundleIdentifier: app.mappedBundleIdentifier,
                lifecycleStatus: .active
            )
            do {
                try await signingHistoryStore.append(record)
            } catch {
                surfaceHistoryWarning(
                    title: "签名历史回填未完成",
                    reason: "部分已有应用的历史记录无法保存。",
                    code: "SEAL-HISTORY-004a"
                )
                return
            }
        }
    }

    func presentImporter() {
        guard phase == .idle else { return }
        isImporterPresented = true
    }

    func importSelectedFile(_ url: URL) async {
        await importSelectedFile(url, autoOpenSigning: false)
    }

    /// 应用内更新下载完成后导入 Seal 自身 IPA，成功后自动打开签名抽屉覆盖安装。
    func importSelfUpdateFile(_ url: URL) async {
        await importSelectedFile(url, autoOpenSigning: true)
    }

    private func importSelectedFile(_ url: URL, autoOpenSigning: Bool) async {
        guard let workflow, phase == .idle else { return }
        guard let operationLease = await acquireOperation(.importing) else { return }
        defer { releaseOperation(operationLease) }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        alertFailure = nil
        sheetFailure = nil
        isImportSheetPresented = false
        autoOpenSigningAfterImport = autoOpenSigning
        phase = .preparing
        await workflow.prepare(sourceURL: url)
        await consumeWorkflowState()
    }

    func confirmImport() async {
        guard let workflow else { return }
        guard let operationLease = await acquireOperation(.importing) else { return }
        defer { releaseOperation(operationLease) }
        guard let draft = sheetDraft else {
            sheetFailure = ImportFailure(
                title: "无法导入 IPA",
                reason: "导入确认信息已失效，请重新选择 IPA。",
                recovery: "重新选择",
                code: "SEAL-IPA-211"
            )
            isImportSheetPresented = true
            phase = .idle
            return
        }

        phase = .committing
        sheetFailure = nil
        isImportSheetPresented = true
        await workflow.confirm(preferredDraft: draft)
        await consumeWorkflowState()
    }

    func retryImport() async {
        guard let workflow, sheetDraft != nil else { return }
        guard let operationLease = await acquireOperation(.importing) else { return }
        defer { releaseOperation(operationLease) }
        phase = .committing
        sheetFailure = nil
        await workflow.retry()
        await consumeWorkflowState()
    }

    func cancelImport() async {
        var cleanupFailure: ImportFailure?
        if let workflow {
            await workflow.cancel()
            cleanupFailure = await workflow.takeCleanupFailure()
        }
        sheetDraft = nil
        sheetFailure = nil
        isImportSheetPresented = false
        phase = .idle
        if let cleanupFailure {
            alertFailure = cleanupFailure
        }
    }

    func handleImporterFailure(_ error: Error) {
        let cocoaError = error as? CocoaError
        guard cocoaError?.code != .userCancelled else { return }
        alertFailure = ImportFailure(
            title: "无法选择 IPA",
            reason: "文件选择失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
            recovery: "重试",
            code: "SEAL-IPA-206"
        )
    }

    func performAlertRecovery(for failure: ImportFailure) {
        alertFailure = nil
        let recovery = failure.recovery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recovery != "知道了" else { return }
        if failure.code.hasPrefix("SEAL-IPA-") {
            presentImporter()
        } else if let route = settingsRoute(for: failure) {
            openSettings(route: route)
        }
    }

    func openSettings(route: SettingsRoute) {
        requestedSettingsRoute = route
        shouldOpenSettings = true
    }

    func requestSigning(for app: AppRecord) async {
        guard signingTask == nil, batchRefreshTask == nil else { return }
        await load(force: true)
        let availableAccounts = accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
        guard availableAccounts.isEmpty == false else {
            alertFailure = ImportFailure(
                title: "缺少签名账号",
                reason: accounts.isEmpty ? "尚未添加 Apple ID" : "Apple ID 需要重新验证",
                recovery: "前往设置",
                code: "SEAL-AUTH-104a"
            )
            return
        }

        // 宽松策略：已安装应用没有记录签名账号时，不拒绝，让用户选择账号进行续签
        continueSigningRequest(for: app, availableAccounts: availableAccounts)
    }

    func beginSigning(
        for app: AppRecord,
        accountID: UUID,
        requestedBundleIdentifier: String? = nil,
        completionMode: SigningCompletionMode = .signAndInstall
    ) async {
        guard signingTask == nil, batchRefreshTask == nil else { return }
        let isRenewal = app.belongsInInstalledList
        // 宽松策略：续签时优先用应用记录的账号，没有则用传入的账号
        let resolvedAccountID = (isRenewal ? app.accountID : nil) ?? accountID
        guard let account = verifiedAccounts.first(where: { $0.id == resolvedAccountID }) else {
            alertFailure = ImportFailure(
                title: "Apple ID 不可用",
                reason: isRenewal ? "请选择一个已验证的 Apple ID 进行续签。" : "请选择一个已验证的 Apple ID",
                recovery: "前往设置",
                code: "SEAL-AUTH-104b"
            )
            return
        }

        if isRenewal == false {
            await selectActiveAccount(id: account.id)
        }
        startSigning(
            app: app,
            account: account,
            requestedBundleIdentifier: isRenewal ? nil : requestedBundleIdentifier,
            completionMode: completionMode
        )
    }

    private func continueSigningRequest(
        for app: AppRecord,
        availableAccounts: [AppleAccountRecord]
    ) {
        if app.belongsInInstalledList {
            guard let accountID = app.accountID,
                  let account = availableAccounts.first(where: { $0.id == accountID }) else {
                alertFailure = ImportFailure(
                    title: "签名账号不可用",
                reason: "上次签名这个应用的 Apple ID 已被删除或凭据失效。",
                recovery: "在「我的」中重新添加原 Apple ID，或用当前账号重新签名安装",
                    code: "SEAL-AUTH-104c"
                )
                return
            }
            startSigning(app: app, account: account)
        } else if let activeAccountID,
                  let account = availableAccounts.first(where: { $0.id == activeAccountID }) {
            startSigning(app: app, account: account)
        } else if availableAccounts.count == 1, let account = availableAccounts.first {
            startSigning(app: app, account: account)
        } else {
            accountSelectionApp = app
        }
    }

    func resumePendingVPNAction() async {
        guard let action = pendingVPNAction else {
            _ = await refreshSigningChannel()
            return
        }
        alertFailure = nil
        guard await refreshSigningChannel() else {
            presentVPNRecovery(for: action)
            return
        }
        pendingVPNAction = nil
        switch action {
        case .signing(
            let app,
            let accountID,
            let requestedBundleIdentifier,
            let completionMode
        ):
            if let accountID {
                await beginSigning(
                    for: app,
                    accountID: accountID,
                    requestedBundleIdentifier: requestedBundleIdentifier,
                    completionMode: completionMode
                )
            } else {
                await requestSigning(for: app)
            }
        case .batch:
            startBatchRefresh()
        }
    }

    func cancelPendingVPNRecovery() {
        pendingVPNAction = nil
        alertFailure = nil
    }

    func selectAccount(_ account: AppleAccountRecord, for app: AppRecord) {
        accountSelectionApp = nil
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard Task.isCancelled == false else { return }
            await self?.selectActiveAccount(id: account.id)
            self?.startSigning(app: app, account: account)
        }
    }

    func chooseAnotherAccount(for app: AppRecord) async {
        await load(force: true)
        guard accounts.contains(where: { AccountAvailabilityPolicy.isSelectable($0) }) else {
            alertFailure = ImportFailure(
                title: "缺少签名账号",
                reason: accounts.isEmpty ? "尚未添加 Apple ID" : "Apple ID 需要重新验证",
                recovery: "前往设置",
                code: "SEAL-AUTH-104d"
            )
            return
        }
        accountSelectionApp = app
    }

    func retrySigning() {
        guard let session = signingSession else { return }
        restartSigning(
            session,
            allowDroppingExtensions: session.allowsDroppingExtensions
        )
    }

    /// 用户已在 Lara 完成 3-App Bypass 后继续签名：跳过免费账号设备上限预检，
    /// 交回 installd 最终裁决（未真正绕过时 installd 仍会拒绝并落到 iOS 拒绝分支）。
    func continueBypassingDeviceLimit() {
        guard let session = signingSession else { return }
        restartSigning(
            session,
            allowDroppingExtensions: session.allowsDroppingExtensions,
            bypassFreeAccountDeviceLimit: true
        )
    }

    func retryWithoutExtensions() {
        guard let session = signingSession else { return }
        restartSigning(
            session,
            allowDroppingExtensions: true
        )
    }


    func cancelSigning() {
        signingTask?.cancel()
        signingSession = nil
        selectedOperationApp = nil
    }

    func dismissSigningResult() {
        guard let signingSession else { return }
        if case .running = signingSession.status { return }
        self.signingSession = nil
        selectedOperationApp = nil
    }

    @discardableResult
    func updatePreferredBundleIdentifier(for app: AppRecord, value: String) async -> Bool {
        guard let appStore, BundleIDPolicy.isEditable(app) else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validationError = BundleIDPolicy.validationError(for: trimmed) {
            alertFailure = ImportFailure(
                title: "Bundle ID 无效",
                reason: validationError,
                recovery: "修改 Bundle ID",
                code: "SEAL-BUNDLE-001a"
            )
            return false
        }
        do {
            var updated = app
            updated.preferredBundleIdentifier = trimmed
            try await appStore.save(updated)
            await load(force: true)
            return true
        } catch {
            alertFailure = ImportFailure(
                title: "无法保存 Bundle ID",
                reason: "Bundle ID 草稿保存失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-BUNDLE-003"
            )
            return false
        }
    }

    @discardableResult
    func updatePreferredDisplayName(for app: AppRecord, name: String) async -> Bool {
        guard let appStore, app.state != .installed, app.hasSignedArtifact == false else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            alertFailure = ImportFailure(
                title: "App 名称无效",
                reason: "App 名称不能为空。",
                recovery: "修改 App 名称",
                code: "SEAL-CUSTOM-001"
            )
            return false
        }
        do {
            var updated = app
            updated.preferredDisplayName = trimmed == app.name ? nil : trimmed
            try await appStore.save(updated)
            await load(force: true)
            return true
        } catch {
            alertFailure = ImportFailure(
                title: "无法保存 App 名称",
                reason: "App 名称记录保存失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-CUSTOM-002"
            )
            return false
        }
    }

    @discardableResult
    func updatePreferredIcon(for app: AppRecord, data: Data?) async -> Bool {
        guard let appStore, let fileStore, app.state != .installed, app.hasSignedArtifact == false else { return false }
        do {
            var updated = app
            if let data {
                updated.preferredIconRelativePath = try await fileStore.storePreferredIcon(data: data, appID: app.id)
            } else {
                try await fileStore.removePreferredIcon(appID: app.id)
                updated.preferredIconRelativePath = nil
            }
            try await appStore.save(updated)
            if let path = updated.displayIconRelativePath,
               let data = try? await fileStore.read(relativePath: path) {
                iconData[updated.id] = data
            } else {
                iconData[updated.id] = nil
            }
            await load(force: true)
            return true
        } catch {
            alertFailure = ImportFailure(
                title: "无法保存 App 图标",
                reason: "图标文件无法写入本机存储。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-CUSTOM-003"
            )
            return false
        }
    }

    func retryInstallationForCurrentSigningSession() async {
        guard let session = signingSession else { return }
        await load(force: true)
        guard let signedApp = apps.first(where: { $0.id == session.app.id && $0.hasSignedArtifact }) else {
            alertFailure = ImportFailure(
                title: "无法重新安装",
                reason: "本机没有可用于安装的签名包。",
                recovery: "重新签名",
                code: "SEAL-INSTALL-715"
            )
            return
        }
        let succeeded = await installSignedArtifact(signedApp)
        guard succeeded, let installed = apps.first(where: { $0.id == signedApp.id }) else { return }
        var updatedSession = session
        updatedSession.status = .succeeded(installed)
        signingSession = updatedSession
    }

    func installSignedArtifact(_ app: AppRecord) async -> Bool {
        guard signingTask == nil, batchRefreshTask == nil, installingCachedPackageAppID == nil,
              let signingCoordinator else { return false }
        guard let operationLease = await acquireOperation(.installing, appID: app.id) else { return false }
        defer { releaseOperation(operationLease) }
        installingCachedPackageAppID = app.id
        defer { installingCachedPackageAppID = nil }
        do {
            let installed = try await signingCoordinator.installSignedArtifact(
                appID: app.id,
                progress: { _ in }
            )
            try? await logStore?.append(
                category: .signing,
                message: "已使用本机保存的签名包完成安装：\(installed.displayName)"
            )
            await cleanTemporaryFilesIfNeeded(appID: app.id)
            await load(force: true)
            return true
        } catch let failure as ImportFailure {
            alertFailure = failure
            try? await logStore?.append(
                category: .signing,
                level: .error,
                message: "签名包安装失败：\(failure.reason)",
                code: failure.code
            )
        } catch {
            alertFailure = Self.unexpectedSigningFailure(error)
        }
        await load(force: true)
        return false
    }


    func delete(_ app: AppRecord) async -> Bool {
        guard let appStore, let fileStore else { return false }
        guard let operationLease = await acquireOperation(.maintainingStorage, appID: app.id) else { return false }
        defer { releaseOperation(operationLease) }
        do {
            try await appStore.delete(id: app.id)
            do {
                try await fileStore.removeApp(appID: app.id)
            } catch {
                do {
                    try await appStore.save(app)
                } catch {
                    alertFailure = ImportFailure(
                        title: "应用删除未完整回滚",
                        reason: "本地文件删除失败，并且应用数据库记录未能恢复。",
                        recovery: "重新打开 Seal 让启动恢复检查本地文件",
                        code: "SEAL-APP-ROLLBACK-001"
                    )
                    await load(force: true)
                    return false
                }
                throw error
            }

            var historyFailure: ImportFailure?
            if let signingHistoryStore {
                do {
                    try await signingHistoryStore.markDeleted(appID: app.id)
                } catch {
                    historyFailure = ImportFailure(
                        title: "应用已删除",
                        reason: "「\(app.displayName)」和本地文件已删除，但签名历史状态未能同步。",
                        recovery: "稍后在设置日志中核对；如仍失败请重新打开 Seal",
                        code: "SEAL-HISTORY-003"
                    )
                }
            }
            await load(force: true)
            if let historyFailure {
                alertFailure = historyFailure
            }
            return true
        } catch {
            alertFailure = ImportFailure(
                title: "无法移除应用",
                reason: "「\(app.displayName)」的本地文件删除失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-APP-003"
            )
            return false
        }
    }

    func refreshAll() {
        startBatchRefresh()
    }

    func cancelBatchRefresh() {
        batchRefreshTask?.cancel()
        batchRefreshSession = nil
        Task { await load(force: true) }
    }

    func dismissBatchRefresh() {
        guard let batchRefreshSession else { return }
        Task { try? await logStore?.append(category: .renewal, level: .info, message: "[BatchDebug] dismissBatchRefresh called, status=\(batchRefreshSession.status)", code: "SEAL-BATCH-DEBUG-6") }
        switch batchRefreshSession.status {
        case .preparing, .running, .preparingSealUpdate:
            return
        case .completed, .failed:
            clearPendingBatchResult()
            self.batchRefreshSession = nil
        }
    }

    private func startBatchRefresh() {
        guard batchRefreshTask == nil,
              signingTask == nil,
              renewalCoordinator != nil else { return }
        batchRefreshSession = BatchRefreshSession()
        batchRefreshTask = Task { [weak self] in
            guard let self else { return }
            guard await self.refreshSigningChannel() else {
                self.batchRefreshTask = nil
                self.batchRefreshSession?.status = .failed(Self.connectionRecoveryFailure)
                return
            }
            await self.runBatchRefresh()
        }
    }

    private func presentVPNRecovery(for action: PendingVPNAction) {
        pendingVPNAction = action
        alertFailure = ImportFailure(
            title: "需要恢复连接",
            reason: Self.connectionRecoveryReason,
            recovery: "恢复连接",
            code: "SEAL-INSTALL-706"
        )
    }

    private func runBatchRefresh() async {
        guard let renewalCoordinator else { return }
        guard let operationLease = await acquireOperation(.renewing) else {
            batchRefreshSession = nil
            batchRefreshTask = nil
            return
        }
        defer { releaseOperation(operationLease) }
        // 批量续签只应使用已保存会话；LocalDevVPN 隔离 gsa.apple.com，交互式 2FA
        // 在此路径必败。关闭验证码弹窗，结束（含取消/失败）后务必恢复，避免影响
        // 后续用户主动签名安装时的正常 2FA 输入。
        signingVerificationBroker.setInteractivePromptAllowed(false)
        defer { signingVerificationBroker.setInteractivePromptAllowed(true) }
        do {
            let progress: @Sendable (BatchRefreshEvent) async -> Void = { [weak self] event in
                await self?.consumeBatchEvent(event)
            }
            let result = try await renewalCoordinator.refreshAll(progress: progress)
            if result.total == 0 {
                batchRefreshSession = nil
                alertFailure = ImportFailure(
                    title: "没有可续签的应用",
                    reason: "已安装应用尚未绑定账号",
                    recovery: "知道了",
                    code: "SEAL-RENEW-001"
                )
            } else {
                batchRefreshSession?.status = .completed(result)
                try? await logStore?.append(
                    category: .renewal,
                    level: result.failed == 0 ? .info : .warning,
                    message: "全部续签完成"
                )
                await cleanTemporaryFilesIfNeeded()
            }
            await load(force: true)
        } catch is CancellationError {
            batchRefreshSession = nil
            await load(force: true)
        } catch let failure as ImportFailure {
            batchRefreshSession?.status = .failed(Self.renewalGuidance(for: failure))
        } catch {
            batchRefreshSession?.status = .failed(
                ImportFailure(
                    title: "无法续签应用",
                    reason: "续签队列执行失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                    recovery: "重试",
                    code: "SEAL-RENEW-500a"
                )
            )
        }
        batchRefreshTask = nil
    }

    /// 批量续签失败文案引导：认证/会话类问题统一引导到“我的”页重新验证；
    /// 网络类与其他失败保留原始可操作信息。
    private static func renewalGuidance(for failure: ImportFailure) -> ImportFailure {
        guard failure.code.hasPrefix("SEAL-AUTH-") else { return failure }
        return ImportFailure(
            title: "Apple ID 会话已过期",
            reason: "批量续签需要有效的登录会话。请前往「我的」页选中该账号重新验证后再续签。",
            recovery: "知道了",
            code: failure.code
        )
    }

    private func consumeBatchEvent(_ event: BatchRefreshEvent) {
        guard batchRefreshSession != nil else { return }
        switch event {
        case .prepared(let apps):
            batchRefreshSession?.items = apps.map {
                BatchRefreshSession.Item(id: $0.id, name: $0.displayName, isSeal: $0.isSeal, state: .waiting)
            }
            batchRefreshSession?.total = apps.count
        case .started(let total):
            batchRefreshSession?.total = total
            batchRefreshSession?.status = .running
        case .appProgress(let index, let total, let app, let stage):
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            batchRefreshSession?.currentStage = stage
            let itemState: BatchRefreshSession.Item.State = app.isSeal && (stage == .pushing || stage == .installing) ? .preparingSealUpdate : .running
            if app.isSeal && (stage == .pushing || stage == .installing) {
                batchRefreshSession?.status = .preparingSealUpdate
                persistPendingBatchResultForSealUpdate()
            } else {
                batchRefreshSession?.status = .running
            }
            updateBatchItem(appID: app.id, name: app.displayName, isSeal: app.isSeal, state: itemState, stage: stage)
        case .appSucceeded(let index, let total, let app):
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            batchRefreshSession?.succeeded += 1
            updateBatchItem(appID: app.id, name: app.displayName, isSeal: app.isSeal, state: .completed)
            Task { [weak self] in
                await self?.recordSigningHistory(
                    app: app,
                    action: .renew,
                    result: .success,
                    attemptedBundleIdentifier: app.preferredBundleIdentifier ?? app.mappedBundleIdentifier,
                    finalSignedBundleIdentifier: app.mappedBundleIdentifier,
                    lifecycleStatus: .active
                )
            }
        case .appFailed(let index, let total, let app, let failure):
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            batchRefreshSession?.failed += 1
            updateBatchItem(appID: app.id, name: app.displayName, isSeal: app.isSeal, state: .failed)
            Task { [weak self] in
                await self?.recordSigningHistory(
                    app: app,
                    action: .renew,
                    result: .failed,
                    attemptedBundleIdentifier: app.preferredBundleIdentifier ?? app.mappedBundleIdentifier,
                    lifecycleStatus: app.belongsInInstalledList ? .active : .unknown,
                    failure: failure
                )
            }
        }
    }

    private func updateBatchItem(
        appID: UUID,
        name: String,
        isSeal: Bool,
        state: BatchRefreshSession.Item.State,
        stage: SigningStage? = nil
    ) {
        guard batchRefreshSession != nil else { return }
        if let index = batchRefreshSession?.items.firstIndex(where: { $0.id == appID }) {
            batchRefreshSession?.items[index].name = name
            batchRefreshSession?.items[index].isSeal = isSeal
            batchRefreshSession?.items[index].state = state
            batchRefreshSession?.items[index].stage = stage
        } else {
            batchRefreshSession?.items.append(.init(id: appID, name: name, isSeal: isSeal, state: state, stage: stage))
        }
    }

    private func persistPendingBatchResultForSealUpdate() {
        guard let session = batchRefreshSession else {
            Task { try? await logStore?.append(category: .renewal, level: .warning, message: "[BatchDebug] persist skipped: batchRefreshSession is nil", code: "SEAL-BATCH-DEBUG-1") }
            return
        }
        let itemPayload = session.items.map { item -> [String: Any] in
            [
                "id": item.id.uuidString,
                "name": item.name,
                "isSeal": item.isSeal,
                "state": item.isSeal ? "completed" : item.state.storageValue
            ]
        }
        let succeeded = max(session.succeeded + 1, itemPayload.filter { ($0["state"] as? String) == "completed" }.count)
        let payload: [String: Any] = [
            "succeeded": succeeded,
            "failed": session.failed,
            "total": session.total,
            "timestamp": Date().timeIntervalSince1970,
            "items": itemPayload
        ]
        UserDefaults.standard.set(payload, forKey: Self.pendingBatchResultKey)
        UserDefaults.standard.synchronize()
        // 双保险：同时写入 JSON 文件，避免 Seal 自签覆盖安装时 UserDefaults 丢失
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.pendingBatchResultFileURL, options: .atomic)
        }
        Task { try? await logStore?.append(category: .renewal, level: .info, message: "[BatchDebug] persisted: total=\(session.total) succeeded=\(succeeded) failed=\(session.failed) items=\(itemPayload.count)", code: "SEAL-BATCH-DEBUG-2") }
    }

    private func restorePendingBatchResultIfNeeded() {
        guard batchRefreshSession == nil, batchRefreshTask == nil else {
            Task { try? await logStore?.append(category: .renewal, level: .warning, message: "[BatchDebug] restore skipped: session=\(batchRefreshSession != nil) task=\(batchRefreshTask != nil)", code: "SEAL-BATCH-DEBUG-3") }
            return
        }
        // 优先从文件读取（更可靠，避免 Seal 自签覆盖安装时 UserDefaults 丢失），文件没有再回退到 UserDefaults
        let payload: [String: Any]?
        if let fileData = try? Data(contentsOf: Self.pendingBatchResultFileURL),
           let filePayload = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any] {
            payload = filePayload
        } else {
            payload = UserDefaults.standard.dictionary(forKey: Self.pendingBatchResultKey)
        }
        guard let payload else {
            Task { try? await logStore?.append(category: .renewal, level: .info, message: "[BatchDebug] restore skipped: no pending data in file or UserDefaults", code: "SEAL-BATCH-DEBUG-4") }
            return
        }
        let succeeded = payload["succeeded"] as? Int ?? 0
        let failed = payload["failed"] as? Int ?? 0
        let total = payload["total"] as? Int ?? max(succeeded + failed, 0)
        var restored = BatchRefreshSession()
        restored.status = .completed(.init(total: total, succeeded: succeeded, failed: failed, remaining: max(0, total - succeeded - failed)))
        restored.currentIndex = total
        restored.total = total
        if let itemPayload = payload["items"] as? [[String: Any]] {
            restored.items = itemPayload.compactMap { item in
                guard let idString = item["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let name = item["name"] as? String else { return nil }
                let isSeal = item["isSeal"] as? Bool ?? false
                let state = BatchRefreshSession.Item.State(storageValue: item["state"] as? String)
                return BatchRefreshSession.Item(id: id, name: name, isSeal: isSeal, state: state)
            }
        }
        batchRefreshSession = restored
        Task { try? await logStore?.append(category: .renewal, level: .info, message: "[BatchDebug] restored: total=\(total) succeeded=\(succeeded) failed=\(failed) items=\(restored.items.count) status=completed", code: "SEAL-BATCH-DEBUG-5") }
    }

    private func clearPendingBatchResult() {
        UserDefaults.standard.removeObject(forKey: Self.pendingBatchResultKey)
        try? FileManager.default.removeItem(at: Self.pendingBatchResultFileURL)
    }

    private static let pendingBatchResultKey = "seal.pendingBatchRefreshResult"
    private static var pendingBatchResultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppConfiguration.Paths.applicationSupportSubdirectory, isDirectory: true)
            .appendingPathComponent("PendingBatchResult.json")
    }

    private func startSigning(
        app: AppRecord,
        account: AppleAccountRecord,
        requestedBundleIdentifier: String? = nil,
        completionMode: SigningCompletionMode = .signAndInstall,
        allowDroppingExtensions: Bool = false
    ) {
        guard signingTask == nil,
              batchRefreshTask == nil,
              signingCoordinator != nil else { return }
        let selectedCertificateSerialNumber: String?
        if app.belongsInInstalledList {
            selectedCertificateSerialNumber = nil
        } else {
            selectedCertificateSerialNumber = try? SigningCertificateSelectionPolicy
                .resolvedSerialNumber(for: app, account: account)
        }
        let resolvedAllowDroppingExtensions = allowDroppingExtensions
            || app.removedExtensionBundleIdentifiers.isEmpty == false
        signingSession = SigningSession(
            app: app,
            account: account,
            requestedBundleIdentifier: requestedBundleIdentifier,
            selectedCertificateSerialNumber: selectedCertificateSerialNumber,
            completionMode: completionMode,
            allowsDroppingExtensions: resolvedAllowDroppingExtensions,
            status: .running(.waitingForChannel)
        )
        let targetBundleIdentifier = (try? BundleIDPolicy.targetBundleIdentifier(
            for: app,
            requestedBundleIdentifier: requestedBundleIdentifier
        )) ?? app.mappedBundleIdentifier ?? app.originalBundleIdentifier
        Task { [weak self] in
            try? await self?.logStore?.append(
                category: .signing,
                message: "准备签名：\(app.name)，Apple ID：\(account.maskedEmail)，Team：\(account.teamID)，证书：\(selectedCertificateSerialNumber ?? "签名时申请")，Bundle ID：\(targetBundleIdentifier)"
            )
        }
        signingTask = Task { [weak self] in
            await self?.runSigning(
                app: app,
                account: account,
                requestedBundleIdentifier: requestedBundleIdentifier,
                selectedCertificateSerialNumber: selectedCertificateSerialNumber,
                completionMode: completionMode,
                allowDroppingExtensions: resolvedAllowDroppingExtensions
            )
        }
    }

    private func restartSigning(
        _ session: SigningSession,
        allowDroppingExtensions: Bool,
        bypassFreeAccountDeviceLimit: Bool = false
    ) {
        guard signingTask == nil,
              batchRefreshTask == nil,
              signingCoordinator != nil else { return }
        signingSession?.allowsDroppingExtensions = allowDroppingExtensions
        signingSession?.status = .running(.waitingForChannel)
        signingTask = Task { [weak self] in
            await self?.runSigning(
                app: session.app,
                account: session.account,
                requestedBundleIdentifier: session.requestedBundleIdentifier,
                selectedCertificateSerialNumber: session.selectedCertificateSerialNumber,
                completionMode: session.completionMode,
                allowDroppingExtensions: allowDroppingExtensions,
                bypassFreeAccountDeviceLimit: bypassFreeAccountDeviceLimit
            )
        }
    }

    private func runSigning(
        app: AppRecord,
        account: AppleAccountRecord,
        requestedBundleIdentifier: String? = nil,
        selectedCertificateSerialNumber: String?,
        completionMode: SigningCompletionMode,
        allowDroppingExtensions: Bool,
        bypassFreeAccountDeviceLimit: Bool = false
    ) async {
        guard let signingCoordinator else { return }
        defer { signingTask = nil }
        let isRenewal = app.belongsInInstalledList
        let operationKind: OperationCoordinator.Kind = isRenewal ? .renewing : .signing
        guard let operationLease = await acquireOperation(operationKind, appID: app.id) else {
            signingTask = nil
            return
        }
        defer { releaseOperation(operationLease) }
        let attemptedBundleIdentifier = try? BundleIDPolicy.targetBundleIdentifier(
            for: app,
            requestedBundleIdentifier: requestedBundleIdentifier
        )
        do {
            updateSigningStage(.waitingForChannel)
            if completionMode == .signAndInstall {
                guard await refreshSigningChannel() else {
                    throw Self.connectionRecoveryFailure
                }
            }
            let completed = try await signingCoordinator.signAndInstall(
                appID: app.id,
                accountID: account.id,
                requestedBundleIdentifier: requestedBundleIdentifier,
                selectedCertificateSerialNumber: selectedCertificateSerialNumber,
                allowDroppingExtensions: allowDroppingExtensions,
                forceResign: isRenewal,
                bypassFreeAccountDeviceLimit: bypassFreeAccountDeviceLimit,
                progress: { [weak self] stage in
                    await self?.updateSigningStage(stage)
                },
                onCertificateResolved: { [weak self] serialNumber in
                    await self?.updateResolvedCertificateSerialNumber(serialNumber)
                },
                onInstallProgress: { [weak self] progress in
                    await self?.updateInstallProgress(progress)
                }
            )
            let action: SigningHistoryRecord.Action = isRenewal ? .renew : .sign
            signingSession?.status = .succeeded(completed)
            try? await logStore?.append(
                category: .signing,
                message: isRenewal ? "续签并安装成功" : "签名并安装成功"
            )
            await recordSigningHistory(
                app: completed,
                account: account,
                action: action,
                result: .success,
                attemptedBundleIdentifier: attemptedBundleIdentifier,
                finalSignedBundleIdentifier: completed.mappedBundleIdentifier,
                lifecycleStatus: completed.belongsInInstalledList ? .active : .unknown
            )
            await cleanTemporaryFilesIfNeeded(appID: completed.id)
            await load(force: true)
        } catch is CancellationError {
            signingSession = nil
        } catch let failure as ImportFailure {
            signingSession?.status = .failed(failure)

            try? await logStore?.append(
                category: .signing,
                level: .error,
                message: "\(failure.title)：\(failure.reason)",
                code: failure.code
            )
            let latestApp = await latestStoredApp(for: app)
            await recordSigningHistory(
                app: latestApp,
                account: account,
                action: isRenewal ? .renew : .sign,
                result: .failed,
                attemptedBundleIdentifier: attemptedBundleIdentifier,
                lifecycleStatus: isRenewal ? .active : .unknown,
                failure: failure
            )
            await load(force: true)
        } catch {
            let failure = Self.unexpectedSigningFailure(error)
            signingSession?.status = .failed(failure)
            try? await logStore?.append(
                category: .signing,
                level: .error,
                message: failure.reason,
                code: failure.code
            )
            let latestApp = await latestStoredApp(for: app)
            await recordSigningHistory(
                app: latestApp,
                account: account,
                action: isRenewal ? .renew : .sign,
                result: .failed,
                attemptedBundleIdentifier: attemptedBundleIdentifier,
                lifecycleStatus: isRenewal ? .active : .unknown,
                failure: failure
            )
            await load(force: true)
        }
    }

    private func latestStoredApp(for fallback: AppRecord) async -> AppRecord {
        guard let appStore,
              let stored = try? await appStore.fetchAll().first(where: {
                  $0.id == fallback.id
              }) else {
            return fallback
        }
        return stored
    }

    private func updateSigningStage(_ stage: SigningStage) {
        guard signingSession != nil else { return }
        signingSession?.status = .running(stage)
    }

    // 安装通道 AFC 上传阶段的真实进度（0-1）→ 刷新进度 UI。
    // Rust 上传结束、installd 安装命令即将下发时的哨兵（>1.0，101→1.01）会让进度条
    // 停在 100% 干等 installd 解压/复制，故在这里把阶段切到 .installing（文案「正在安装」），
    // 进度归 1.0 收尾，避免 UI 一直显示「正在传输 100%」。
    private func updateInstallProgress(_ progress: Double) {
        guard signingSession != nil else { return }
        if progress > 1.0 {
            signingSession?.installProgress = 1.0
            if case .running(let stage) = signingSession?.status, stage == .pushing {
                signingSession?.status = .running(.installing)
            }
            return
        }
        signingSession?.installProgress = progress
    }

    // SigningCoordinator 在证书序列号确定后回传（actor 上下文 → hop 回 MainActor 更新快照）
    private func updateResolvedCertificateSerialNumber(_ serialNumber: String) {
        signingSession?.selectedCertificateSerialNumber = serialNumber
    }

    private func recordSigningHistory(
        app: AppRecord,
        account explicitAccount: AppleAccountRecord? = nil,
        action: SigningHistoryRecord.Action,
        result: SigningHistoryRecord.Result,
        attemptedBundleIdentifier: String? = nil,
        finalSignedBundleIdentifier: String? = nil,
        lifecycleStatus: SigningHistoryRecord.LifecycleStatus? = nil,
        failure: ImportFailure? = nil
    ) async {
        guard let signingHistoryStore else { return }
        let account = await resolvedHistoryAccount(for: app, explicitAccount: explicitAccount)
        guard let account else { return }
        let record = SigningHistoryRecord(
            app: app,
            account: account,
            action: action,
            result: result,
            attemptedBundleIdentifier: attemptedBundleIdentifier,
            finalSignedBundleIdentifier: finalSignedBundleIdentifier,
            lifecycleStatus: lifecycleStatus,
            errorCode: failure?.code,
            errorReason: failure?.reason
        )
        do {
            try await signingHistoryStore.append(record)
        } catch {
            surfaceHistoryWarning(
                title: "签名历史未保存",
                reason: "签名结果已经完成，但历史记录无法写入。",
                code: "SEAL-HISTORY-005"
            )
        }
    }

    private func resolvedHistoryAccount(
        for app: AppRecord,
        explicitAccount: AppleAccountRecord?
    ) async -> AppleAccountRecord? {
        if let explicitAccount { return explicitAccount }
        guard let accountID = app.accountID else { return nil }
        if let account = accounts.first(where: { $0.id == accountID }) {
            return account
        }
        guard let accountRepository else { return nil }
        do {
            let fetchedAccounts = try await accountRepository.fetchAll()
            return fetchedAccounts.first { $0.id == accountID }
        } catch {
            surfaceHistoryWarning(
                title: "签名历史账号读取失败",
                reason: "无法读取历史记录关联的 Apple ID。",
                code: "SEAL-HISTORY-006"
            )
            return nil
        }
    }

    private func surfaceHistoryWarning(
        title: String,
        reason: String,
        code: String
    ) {
        guard alertFailure == nil else { return }
        alertFailure = ImportFailure(
            title: title,
            reason: reason,
            recovery: "检查本地存储空间后重试",
            code: code
        )
    }

    private func cleanTemporaryFilesIfNeeded(appID: UUID? = nil) async {
        guard UserDefaults.standard.bool(forKey: "behavior.deleteIPAAfterInstall"),
              let fileStore else { return }
        do {
            try await fileStore.clearTemporaryFiles()
            try? await logStore?.append(
                category: .system,
                message: appID == nil ? "安装完成后已清理临时签名工作区" : "安装完成后已清理当前应用临时签名工作区"
            )
        } catch {
            try? await logStore?.append(
                category: .system,
                level: .warning,
                message: "安装完成后清理签名缓存失败",
                code: "SEAL-STORAGE-001"
            )
        }
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

    private func settingsRoute(for failure: ImportFailure) -> SettingsRoute? {
        if failure.code.hasPrefix("SEAL-AUTH-") { return .account }
        if failure.code.hasPrefix("SEAL-CERT-") || failure.code.contains("CERT") { return .certificates }
        if failure.code.hasPrefix("SEAL-PAIR-") || failure.code == "SEAL-INSTALL-703" { return .pairing }
        if failure.code.hasPrefix("SEAL-INSTALL-") { return .localDevVPN }
        return nil
    }

    private static func unexpectedSigningFailure(_ error: Error) -> ImportFailure {
        return ImportFailure(
            title: "签名失败",
            reason: "签名流程遇到未预期错误，技术信息已写入脱敏日志。",
            recovery: "重试",
            code: "SEAL-SIGN-500"
        )
    }

    private func consumeWorkflowState() async {
        guard let workflow else { return }
        let workflowState = await workflow.state
        switch workflowState {
        case .idle:
            phase = .idle
        case .preparing:
            phase = .preparing
        case .awaitingConfirmation(let draft):
            sheetDraft = draft
            sheetFailure = nil
            isImportSheetPresented = false
            phase = .committing
            await workflow.confirm(preferredDraft: draft)
            await consumeWorkflowState()
        case .committing(let draft):
            phase = .committing
            sheetDraft = draft
            isImportSheetPresented = true
        case .completed(let record):
            phase = .idle
            sheetDraft = nil
            sheetFailure = nil
            isImportSheetPresented = false
            await load(force: true)
            lastImportCompletedInstalledApp = record.belongsInInstalledList
            importCompletionCount += 1
            if autoOpenSigningAfterImport {
                autoOpenSigningAfterImport = false
                if let refreshed = apps.first(where: { $0.id == record.id }) {
                    selectedOperationApp = refreshed
                }
            }
            if let cleanupFailure = await workflow.takeCleanupFailure() {
                alertFailure = cleanupFailure
            }
        case .failed(let failure):
            phase = .idle
            if sheetDraft == nil {
                alertFailure = failure
            } else {
                sheetFailure = failure
                isImportSheetPresented = true
            }
        }
    }

    private static func exportFileName(for app: AppRecord) -> String {
        let raw = "\(app.displayName)-\(app.version)-Seal.ipa"
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return raw.components(separatedBy: invalid).joined(separator: "-")
    }

    static func uiTestModel(arguments: [String]) -> AppsViewModel? {
        if arguments.contains("--ui-testing-empty") {
            return AppsViewModel(apps: [], draft: nil)
        }

        let appID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let record = AppRecord(
            id: appID,
            originalBundleIdentifier: "com.example.demo",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1_234_567,
            state: .preflightPassed,
            ipaRelativePath: "Apps/\(appID.uuidString)/Original.ipa",
            importedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        if arguments.contains("--ui-testing-imported") {
            return AppsViewModel(apps: [record], draft: nil)
        }
        if arguments.contains("--ui-testing-confirmation") {
            let draft = ImportDraft(
                appID: appID,
                parsedIPA: ParsedIPA(
                    name: "Demo",
                    bundleIdentifier: "com.example.demo",
                    version: "1.0",
                    buildNumber: "1",
                    fileSize: 1_234_567,
                    iconData: nil,
                    extensions: [
                        AppExtensionRecord(
                            name: "Share",
                            originalBundleIdentifier: "com.example.demo.share",
                            kind: .share
                        )
                    ],
                    entitlementKeys: [],
                    importWarnings: []
                ),
                stagedIPA: StagedIPA(
                    id: appID,
                    url: FileManager.default.temporaryDirectory.appending(path: "Demo.ipa")
                )
            )
            return AppsViewModel(apps: [], draft: draft)
        }
        return nil
    }

    private static let connectionRecoveryReason = "请确认已连接 Wi-Fi 并开启 LocalDevVPN。若长时间无响应，请在设置中确认 LocalDevVPN 已连接后重试。"

    private static let connectionRecoveryFailure = ImportFailure(
        title: "需要恢复连接",
        reason: connectionRecoveryReason,
        recovery: "重新检查",
        code: "SEAL-VPN-001"
    )
}


private extension BatchRefreshSession.Item.State {
    var storageValue: String {
        switch self {
        case .waiting: return "waiting"
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .preparingSealUpdate: return "preparingSealUpdate"
        }
    }

    init(storageValue: String?) {
        switch storageValue {
        case "running": self = .running
        case "completed": self = .completed
        case "failed": self = .failed
        case "preparingSealUpdate": self = .preparingSealUpdate
        default: self = .waiting
        }
    }
}
