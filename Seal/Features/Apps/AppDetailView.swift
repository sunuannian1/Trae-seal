import SwiftUI
import UIKit

struct AppDetailView: View {
    let appID: UUID
    @ObservedObject var viewModel: AppsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showExtensions = false

    var body: some View {
        Group {
            if let app = viewModel.apps.first(where: { $0.id == appID }) {
                SealDrawer(title: "应用详情") {
                    VStack(alignment: .leading, spacing: 18) {
                        header(app)
                        infoCard(app)
                    }
                    .padding(.bottom, 8)
                } footer: {
                    if app.belongsInInstalledList {
                        VStack(spacing: 10) {
                            Button(AppSigningPresentationHelpers.renewNowAction) {
                                dismiss()
                                Task { await viewModel.beginRenewalDirectly(for: app) }
                            }
                            .sealPrimaryAction(cornerRadius: 14)
                        }
                    } else {
                        Button("关闭") { dismiss() }
                            .sealOutlineAction(cornerRadius: 14)
                    }
                }
            } else {
                SealDrawer(title: "应用详情") {
                    VStack(spacing: 12) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("应用不存在")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                } footer: {
                    Button("关闭") { dismiss() }
                        .sealOutlineAction(cornerRadius: 14)
                }
            }
        }
        .alert(item: $viewModel.alertFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.userMessage),
                dismissButton: .default(Text(failure.recovery))
            )
        }
    }

    private func header(_ app: AppRecord) -> some View {
        HStack(spacing: 16) {
            icon(app, size: 72)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("v\(app.version) · \(app.size.sealFormattedByteCount)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private func infoCard(_ app: AppRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailRow("当前状态", app.belongsInInstalledList ? "已安装" : app.state.title)
            Divider()
            detailRow("签名账户", accountName(app))
            Divider()
            detailRow("签名证书", certificateName(app))
            Divider()
            detailRow("Team ID", app.signingTeamID ?? "未记录")
            Divider()
            identifierDetailRow("签名 Bundle ID", signedBundleIdentifier(app), highlightSeal: true)
            Divider()
            identifierDetailRow("原始 Bundle ID", app.originalBundleIdentifier, highlightSeal: false)
            Divider()
            detailRow("描述文件", profileStatus(app).title, valueColor: profileColor(app))
            Divider()
            detailRow("描述文件有效期至", expiryDateText(app), valueColor: profileColor(app))
            Divider()
            if app.extensions.isEmpty {
                detailRow("扩展", "无")
            } else {
                Button {
                    showExtensions.toggle()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("扩展")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 12)
                        Text("\(app.extensions.count) 个")
                            .foregroundStyle(Color.sealTextSecondary)
                        Image(systemName: showExtensions ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.sealAccent)
                    }
                    .padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // 每个插件有独立的描述文件与有效期（独立 App ID，随续签一起刷新）。
                // 逐插件展示到期时间，便于验证续签后插件 profile 是否已更新。
                if showExtensions {
                    ForEach(
                        app.extensions.sorted(by: { $0.originalBundleIdentifier < $1.originalBundleIdentifier }),
                        id: \.id
                    ) { extensionRecord in
                        Divider()
                        detailRow(
                            "插件·\(extensionRecord.name)",
                            extensionExpiryText(extensionRecord),
                            valueColor: extensionExpiryColor(extensionRecord)
                        )
                    }
                }
            }
            if app.belongsInInstalledList {
                Divider()
                detailRow("签名记录", signingRecordSummary(app))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: 24)
    }

    private func detailRow(_ title: String, _ value: String, valueColor: Color = Color.sealTextSecondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .padding(.vertical, 15)
    }

    private func identifierDetailRow(
        _ title: String,
        _ value: String,
        highlightSeal: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            bundleIdentifierValue(value, highlightSeal: highlightSeal)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 15)
    }

    private func bundleIdentifierValue(_ value: String, highlightSeal: Bool) -> Text {
        var attributed = AttributedString(value)
        attributed.foregroundColor = Color.sealTextSecondary
        if highlightSeal, let range = attributed.range(of: ".seal", options: .backwards) {
            attributed[range].foregroundColor = Color.sealAccent
        }
        return Text(attributed)
    }

    @ViewBuilder
    private func icon(_ app: AppRecord, size: CGFloat) -> some View {
        Group {
            if let data = viewModel.iconData[app.id], let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .foregroundStyle(Color.sealAccent)
                    .background(Color.sealSurfaceElevated)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func accountName(_ app: AppRecord) -> String {
        guard let account = viewModel.accounts.first(where: { $0.id == app.accountID }) else {
            return "未记录"
        }
        return viewModel.fullEmail(for: account)
    }

    private func certificateName(_ app: AppRecord) -> String {
        if let serial = app.certificateSerialNumber, serial.isEmpty == false {
            return AppSigningPresentationHelpers.certificateName(serial: serial)
        }
        if let serial = app.signingTargets
            .flatMap(\.certificateSerialNumbers)
            .first(where: { $0.isEmpty == false }) {
            return AppSigningPresentationHelpers.certificateName(serial: serial)
        }
        return app.belongsInInstalledList ? "未记录" : "签名时创建"
    }

    private func signedBundleIdentifier(_ app: AppRecord) -> String {
        app.mappedBundleIdentifier
            ?? app.preferredBundleIdentifier
            ?? (app.belongsInInstalledList ? "未记录" : app.originalBundleIdentifier)
    }

    private func profileStatus(_ app: AppRecord) -> ProfileDisplayStatus {
        AppSigningPresentationHelpers.profileStatus(for: app)
    }

    private func profileColor(_ app: AppRecord) -> Color {
        switch profileStatus(app).tone {
        case .success: .sealSuccess
        case .warning: .sealWarning
        case .danger: .sealDanger
        case .neutral: .sealTextSecondary
        }
    }

    private func expiryDateText(_ app: AppRecord) -> String {
        guard let date = AppSigningPresentationHelpers.profileExpirationDate(for: app) else { return "未记录" }
        return SealSettingsDateFormatter.string(from: date)
    }

    private func extensionExpiryText(_ record: AppExtensionRecord) -> String {
        guard let date = record.provisioningProfileExpirationDate else { return "未签名" }
        return SealSettingsDateFormatter.string(from: date)
    }

    private func extensionExpiryColor(_ record: AppExtensionRecord) -> Color {
        guard let date = record.provisioningProfileExpirationDate else { return .sealTextSecondary }
        let remaining = date.timeIntervalSinceNow
        if remaining < 0 { return .sealDanger }
        if remaining < 2 * 24 * 3600 { return .sealWarning }
        return .sealSuccess
    }

    private func entitlementSummary(_ app: AppRecord) -> String {
        if let status = app.entitlementValidationStatus, status.isEmpty == false { return status }
        if let status = app.capabilityValidationStatus, status.isEmpty == false { return status }
        return app.belongsInInstalledList ? "已通过" : "签名后校验"
    }

    private func signingRecordSummary(_ app: AppRecord) -> String {
        guard let lastSignedAt = app.lastSignedAt else { return "未记录" }
        return "最近成功 · \(SealSettingsDateFormatter.string(from: lastSignedAt))"
    }
}
