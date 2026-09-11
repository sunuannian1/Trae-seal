import SwiftUI
import UIKit

struct SettingsRootView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let relatedApps: [AppRecord]
    let certificateExportHandler: CertificateExportHandler
    let onSelfUpdateInstall: ((URL) -> Void)?

    @State private var navigationPath = NavigationPath()
    @State private var isAddingAccount = false
    @State private var isAppearanceThemePresented = false

    @AppStorage("appearance.mode") private var appearanceRawValue = SealAppearance.system.rawValue
    @AppStorage("appearance.accent") private var accentRawValue = SealAccentTheme.system.rawValue

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    settingsSection("签名") {
                        settingsLink(value: SettingsRoute.pairing) {
                            settingsRow(
                                title: "设备",
                                value: devicePairingSummary,
                                icon: "iphone",
                                showsChevron: true
                            )
                        }
                        sectionDivider

                        settingsLink(value: SettingsRoute.account) {
                            settingsRow(
                                title: "Apple ID",
                                value: nil,
                                icon: "person.crop.circle",
                                showsChevron: true
                            )
                        }
                        sectionDivider

                        settingsLink(value: SettingsRoute.certificates) {
                            settingsRow(
                                title: "签名证书",
                                value: nil,
                                icon: "rectangle.stack.person.crop",
                                showsChevron: true
                            )
                        }
                        sectionDivider
                    }

                    settingsSection("到期提醒") {
                        Toggle(isOn: Binding(
                            get: { viewModel.notificationsEnabled },
                            set: { enabled in
                                Task { await viewModel.setNotificationsEnabled(enabled) }
                            }
                        )) {
                            settingsRow(
                                title: "提前 24 小时提醒",
                                value: nil,
                                icon: "bell.badge",
                                showsChevron: false,
                                iconColor: .orange
                            )
                        }
                        .tint(.sealAccent)

                        if viewModel.notificationsEnabled {
                            sectionDivider
                            settingsRow(
                                title: "下次提醒",
                                value: notificationReminderText,
                                icon: "clock",
                                showsChevron: false,
                                iconColor: .orange
                            )
                        }
                    }

                    settingsSection("管理") {
                        Button { isAppearanceThemePresented = true } label: {
                            settingsRow(
                                title: "外观与主题",
                                value: "\(currentAppearanceTitle) · \(currentAccentTitle)",
                                icon: "circle.lefthalf.filled",
                                showsChevron: true
                            )
                        }
                        .buttonStyle(.plain)
                        sectionDivider

                        settingsLink(value: SettingsRoute.storage) {
                            settingsRow(
                                title: "存储与清理",
                                value: viewModel.storageUsage.total.formattedByteCount,
                                icon: "internaldrive",
                                showsChevron: true,
                                iconColor: Color.sealAccent
                            )
                        }
                    }

                    settingsSection("帮助") {
                        NavigationLink { SigningAndRenewalGuideView() } label: {
                            settingsRow(
                                title: "签名与续签",
                                value: nil,
                                icon: "book.pages",
                                showsChevron: true
                            )
                        }
                        .buttonStyle(.plain)
                        sectionDivider

                        NavigationLink { PrivacyNoticeView() } label: {
                            settingsRow(
                                title: "本机签名与凭据说明",
                                value: nil,
                                icon: "lock.shield",
                                showsChevron: true
                            )
                        }
                        .buttonStyle(.plain)
                        sectionDivider

                        NavigationLink { AboutView(onInstall: onSelfUpdateInstall) } label: {
                            settingsRow(
                                title: "关于 Seal",
                                value: "版本 \(appVersion)",
                                icon: "info.circle",
                                showsChevron: true
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    settingsSection("社群") {
                        NavigationLink { SealCommunityView() } label: {
                            settingsRow(
                                title: "加入 Seal 社群",
                                value: nil,
                                icon: "person.3",
                                showsChevron: true,
                                iconColor: Color.sealAccent,
                                iconImage: "SealCommunityIcon"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 34)
            }
            .navigationTitle("我的")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .account:
                    CertificatesRootView(viewModel: viewModel, relatedApps: relatedApps)
                case .addAccount:
                    EmptyView()
                case .certificates:
                    SigningCertificateSettingsView(viewModel: viewModel, relatedApps: relatedApps, certificateExportHandler: certificateExportHandler)
                case .accountDetail(let id):
                    if let account = viewModel.accounts.first(where: { $0.id == id }) {
                        AppleAccountDetailView(
                            account: account,
                            relatedApps: relatedApps,
                            viewModel: viewModel
                        )
                    }
                case .pairing:
                    PairingSettingsView(viewModel: viewModel)
                case .localDevVPN:
                    LocalDevVPNSettingsView(viewModel: viewModel)
                case .storage:
                    StorageMaintenanceView(viewModel: viewModel)
                }
            }
            .alert(item: $viewModel.alertFailure) { failure in
                Alert(
                    title: Text(failure.title),
                    message: Text(failure.userMessage),
                    dismissButton: .default(Text(failure.recovery))
                )
            }
            .task { await viewModel.load() }
            .refreshable {
                await viewModel.load(force: true)
                await viewModel.refreshStorageUsage()
            }
            .onChange(of: viewModel.requestedRoute) { route in
                guard let route else { return }
                viewModel.requestedRoute = nil
                if route == .addAccount {
                    isAddingAccount = true
                    return
                }
                navigationPath.append(route)
            }
            .fullScreenCover(isPresented: $isAddingAccount) {
                AddAccountView(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $isAppearanceThemePresented) {
            AppearanceThemeSheet(
                appearanceRawValue: $appearanceRawValue,
                accentRawValue: $accentRawValue
            )
            .presentationDetents([.height(390), .medium])
            .presentationDragIndicator(.hidden)
        }        .sealScreenBackground()
    }

    private var appearanceCard: some View {
        Button { isAppearanceThemePresented = true } label: {
            HStack(spacing: 16) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.sealAccent)
                    .frame(width: 34)
                Text("外观与主题")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text("\(currentAppearanceTitle) · \(currentAccentTitle)")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 56)
            .padding(.horizontal, 16)
            .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private var currentAppearanceTitle: String {
        (SealAppearance(rawValue: appearanceRawValue) ?? .system).title
    }

    private var currentAccentTitle: String {
        (SealAccentTheme(rawValue: accentRawValue) ?? .system).title
    }

    private func appearanceIcon(_ appearance: SealAppearance) -> String {
        switch appearance {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.leading, 8)
            VStack(spacing: 0, content: content)
                .padding(.horizontal, 16)
                .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
                }
        }
    }

    private func settingsLink<Label: View>(
        value: SettingsRoute,
        @ViewBuilder label: () -> Label
    ) -> some View {
        NavigationLink(value: value, label: label)
            .buttonStyle(.plain)
    }

    private func settingsRow(
        title: String,
        value: String?,
        icon: String,
        showsChevron: Bool,
        iconColor: Color = Color.sealAccent,
        iconImage: String? = nil
    ) -> some View {
        HStack(spacing: 16) {
            if let iconImage {
                Image(iconImage)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(iconColor)
                    .frame(width: 34)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 34)
            }
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .font(.system(size: 16, weight: .medium))
            Spacer(minLength: 12)
            if let value {
                Text(value)
                    .foregroundStyle(Color.sealTextSecondary)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 0, alignment: .trailing)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var sectionDivider: some View {
        Divider().padding(.leading, 50)
    }

    private var accountSummary: String {
        if let account = viewModel.activeAccount { return viewModel.fullEmail(for: account) }
        if viewModel.accounts.isEmpty { return "未添加" }
        return "请选择"
    }

    private var certificateSummary: String {
        guard let account = viewModel.activeAccount else { return "不可用" }
        let serial = account.selectedCertificateSerialNumber
            ?? account.certificateSerialNumber
        guard serial != nil else { return "签名时创建" }
        return "本机可用"
    }

    private var devicePairingSummary: String {
        guard let pairing = viewModel.pairingRecord else { return "未导入" }
        return pairing.validationStatus.title
    }

    private var notificationReminderText: String {
        guard viewModel.notificationsEnabled else { return "关" }
        let status = viewModel.notificationStatus
        if let failure = status.schedulingFailure, failure.isEmpty == false {
            return "设置失败"
        }
        guard status.authorization == .allowed else {
            return status.authorization == .denied ? "权限关闭" : "等待授权"
        }
        guard status.soundEnabled else {
            return "声音关闭"
        }
        guard let nextDate = status.nextReminderDate else {
            return "暂无提醒"
        }
        return SealSettingsDateFormatter.string(from: nextDate)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}

private func sectionTitle(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.sealTextSecondary)
}
private struct AppearanceModeControl: View {
    @Binding var appearanceRawValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("外观模式")
            HStack(spacing: 4) {
                ForEach(SealAppearance.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            appearanceRawValue = item.rawValue
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: appearanceIcon(item))
                                .font(.system(size: 13, weight: .semibold))
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(appearanceRawValue == item.rawValue ? Color.sealAccent : Color.sealTextSecondary)
                        .background {
                            if appearanceRawValue == item.rawValue {
                                Capsule(style: .continuous)
                                    .fill(Color.sealAccent.opacity(0.12))
                                    .overlay {
                                        Capsule(style: .continuous)
                                            .stroke(Color.sealAccent.opacity(0.24), lineWidth: 0.8)
                                    }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.sealSurfaceElevated, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.sealHairline.opacity(0.55), lineWidth: 0.8)
            }
        }
    }

    private func appearanceIcon(_ appearance: SealAppearance) -> String {
        switch appearance {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

private struct AccentThemeGrid: View {
    @Binding var accentRawValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("主题色")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                ForEach(SealAccentTheme.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            accentRawValue = item.rawValue
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(item.color)
                                .frame(width: 12, height: 12)
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(accentRawValue == item.rawValue ? Color.sealAccent : Color.sealTextSecondary)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(accentRawValue == item.rawValue ? Color.sealAccent.opacity(0.12) : Color.sealSurfaceElevated)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(accentRawValue == item.rawValue ? Color.sealAccent.opacity(0.30) : Color.sealHairline.opacity(0.45), lineWidth: 0.8)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct AppearanceThemeSheet: View {
    @Binding var appearanceRawValue: String
    @Binding var accentRawValue: String

    var body: some View {
        SealDrawer(title: "\u{5916}\u{89C2}\u{4E0E}\u{4E3B}\u{9898}") {
            VStack(spacing: 14) {
                appearanceCard
                accentCard
            }
            .padding(.bottom, 12)
        }
    }

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            drawerSectionTitle("\u{5916}\u{89C2}")
            appearanceSegment
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    private var accentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            drawerSectionTitle("\u{4E3B}\u{9898}\u{8272}")
            accentThemeGrid
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    private var appearanceSegment: some View {
        HStack(spacing: 4) {
            ForEach(SealAppearance.allCases) { item in
                Button {
                    appearanceRawValue = item.rawValue
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: appearanceIcon(item))
                            .font(.system(size: 13, weight: .semibold))
                        Text(appearanceDisplayTitle(item))
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .foregroundStyle(
                        appearanceRawValue == item.rawValue
                            ? Color.sealAccent
                            : Color.sealTextSecondary
                    )
                    .background {
                        if appearanceRawValue == item.rawValue {
                            Capsule(style: .continuous)
                                .fill(Color.sealAccent.opacity(0.12))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .stroke(Color.sealAccent.opacity(0.24), lineWidth: 0.8)
                                }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.sealSurfaceElevated, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.sealHairline.opacity(0.55), lineWidth: 0.8)
        }
    }

    private var accentThemeGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 10),
                count: 3
            ),
            spacing: 10
        ) {
            ForEach(SealAccentTheme.allCases) { item in
                Button {
                    accentRawValue = item.rawValue
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 12, height: 12)

                        Text(accentDisplayTitle(item))
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)

                        Spacer(minLength: 0)

                        if accentRawValue == item.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .foregroundStyle(
                        accentRawValue == item.rawValue
                            ? item.color
                            : Color.sealTextSecondary
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                accentRawValue == item.rawValue
                                    ? item.color.opacity(0.12)
                                    : Color.sealSurfaceElevated
                            )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                accentRawValue == item.rawValue
                                    ? item.color.opacity(0.34)
                                    : Color.sealHairline.opacity(0.45),
                                lineWidth: 0.8
                            )
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func appearanceDisplayTitle(_ appearance: SealAppearance) -> String {
        switch appearance {
        case .system: return "\u{81EA}\u{52A8}"
        case .light: return "\u{6D45}\u{8272}"
        case .dark: return "\u{6DF1}\u{8272}"
        }
    }

    private func accentDisplayTitle(_ theme: SealAccentTheme) -> String {
        switch theme {
        case .system: return "\u{7ECF}\u{5178}\u{84DD}"
        case .green: return "\u{7FE1}\u{7FE0}\u{7EFF}"
        case .blue: return "\u{6674}\u{7A7A}\u{9752}"
        case .purple: return "\u{7D2B}\u{7F57}\u{5170}"
        case .amber: return "\u{7425}\u{73C0}\u{6A59}"
        case .pink: return "\u{73AB}\u{7470}\u{7C89}"
        }
    }
    private func drawerSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.sealTextSecondary)
    }

    private func appearanceIcon(_ appearance: SealAppearance) -> String {
        switch appearance {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}
private extension Int64 {
    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

