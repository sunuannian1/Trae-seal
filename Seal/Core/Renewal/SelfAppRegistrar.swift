import Foundation
import ZIPFoundation

actor SelfAppRegistrar {
    private let metadata: SelfAppMetadata
    private let appStore: any AppStore
    private let accountRepository: any AccountRepository
    private let fileStore: AppFileStore

    // 固定 ID，确保 Seal 记录和文件夹路径始终一致，不会出现多个文件夹
    private let fixedSealID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // 防重入：确保同时只有一个注册流程在执行
    private var isRegistering = false

    init(
        metadata: SelfAppMetadata,
        appStore: any AppStore,
        accountRepository: any AccountRepository,
        fileStore: AppFileStore
    ) {
        self.metadata = metadata
        self.appStore = appStore
        self.accountRepository = accountRepository
        self.fileStore = fileStore
    }

    func ensureRegistered() async throws {
        guard isRegistering == false else { return }
        isRegistering = true
        defer { isRegistering = false }

        let records = try await appStore.fetchAll()
        let accounts = try await accountRepository.fetchAll()
        let existing = SelfAppRecordSelection.preferredExistingSealRecord(
            in: records,
            currentBundleIdentifier: metadata.bundleIdentifier
        )

        // 已导入、待下次安装生效的自更新源（hasPendingSelfUpdateSource）：
        // 其版本通常比当前运行中的 Bundle 新。此窗口内 App 若重启，仍运行旧版，
        // 绝不能用当前旧 metadata 覆盖这条待安装记录与文件，否则更新源丢失。
        // 仅当待安装源文件仍在、且记录版本不低于运行版本时保留（记录版本更低说明
        // 待安装源已被外部更新取代，属残留标记，落到原子更新对齐当前运行版本，
        // 否则已安装列表会一直显示旧版本号）。
        if let existing,
           existing.hasPendingSelfUpdateSource,
           existing.ipaRelativePath.isEmpty == false,
           try await fileStore.exists(relativePath: existing.ipaRelativePath),
           Version.compare(existing.version, metadata.version) != .orderedAscending {
            try await cleanupDuplicateSealRecords(records: records, keepID: existing.id)
            return
        }

        // 版本一致且文件存在 → 直接跳过，只清理重复记录
        if let existing,
           existing.version == metadata.version,
           existing.buildNumber == metadata.buildNumber,
           existing.ipaRelativePath.isEmpty == false,
           try await fileStore.exists(relativePath: existing.ipaRelativePath) {
            try await cleanupDuplicateSealRecords(records: records, keepID: existing.id)
            // 版本一致也回补 Team/账号：首次未记录时，后续启动从自身描述文件补全，
            // 避免续签时退化成"选第一个账号"导致 Bundle ID 被占用。
            try await reconcileSealRecordBindingIfNeeded(
                existing: existing,
                metadata: metadata,
                accounts: accounts
            )
            return
        }

        // 版本变更或文件缺失 → 原子更新
        let id = existing?.id ?? fixedSealID
        try await atomicallyUpdateSealRecord(id: id, existing: existing, accounts: accounts)

        // 清理历史残留的重复记录
        try await cleanupDuplicateSealRecords(records: records, keepID: id)
    }

    // MARK: - 原子更新：先暂存，再提交覆盖，失败回滚

    private func atomicallyUpdateSealRecord(
        id: UUID,
        existing: AppRecord?,
        accounts: [AppleAccountRecord]
    ) async throws {
        // 1. 打包新 IPA 到临时工作区（不碰旧文件）
        let workspace = try await fileStore.signingWorkspace(appID: UUID())
        defer { try? FileManager.default.removeItem(at: workspace) }

        let payload = workspace.appending(path: "Payload", directoryHint: .isDirectory)
        let appURL = payload.appending(
            path: "\(metadata.name).app",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: payload,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: metadata.bundleURL, to: appURL)
        let ipaURL = workspace.appending(path: "Seal.ipa")
        try FileManager.default.zipItem(
            at: payload,
            to: ipaURL,
            shouldKeepParent: true,
            compressionMethod: .deflate
        )

        // 2. 暂存新文件
        let staged = try await fileStore.stage(sourceURL: ipaURL)

        do {
            // 3. 图标：优先用新提取的，失败则复用旧图标
            var iconData = metadata.iconData
            if iconData == nil, let oldIconPath = existing?.iconRelativePath {
                iconData = try? await fileStore.read(relativePath: oldIconPath)
            }

            // 4. 提交新文件（用同一个 ID，覆盖旧文件，不是先删后建）
            let files = try await fileStore.commit(
                staged: staged,
                appID: id,
                iconData: iconData
            )

            // 5. 取消暂存
            do {
                try await fileStore.cancel(staged)
            } catch {
                throw ImportFailure(
                    title: "Seal 临时文件清理失败",
                    reason: "Seal 自身注册已写入文件，但暂存文件未能清理。",
                    recovery: "稍后在设置→存储维护中重试清理",
                    code: "SEAL-STORAGE-SELF-001"
                )
            }

            // 6. 计算文件大小
            let attributes = try FileManager.default.attributesOfItem(atPath: ipaURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

            // 7. 解析账户绑定（和以前逻辑一致，匹配不到返回 nil，不强制用第一个账户）
            let resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: metadata.signingTeamIdentifier,
                accounts: accounts,
                fallbackAccountID: existing?.accountID
            )

            // 8. 更新记录（复用 ID，不删除重建）
            let record = AppRecord(
                id: id,
                originalBundleIdentifier: SelfAppBundleIdentity.originalBundleIdentifier(
                    currentBundleIdentifier: metadata.bundleIdentifier,
                    declaredOriginalBundleIdentifier: metadata.originalBundleIdentifier,
                    existingOriginalBundleIdentifier: existing?.originalBundleIdentifier
                ),
                mappedBundleIdentifier: metadata.bundleIdentifier,
                name: metadata.name,
                version: metadata.version,
                buildNumber: metadata.buildNumber,
                size: size,
                iconRelativePath: files.iconRelativePath ?? existing?.iconRelativePath,
                state: .installed,
                expiryDate: metadata.expirationDate,
                accountID: resolvedAccountID,
                signingTeamID: metadata.signingTeamIdentifier ?? existing?.signingTeamID,
                certificateSerialNumber: existing?.certificateSerialNumber,
                provisioningProfileExpirationDate: metadata.expirationDate,
                ipaRelativePath: files.ipaRelativePath,
                signedIPARelativePath: nil,
                preferredBundleIdentifier: metadata.bundleIdentifier,
                isSeal: true,
                isPinned: true,
                importedAt: existing?.importedAt ?? Date(),
                extensions: existing?.extensions ?? []
            )
            try await appStore.save(record)

        } catch {
            // 9. 失败回滚：取消暂存，旧文件不受影响
            try? await fileStore.cancel(staged)
            throw error
        }
    }

    // MARK: - 清理重复的 Seal 记录

    private func cleanupDuplicateSealRecords(
        records: [AppRecord],
        keepID: UUID
    ) async throws {
        for record in records where record.isSeal && record.id != keepID {
            // 先删除文件，再删除数据库记录，避免产生孤儿文件
            try? await fileStore.removeApp(appID: record.id)
            try? await appStore.delete(id: record.id)
        }
    }

    /// 版本一致时的轻量回补：只更新 Team/账号绑定，不重打包 IPA。
    /// 解决"首次启动未记录账号 → 之后版本不变永远未记录 → 续签错选第一个账号"的问题。
    private func reconcileSealRecordBindingIfNeeded(
        existing: AppRecord,
        metadata: SelfAppMetadata,
        accounts: [AppleAccountRecord]
    ) async throws {
        let resolvedTeamID = metadata.signingTeamIdentifier ?? existing.signingTeamID
        let resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
            teamIdentifier: resolvedTeamID,
            accounts: accounts,
            fallbackAccountID: existing.accountID
        )
        guard existing.signingTeamID != resolvedTeamID
                || existing.accountID != resolvedAccountID else {
            return
        }
        var updated = existing
        updated.signingTeamID = resolvedTeamID
        updated.accountID = resolvedAccountID
        try await appStore.save(updated)
    }
}
