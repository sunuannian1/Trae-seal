import Foundation
import ZIPFoundation

struct IPAParserService: Sendable {
    let limits: ArchiveLimits

    init(limits: ArchiveLimits = ArchiveLimits()) {
        self.limits = limits
    }

    func parse(url: URL) throws -> ParsedIPA {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw failure(
                title: "无法打开 IPA",
                reason: "文件 \(url.lastPathComponent) 无法作为 IPA（ZIP）打开。",
                recovery: "选择其他 IPA",
                code: "SEAL-IPA-106"
            )
        }

        do {
            return try parse(archive: archive, sourceURL: url)
        } catch let error as ImportFailure {
            throw error
        } catch {
            throw failure(
                title: "无法读取 IPA",
                reason: "应用信息解析失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "选择其他 IPA",
                code: "SEAL-IPA-102"
            )
        }
    }

    private func parse(archive: Archive, sourceURL: URL) throws -> ParsedIPA {
        let entries = Array(archive)
        try validate(entries: entries)

        // 检测嵌套 IPA：外层 zip 只有一个 .ipa 文件，没有 Payload 目录
        // 部分第三方平台下载的 IPA 是这种结构，需要自动解包
        let hasPayload = entries.contains { entry in
            entry.path.hasPrefix("Payload/")
        }
        let nestedIPAEntries = entries.filter { entry in
            entry.type == .file && entry.path.lowercased().hasSuffix(".ipa")
        }
        if hasPayload == false, let nestedIPAEntry = nestedIPAEntries.first, nestedIPAEntries.count == 1 {
            // 解压嵌套 IPA 到临时文件，然后递归解析
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("SealNestedIPA-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let nestedIPATempURL = tempDir.appendingPathComponent("nested.ipa")
            var nestedData = Data()
            nestedData.reserveCapacity(Int(nestedIPAEntry.uncompressedSize))
            _ = try archive.extract(nestedIPAEntry) { chunk in
                nestedData.append(chunk)
            }
            try nestedData.write(to: nestedIPATempURL)

            let nestedArchive: Archive
            do {
                nestedArchive = try Archive(url: nestedIPATempURL, accessMode: .read)
            } catch {
                throw failure(
                    title: "无法读取 IPA",
                    reason: "嵌套的 IPA 文件已损坏",
                    recovery: "选择其他 IPA",
                    code: "SEAL-IPA-101a"
                )
            }
            return try parse(archive: nestedArchive, sourceURL: sourceURL)
        }

        let appInfoEntries = entries.filter { entry in
            let components = entry.path.split(separator: "/")
            return components.count == 3
                && components[0] == "Payload"
                && components[1].hasSuffix(".app")
                && components[2] == "Info.plist"
        }

        guard appInfoEntries.isEmpty == false else {
            throw failure(
                title: "无法读取 IPA",
                reason: "未找到应用信息（Payload 目录缺少 .app 的 Info.plist）。",
                recovery: "选择其他 IPA",
                code: "SEAL-IPA-101"
            )
        }
        guard appInfoEntries.count == 1, let appInfoEntry = appInfoEntries.first else {
            throw failure(
                title: "无法读取 IPA",
                reason: "包含多个主应用（找到 \(appInfoEntries.count) 个 .app/Info.plist）。",
                recovery: "选择标准 IPA",
                code: "SEAL-IPA-103"
            )
        }

        let info = try propertyList(
            from: appInfoEntry,
            in: archive,
            maximumSize: limits.maximumMetadataSize
        )
        let bundleIdentifier = info["CFBundleIdentifier"] as? String
        let version = info["CFBundleShortVersionString"] as? String
        let buildNumber = info["CFBundleVersion"] as? String
        let name = displayName(from: info)
        let missingFields = [
            (bundleIdentifier?.isEmpty == false) ? nil : "Bundle ID",
            (version?.isEmpty == false) ? nil : "版本号",
            (buildNumber?.isEmpty == false) ? nil : "构建号",
            (name?.isEmpty == false) ? nil : "应用名"
        ].compactMap { $0 }
        guard missingFields.isEmpty,
              let bundleIdentifier,
              let version,
              let buildNumber,
              let name,
              name.isEmpty == false else {
            throw failure(
                title: "无法读取 IPA",
                reason: "应用信息不完整，缺少：\(missingFields.joined(separator: "、"))。",
                recovery: "选择其他 IPA",
                code: "SEAL-IPA-102a"
            )
        }

        let appRoot = appInfoEntry.path
            .split(separator: "/")
            .dropLast()
            .joined(separator: "/")
        let iconData = try readIcon(
            info: info,
            appRoot: appRoot,
            entries: entries,
            archive: archive
        )
        let appExtensions = try readExtensions(
            appRoot: appRoot,
            entries: entries,
            archive: archive
        )
        let entitlementKeys = readEntitlementKeys(
            appRoot: appRoot,
            entries: entries,
            archive: archive
        )
        let importWarnings = detectImportWarnings(
            appRoot: appRoot,
            entries: entries,
            archive: archive
        )
        let fileSize = try sourceFileSize(at: sourceURL)

        return ParsedIPA(
            name: name,
            bundleIdentifier: bundleIdentifier,
            version: version,
            buildNumber: buildNumber,
            fileSize: fileSize,
            iconData: iconData,
            extensions: appExtensions,
            entitlementKeys: entitlementKeys,
            importWarnings: importWarnings
        )
    }

    private func validate(entries: [Entry]) throws {
        guard entries.count <= limits.maximumEntryCount else {
            throw sizeFailure(
                detail: "IPA 内文件条目数 \(entries.count) 超过安全上限 \(limits.maximumEntryCount)。"
            )
        }

        var expandedSize: UInt64 = 0
        for entry in entries {
            guard ArchivePathValidator.isSafe(entry.path) else {
                throw failure(
                    title: "IPA 不安全",
                    reason: "压缩包包含非法路径：\(entry.path)。",
                    recovery: "选择其他 IPA",
                    code: "SEAL-IPA-104"
                )
            }

            let (sum, overflow) = expandedSize.addingReportingOverflow(entry.uncompressedSize)
            guard overflow == false, sum <= limits.maximumExpandedSize else {
                throw sizeFailure(
                    detail: "IPA 解压后总大小超过安全上限（\(sum) > \(limits.maximumExpandedSize) 字节）。"
                )
            }
            expandedSize = sum
        }
    }

    private func propertyList(
        from entry: Entry,
        in archive: Archive,
        maximumSize: UInt64
    ) throws -> [String: Any] {
        let data = try data(from: entry, in: archive, maximumSize: maximumSize)
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let dictionary = value as? [String: Any] else {
            throw failure(
                title: "无法读取 IPA",
                reason: "无法解析 \(entry.path) 的 PropertyList。",
                recovery: "选择其他 IPA",
                code: "SEAL-IPA-102b"
            )
        }
        return dictionary
    }

    private func data(
        from entry: Entry,
        in archive: Archive,
        maximumSize: UInt64
    ) throws -> Data {
        guard entry.uncompressedSize <= maximumSize else {
            throw sizeFailure(
                detail: "文件 \(entry.path) 的大小 \(entry.uncompressedSize) 字节超过单文件读取上限 \(maximumSize) 字节。"
            )
        }

        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            result.append(chunk)
        }
        return result
    }

    private func displayName(from info: [String: Any]) -> String? {
        (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
    }

    private func readIcon(
        info: [String: Any],
        appRoot: String,
        entries: [Entry],
        archive: Archive
    ) throws -> Data? {
        let iconNames = iconFileNames(from: info)
        let iconCandidateEntries = entries.filter { entry in
            guard entry.type == .file, entry.path.hasPrefix("\(appRoot)/") else { return false }
            let lowerName = URL(filePath: entry.path).lastPathComponent.lowercased()
            return lowerName.hasSuffix(".png")
                || lowerName == "itunesartwork"
                || lowerName.hasPrefix("itunesartwork@")
        }

        let declared = iconCandidateEntries.filter { entry in
            let fileName = URL(filePath: entry.path).deletingPathExtension().lastPathComponent
            return iconNames.contains { declaredName in
                fileName.caseInsensitiveCompare(declaredName) == .orderedSame
                    || fileName.localizedCaseInsensitiveContains(declaredName)
                    || fileName.hasPrefix(declaredName)
            }
        }

        let fallbacks = iconCandidateEntries.filter { entry in
            let lower = URL(filePath: entry.path).lastPathComponent.lowercased()
            return lower.hasPrefix("icon")
                || lower.hasPrefix("appicon")
                || lower.contains("appicon")
                || lower.contains("itunesartwork")
        }

        guard let selected = (declared + fallbacks).max(by: {
            $0.uncompressedSize < $1.uncompressedSize
        }) else {
            return nil
        }

        return try data(
            from: selected,
            in: archive,
            maximumSize: limits.maximumIconSize
        )
    }

    private func iconFileNames(from info: [String: Any]) -> [String] {
        var names: [String] = []
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files)
        }
        if let files = info["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files)
        }
        return Array(NSOrderedSet(array: names)) as? [String] ?? names
    }

    private func readExtensions(
        appRoot: String,
        entries: [Entry],
        archive: Archive
    ) throws -> [AppExtensionRecord] {
        let infoEntries = entries.filter { entry in
            entry.path.hasPrefix("\(appRoot)/PlugIns/")
                && entry.path.hasSuffix(".appex/Info.plist")
        }

        return try infoEntries.map { entry in
            let info = try propertyList(
                from: entry,
                in: archive,
                maximumSize: limits.maximumMetadataSize
            )
            guard let bundleIdentifier = info["CFBundleIdentifier"] as? String,
                  bundleIdentifier.isEmpty == false else {
                throw failure(
                    title: "无法读取 IPA",
                    reason: "扩展 \(entry.path) 的 Info.plist 缺少有效的 Bundle ID。",
                    recovery: "选择其他 IPA",
                    code: "SEAL-IPA-102c"
                )
            }
            let name = displayName(from: info)
                ?? URL(filePath: entry.path).deletingLastPathComponent().lastPathComponent
            let extensionInfo = info["NSExtension"] as? [String: Any]
            let pointIdentifier = extensionInfo?["NSExtensionPointIdentifier"] as? String

            return AppExtensionRecord(
                name: name,
                originalBundleIdentifier: bundleIdentifier,
                kind: extensionKind(for: pointIdentifier)
            )
        }
    }

    private func extensionKind(for pointIdentifier: String?) -> AppExtensionKind {
        switch pointIdentifier {
        case "com.apple.share-services":
            return .share
        case "com.apple.usernotifications.service":
            return .notificationService
        case "com.apple.widgetkit-extension", "com.apple.widget-extension":
            return .widget
        default:
            return .unknown
        }
    }

    private func readEntitlementKeys(
        appRoot: String,
        entries: [Entry],
        archive: Archive
    ) -> Set<String> {
        let entitlementEntries = entries.filter { entry in
            entry.path.hasPrefix("\(appRoot)/")
                && entry.path.hasSuffix(".xcent")
                && entry.uncompressedSize <= limits.maximumMetadataSize
        }

        return entitlementEntries.reduce(into: Set<String>()) { keys, entry in
            guard let info = try? propertyList(
                from: entry,
                in: archive,
                maximumSize: limits.maximumMetadataSize
            ) else {
                return
            }
            keys.formUnion(info.keys)
        }
    }

    /// 预检 IPA 中可能导致签名失败的问题，返回用户可读的警告
    private func detectImportWarnings(
        appRoot: String,
        entries: [Entry],
        archive: Archive
    ) -> [String] {
        var warnings: [String] = []

        // 检测加密 IPA（App Store 下载的加密 IPA 无法签名）
        if isEncryptedBinary(appRoot: appRoot, entries: entries, archive: archive) {
            warnings.append("主二进制已加密（App Store 版本），需要砸壳后才能签名")
        }

        // 检测 Watch app（免费账号不支持）
        let hasWatchApp = entries.contains { entry in
            entry.path.hasPrefix("\(appRoot)/Watch/")
                && entry.path.hasSuffix(".app/Info.plist")
        }
        if hasWatchApp {
            warnings.append("包含 Apple Watch 应用，免费账号签名时会自动移除 Watch 部分")
        }

        // 检测包内证书文件（可疑，可能导致签名问题）
        let hasEmbeddedCertificate = entries.contains { entry in
            let lower = entry.path.lowercased()
            return lower.hasSuffix(".p12")
                || lower.hasSuffix(".cer")
                || lower.hasSuffix(".cert")
                || lower.hasSuffix(".mobileprovision")
        }
        if hasEmbeddedCertificate {
            warnings.append("包内包含证书或描述文件，签名时会被移除")
        }

        // 检测越狱运行时（substrate 等）
        let hasJailbreakRuntime = entries.contains { entry in
            let lower = entry.path.lowercased()
            return lower.contains("substrate")
                || lower.contains("cycript")
                || lower.contains("rocketbootstrap")
                || lower.contains("liberty")
        }
        if hasJailbreakRuntime {
            warnings.append("包含越狱运行时或插件，可能影响签名稳定性")
        }

        // 检测扩展数量
        let extensionCount = entries.filter { entry in
            entry.path.hasPrefix("\(appRoot)/PlugIns/")
                && entry.path.hasSuffix(".appex/Info.plist")
        }.count
        if extensionCount > 3 {
            warnings.append("包含 \(extensionCount) 个应用扩展，部分扩展可能无法签名")
        }

        return warnings
    }

    /// 检测主二进制是否加密（App Store 下载的 IPA 是加密的，无法签名）
    /// 解析 Mach-O 格式，检查 LC_ENCRYPTION_INFO_64 的 cryptid
    private func isEncryptedBinary(
        appRoot: String,
        entries: [Entry],
        archive: Archive
    ) -> Bool {
        // 主二进制文件名 = app 目录名（去掉 .app 后缀）
        let appDirName = URL(filePath: appRoot).lastPathComponent
        let binaryName = appDirName.replacingOccurrences(of: ".app", with: "")
        let binaryPath = "\(appRoot)/\(binaryName)"

        guard let binaryEntry = entries.first(where: {
            $0.type == .file && $0.path == binaryPath
        }) else {
            return false
        }

        // 读取二进制前 4KB（足够解析 Mach-O 头部和加载命令）
        var binaryData = Data()
        binaryData.reserveCapacity(min(Int(binaryEntry.uncompressedSize), 4096))
        do {
            _ = try archive.extract(binaryEntry) { chunk in
                if binaryData.count < 4096 {
                    binaryData.append(chunk)
                }
            }
        } catch {
            return false
        }

        guard binaryData.count >= 32 else { return false }

        // 读取魔数（小端序）
        let magic = binaryData.withUnsafeBytes { $0.load(as: UInt32.self) }

        // fat binary (0xCAFEBABE)：包含多架构，假设未加密（通常是砸壳后的）
        if magic == 0xCAFEBABE || magic.bigEndian == 0xCAFEBABE {
            return false
        }

        // 64位 Mach-O: 0xFEEDFACF (小端) 或 0xCFFAEDFE (大端读取)
        let is64Bit = magic == 0xFEEDFACF || magic == 0x0100000C
        guard is64Bit else {
            // 32位 Mach-O 已很少见，跳过检测
            return false
        }

        // 解析 64位 Mach-O 头部
        // struct mach_header_64 { magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved }
        let ncmds = binaryData.withUnsafeBytes {
            $0.load(fromByteOffset: 16, as: UInt32.self)
        }
        let sizeofcmds = binaryData.withUnsafeBytes {
            $0.load(fromByteOffset: 20, as: UInt32.self)
        }

        var offset = 32  // mach_header_64 大小
        let endOffset = min(32 + Int(sizeofcmds), binaryData.count)

        // 遍历加载命令，找 LC_ENCRYPTION_INFO_64 (0x2C)
        for _ in 0..<ncmds {
            guard offset + 8 <= endOffset else { break }
            let cmd = binaryData.withUnsafeBytes {
                $0.load(fromByteOffset: offset, as: UInt32.self)
            }
            let cmdsize = binaryData.withUnsafeBytes {
                $0.load(fromByteOffset: offset + 4, as: UInt32.self)
            }

            // LC_ENCRYPTION_INFO_64 = 0x2C
            if cmd == 0x2C || cmd.bigEndian == 0x2C {
                // struct encryption_info_command_64 { cmd, cmdsize, cryptoff, cryptsize, cryptid, pad }
                guard offset + 20 <= binaryData.count else { break }
                let cryptid = binaryData.withUnsafeBytes {
                    $0.load(fromByteOffset: offset + 16, as: UInt32.self)
                }
                return cryptid != 0
            }

            offset += Int(cmdsize)
        }

        return false
    }

    private func sourceFileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else { return 0 }
        return number.int64Value
    }

    private func sizeFailure(detail: String) -> ImportFailure {
        failure(
            title: "IPA 过大",
            reason: detail,
            recovery: "选择较小的 IPA",
            code: "SEAL-IPA-105"
        )
    }

    private func failure(
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
