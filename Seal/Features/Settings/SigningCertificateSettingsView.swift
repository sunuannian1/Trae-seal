import SwiftUI

struct SigningCertificateSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let relatedApps: [AppRecord]
    let certificateExportHandler: CertificateExportHandler
    @State private var selectedAccountID: UUID?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                accountCard

                Text("签名证书")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.sealTextSecondary)
                    .padding(.leading, 8)

                certificateContent
            }
            .padding(20)
        }
        .navigationTitle("签名证书")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $viewModel.alertFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.userMessage),
                dismissButton: .default(Text(failure.recovery))
            )
        }
        .task {
            if selectedAccountID == nil {
                selectedAccountID = viewModel.activeAccount?.id
            }
            await viewModel.load(force: true)
            if let account = activeAccount {
                await viewModel.refreshCertificateInventory(for: account, force: true)
            }
        }
        .refreshable {
            await viewModel.load(force: true)
            if let account = activeAccount {
                await viewModel.refreshCertificateInventory(for: account, force: true)
            }
        }
        .sealScreenBackground()
    }

    private var activeAccount: AppleAccountRecord? {
        if let id = selectedAccountID, let account = viewModel.accounts.first(where: { $0.id == id }) {
            return account
        }
        return viewModel.activeAccount
    }

    private var selectableAccounts: [AppleAccountRecord] {
        viewModel.accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
    }

    @ViewBuilder
    private var accountCard: some View {
        VStack(spacing: 0) {
            if selectableAccounts.isEmpty {
                Text("请先添加并验证 Apple ID")
                    .foregroundStyle(Color.sealTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            } else {
                Menu {
                    ForEach(selectableAccounts) { account in
                        Button {
                            selectedAccountID = account.id
                            Task {
                                await viewModel.selectActiveAccount(account)
                                await viewModel.refreshCertificateInventory(for: account, force: true)
                            }
                        } label: {
                            Text(viewModel.fullEmail(for: account))
                            if account.id == activeAccount?.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Apple ID")
                            .foregroundStyle(.primary)
                        Spacer()
                        if let account = activeAccount {
                            Text(viewModel.fullEmail(for: account))
                                .foregroundStyle(Color.sealTextSecondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(Color.sealTextSecondary)
                        } else {
                            Text("请选择")
                                .foregroundStyle(Color.sealTextSecondary)
                        }
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let account = activeAccount {
                    Divider()
                    detailRow("Team", TeamNameDisplayFormatter.string(from: account.teamName))
                    Divider()
                    detailRow("Team ID", account.teamID.isEmpty ? "—" : account.teamID)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: 24)
    }

    @ViewBuilder
    private var certificateContent: some View {
        if let account = activeAccount {
            if account.certificateSerialNumber?.isEmpty == false {
                localCertificateCard(account: account)
            } else {
                missingCertificateCard
            }
        } else {
            noAccountCard
        }
    }

    private func localCertificateCard(account: AppleAccountRecord) -> some View {
        let health = viewModel.certificateHealthStatus(for: account.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text("Apple 开发证书")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                Spacer(minLength: 12)
                Text(certificateSummary(health))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(certificateSummaryColor(health))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        certificateSummaryColor(health).opacity(0.12),
                        in: Capsule()
                    )
            }
            .padding(.bottom, 14)

            Divider()

            VStack(spacing: 0) {
                certificateHealthRow(
                    expirationTitle(health),
                    value: expirationText(health),
                    state: nil
                )
                Divider()
                certificateHealthRow(
                    "Apple 侧可用于本机",
                    value: usableAppIDCountText(health),
                    state: nil
                )
                Divider()
                Button {
                    certificateExportHandler.exportToLiveContainer()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                        Text("导出证书给 LiveContainer")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Color.sealTextSecondary)
                    }
                    .foregroundStyle(Color.sealAccent)
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface(cornerRadius: 24)
    }

    private func certificateHealthRow(
        _ title: String,
        value: String,
        state: CertificateHealthStatus.CheckState?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(Color.sealTextSecondary)
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                if let state {
                    Image(systemName: stateIcon(state))
                        .foregroundStyle(stateColor(state))
                        .accessibilityHidden(true)
                }
                Text(value)
                    .foregroundStyle(state.map { stateColor($0) } ?? Color.primary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)")
    }

    private func certificateSummary(_ health: CertificateHealthStatus?) -> String {
        guard let health else { return "检查中" }
        if health.expirationState == .invalid { return "无效" }
        return health.isUsable ? "可用" : "无效"
    }

    private func certificateSummaryColor(_ health: CertificateHealthStatus?) -> Color {
        guard let health else { return Color.sealTextSecondary }
        if health.expirationState == .invalid { return Color.sealDanger }
        return health.isUsable ? Color.sealSuccess : Color.sealWarning
    }

    private func stateIcon(_ state: CertificateHealthStatus.CheckState) -> String {
        switch state {
        case .valid: "checkmark.circle.fill"
        case .invalid: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func stateColor(_ state: CertificateHealthStatus.CheckState) -> Color {
        switch state {
        case .valid: Color.sealSuccess
        case .invalid: Color.sealDanger
        case .unknown: Color.sealTextSecondary
        }
    }

    private func expirationText(_ health: CertificateHealthStatus?) -> String {
        guard let health, let expirationDate = health.expirationDate else {
            return "无法确认"
        }
        return SealSettingsDateFormatter.string(from: expirationDate)
    }

    private func expirationTitle(_ health: CertificateHealthStatus?) -> String {
        health?.expirationState == .invalid ? "证书已过期" : "证书有效期至"
    }

    private func relatedAppCountText(_ health: CertificateHealthStatus?) -> String {
        guard let count = health?.relatedAppCount else { return "无法确认" }
        return count == 0 ? "尚未使用" : "\(count) 个 App"
    }

    private func usableAppIDCountText(_ health: CertificateHealthStatus?) -> String {
        guard let count = health?.usableOnCurrentDeviceAppIDCount else { return "无法确认" }
        return "\(count) 个 App ID"
    }

    private var missingCertificateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前没有本机可用证书")
                .font(.headline)
            Text("首次签名时将自动创建。")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface(cornerRadius: 20)
    }

    private var noAccountCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(Color.sealWarning)
            Text("未选择 Apple ID")
                .font(.headline)
            Text("返回 Apple ID 页面，选择一个已验证账号。")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassSurface(cornerRadius: 24)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 15)
    }
}
