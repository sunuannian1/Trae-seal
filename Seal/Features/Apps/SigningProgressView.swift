import SwiftUI
import UIKit

struct SigningProgressView: View {
    @ObservedObject var viewModel: AppsViewModel
    let onFinish: (SigningCompletionMode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var verificationCode = ""

    var body: some View {
        SealDrawer(title: title, showsFooter: !isRunning) {
            VStack(spacing: 14) {
                if let app = session?.app {
                    appIdentity(app)
                }

                statusContent

                if let session {
                    signingRuntimeCard(session)
                }
            }
            .padding(.bottom, 12)
        } footer: {
            actions
        }
        .interactiveDismissDisabled(isRunning)
        .sheet(isPresented: Binding(
            get: { viewModel.signingVerificationBroker.isRequested },
            set: { _ in }
        )) {
            verificationCodeSheet
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch session?.status {
        case .running(let stage):
            runningContent(stage)
        case .succeeded(let installed):
            successContent(installed)
        case .failed(let failure):
            failureContent(failure)
        case nil:
            EmptyView()
        }
    }

    private func runningContent(_ stage: SigningStage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                progressRing(stage)
                Text(stage.stageTitle(isRenewal: isRenewal))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            if stage == .pushing, let progress = session?.installProgress, progress >= 0, progress <= 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("正在传输到设备")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.sealTextSecondary)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.sealAccent)
                            .monospacedDigit()
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color.sealAccent)
                }
                .padding(10)
                .background(Color.sealAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if isRenewal {
                Text(AppSigningPresentationHelpers.keepSealOpenTip)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.sealAccent)
            }

            stageProgressSection(stage)
        }
        .padding(14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    private func stageProgressSection(_ stage: SigningStage) -> some View {
        let current = timelinePosition(for: stage)
        return VStack(alignment: .leading, spacing: 8) {
            Text(isRenewal ? "续签进度" : "签名进度")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.sealTextSecondary)
            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { index in
                    progressSegment(index: index, current: current, fraction: segmentFraction(for: stage))
                }
            }
        }
    }

    @ViewBuilder
    private func progressSegment(index: Int, current: Int, fraction: CGFloat) -> some View {
        if index < current {
            Capsule()
                .fill(Color.sealSuccess)
                .frame(height: 6)
                .frame(maxWidth: .infinity)
        } else if index == current {
            CurrentSegmentFill(fraction: fraction)
                .frame(maxWidth: .infinity)
        } else {
            Capsule()
                .fill(Color.sealTextSecondary.opacity(0.22))
                .frame(height: 6)
                .frame(maxWidth: .infinity)
        }
    }

    private func segmentFraction(for stage: SigningStage) -> CGFloat {
        switch stage {
        case .waitingForChannel: return 0.5
        case .preparingAccount: return 0.33
        case .preparingCertificate: return 0.67
        case .preparingAppID: return 0.33
        case .preparingProfiles: return 0.67
        case .signing: return 0.5
        case .pushing:
            let p = session?.installProgress ?? 0
            return 0.3 + 0.3 * CGFloat(max(0, min(1, p)))
        case .installing: return 0.8
        case .verifying: return 1.0
        }
    }

    private func progressRing(_ stage: SigningStage) -> some View {
        let progress = overallProgress(for: stage)
        return ZStack {
            Circle()
                .stroke(Color.sealTextSecondary.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(Color.sealAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.45), value: progress)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.sealAccent)
                .monospacedDigit()
        }
        .frame(width: 50, height: 50)
    }

    private func overallProgress(for stage: SigningStage) -> CGFloat {
        switch stage {
        case .waitingForChannel: return 0.06
        case .preparingAccount: return 0.16
        case .preparingCertificate: return 0.30
        case .preparingAppID: return 0.42
        case .preparingProfiles: return 0.54
        case .signing: return 0.68
        case .pushing:
            let p = session?.installProgress ?? 0
            return 0.78 + 0.12 * CGFloat(max(0, min(1, p)))
        case .installing: return 0.93
        case .verifying: return 0.99
        }
    }

    private func successContent(_ installed: AppRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.sealSuccess)
            VStack(alignment: .leading, spacing: 3) {
                Text(successTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text(expiryText(for: installed))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.sealTextSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func failureContent(_ failure: ImportFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.sealDanger)
                Text(failure.title)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            Text(userFacingReason(failure))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.sealTextSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            // Only show recovery hint when it differs from primary action button
            let recovery = recoveryText(failure)
            if recovery.isEmpty == false, recovery != primaryRecoveryTitle(failure) {
                Text(recovery)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.sealAccent)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.sealDanger.opacity(0.18), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch session?.status {
        case .running:
            EmptyView()

        case .succeeded:
            Button("完成") { finish() }
                .sealPrimaryAction(cornerRadius: 14)

        case .failed(let failure):
            Button(primaryRecoveryTitle(failure)) {
                performPrimaryRecovery(failure)
            }
            .sealPrimaryAction(cornerRadius: 14)
        case nil:
            EmptyView()
        }
    }

    private func signingRuntimeCard(_ session: SigningSession) -> some View {
        VStack(spacing: 0) {
            runtimeRow("签名账户", viewModel.fullEmail(for: session.account))
            Divider().padding(.leading, 14)
            runtimeRow("Apple ID 证书", certificateDisplayName(session))
            Divider().padding(.leading, 14)
            runtimeRow("Bundle ID", runtimeBundleIdentifier(session))
        }
        .padding(.horizontal, 14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    private func runtimeRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: title.contains("Bundle") ? .monospaced : .default))
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .frame(minHeight: 42)
    }

    private func certificateDisplayName(_ session: SigningSession) -> String {
        guard let serial = session.selectedCertificateSerialNumber ?? session.account.certificateSerialNumber,
              serial.isEmpty == false else {
            return "未准备"
        }
        return "可用"
    }

    private func runtimeBundleIdentifier(_ session: SigningSession) -> String {
        if let requested = session.requestedBundleIdentifier, requested.isEmpty == false {
            return requested
        }
        return displayBundleIdentifier(session.app)
    }

    private func appIdentity(_ app: AppRecord) -> some View {
        HStack(spacing: 14) {
            appIcon(app, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.displayName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("v\(app.version) · \(app.size.sealFormattedByteCount)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displayBundleIdentifier(_ app: AppRecord) -> String {
        if app.isSeal { return app.mappedBundleIdentifier ?? app.preferredBundleIdentifier ?? app.originalBundleIdentifier }
        if app.belongsInInstalledList || app.belongsInSignedList { return app.mappedBundleIdentifier ?? app.preferredBundleIdentifier ?? app.originalBundleIdentifier }
        return app.preferredBundleIdentifier ?? app.originalBundleIdentifier
    }

    @ViewBuilder
    private func appIcon(_ app: AppRecord, size: CGFloat) -> some View {
        Group {
            if let data = viewModel.iconData[app.id], let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(11)
                    .foregroundStyle(Color.sealAccent)
                    .background(Color.sealSurface)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var session: SigningSession? { viewModel.signingSession }
    private var isRenewal: Bool { session?.app.belongsInInstalledList == true }

    private var title: String {
        switch session?.status {
        case .running: isRenewal ? "正在续签" : "正在签名"
        case .succeeded: isRenewal ? "续签完成" : "签名完成"
        case .failed: isRenewal ? "续签失败" : "签名失败"
        case nil: "签名"
        }
    }

    private var isRunning: Bool {
        if case .running = session?.status { return true }
        return false
    }

    private func timelinePosition(for stage: SigningStage) -> Int {
        switch stage {
        case .waitingForChannel: 0
        case .preparingAccount, .preparingCertificate: 1
        case .preparingAppID, .preparingProfiles: 2
        case .signing: 3
        case .pushing, .installing, .verifying: 4
        }
    }

    private var successTitle: String {
        guard session != nil else { return "签名完成" }
        return isRenewal ? "续签并安装成功" : "签名并安装成功"
    }

    private func expiryText(for installed: AppRecord) -> String {
        guard let expiryDate = installed.provisioningProfileExpirationDate ?? installed.expiryDate else {
            return "应用已安装"
        }
        return "有效期至 \(SealSettingsDateFormatter.string(from: expiryDate))"
    }

    private func primaryRecoveryTitle(_ failure: ImportFailure) -> String {
        if failure.code.hasPrefix("SEAL-NET-") { return "重试" }
        if isInstallChannelFailure(failure) { return "重新安装" }
        if isTeamFailure(failure) { return "选择 Team" }
        if isAuthFailure(failure) { return "重新验证 Apple ID" }
        if isCertificateFailure(failure) { return "重新检查" }
        if isAppIDLimitFailure(failure) { return "知道了" }
        if isAppIDFailure(failure) || failure.code.hasPrefix("SEAL-BUNDLE-") { return "重试" }
        if isPairingFailure(failure) { return "重新配对设备" }
        if failure.code.hasPrefix("SEAL-VPN-") { return "重新检查" }
        if failure.code == "SEAL-EXT-401" { return "移除扩展并重试" }
        return "重试"
    }

    private func performPrimaryRecovery(_ failure: ImportFailure) {
        if isNonRetryableFailure(failure) {
            viewModel.dismissSigningResult()
            dismiss()
        } else if failure.code.hasPrefix("SEAL-NET-") {
            viewModel.retrySigning()
        } else if isInstallChannelFailure(failure) {
            Task { await viewModel.retryInstallationForCurrentSigningSession() }
        } else if isTeamFailure(failure) {
            openSettings(.account)
        } else if isAuthFailure(failure) {
            openSettings(.account)
        } else if isCertificateFailure(failure) {
            viewModel.retrySigning()
        } else if isAppIDFailure(failure) || failure.code.hasPrefix("SEAL-BUNDLE-") {
            viewModel.dismissSigningResult()
            dismiss()
        } else if isPairingFailure(failure) {
            openSettings(.pairing)
        } else if failure.code.hasPrefix("SEAL-VPN-") {
            viewModel.retrySigning()
        } else if failure.code == "SEAL-EXT-401" {
            viewModel.retryWithoutExtensions()
        } else {
            viewModel.retrySigning()
        }
    }

    private func userFacingReason(_ failure: ImportFailure) -> String {
        failure.userReason
    }

    private func recoveryText(_ failure: ImportFailure) -> String {
        let recovery = failure.recovery.trimmingCharacters(in: .whitespacesAndNewlines)
        if recovery.isEmpty || recovery == "知道了" { return "" }
        return recovery
    }

    private func isTeamFailure(_ failure: ImportFailure) -> Bool {
        failure.code == "SEAL-AUTH-112" || failure.title.localizedCaseInsensitiveContains("Team 不匹配")
    }

    private func isAuthFailure(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-AUTH-") || failure.code.contains("APPLE_ID")
    }

    private func isCertificateFailure(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-CERT-") || failure.code.contains("CERT")
    }

    private func isAppIDFailure(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-APPID-")
    }

    private func isAppIDLimitFailure(_ failure: ImportFailure) -> Bool {
        failure.code == "SEAL-APPID-301" || failure.code == "SEAL-APPID-304"
    }

    private func isPairingFailure(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-PAIR-")
    }

    private func isInstallChannelFailure(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-INSTALL-")
    }

    /// 确定性失败：重试 / 重新安装都无法改变结果，只能按指引手动处理后重试。
    /// 按钮统一为「知道了」并关闭，不做无效重试。
    private func isNonRetryableFailure(_ failure: ImportFailure) -> Bool {
        failure.code == "SEAL-APPID-DEVICELIMIT"
            || failure.code == "SEAL-INSTALL-702l"   // 安装被 iOS 拒绝（免费账号 3 应用上限 / 完整性校验）
            || failure.code == "SEAL-INSTALL-702s"   // 设备存储空间不足
    }

    private func openSettings(_ route: SettingsRoute) {
        viewModel.dismissSigningResult()
        viewModel.openSettings(route: route)
        dismiss()
    }

    private func finish() {
        let completionMode = session?.completionMode ?? .signAndInstall
        viewModel.dismissSigningResult()
        onFinish(completionMode)
        dismiss()
    }
    @ViewBuilder
    private var verificationCodeSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("需要双重认证")
                    .font(.title2.weight(.bold))
                Text("你的 Apple ID 会话已过期，需要重新验证。请在另一台设备上点击「允许」，然后输入收到的验证码。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                TextField("六位验证码", text: $verificationCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .padding(.vertical, 16)
                    .background(Color.sealSurfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onChange(of: verificationCode) { code in
                        verificationCode = String(code.filter(\.isNumber).prefix(6))
                    }
                Button {
                    viewModel.signingVerificationBroker.submit(verificationCode)
                    verificationCode = ""
                } label: {
                    if viewModel.signingVerificationBroker.hasSubmittedCode {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("验证")
                    }
                }
                .sealPrimaryAction()
                .disabled(verificationCode.count < 6 || viewModel.signingVerificationBroker.hasSubmittedCode)
                Button("取消") {
                    viewModel.signingVerificationBroker.cancel()
                    verificationCode = ""
                }
                .foregroundStyle(.secondary)
            }
            .padding(24)
            .presentationDetents([.medium])
            .interactiveDismissDisabled(true)
        }
    }
}

private struct CurrentSegmentFill: View {
    let fraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.sealTextSecondary.opacity(0.22))
                Capsule()
                    .fill(Color.sealAccent)
                    .frame(width: geo.size.width * clampedFraction)
            }
        }
        .frame(height: 6)
    }

    private var clampedFraction: CGFloat { max(0, min(1, fraction)) }
}
