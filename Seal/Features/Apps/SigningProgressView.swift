import Foundation
import SwiftUI
import UIKit

struct SigningProgressView: View {
    @ObservedObject var viewModel: AppsViewModel
    let onFinish: (SigningCompletionMode) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Seal 自续签进入安装阶段后置 true：界面先做一次可感知的淡出转场并改文案，
    /// 再由 Seal 触发系统级回主屏，避免「静止数秒后瞬间消失」被误读成闪退。
    @State private var isReturningHome = false

    var body: some View {
        // footer 常显：运行中要给出「取消」退出通道。旧实现运行中 footer 为空
        // 且禁用了下滑关闭，用户被关在一个没有任何操作的弹窗里（2026-09-16 真机反馈
        // 「卡在 93% 怎么都没反应」）。
        SealDrawer(title: title, showsFooter: true) {
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
        // Seal 自续签=覆盖安装运行中的自己：进入 .installing（上传完成）后自动切到后台，
        // 让 iOS 用新版替换旧进程，无需人手按 Home；安装续由重新打开的新进程对账确认。
        //
        // 这里**只负责视觉**：先用 withAnimation 把「正在退回主屏幕」这一帧渲染出来，
        // 用户看到的是有交代的退场，而不是界面凭空消失。
        // 真正的「回主页」动作由 AppsViewModel.updateSigningStage 在状态层触发 ——
        // 挂在界面上的话，用户一点「取消」关掉抽屉，触发点就跟着消失了，
        // 而安装早已交给 installd，Seal 的替换会静默失败。
        // ⚠️ 必须用**单参数**闭包：`onChange(of:) { old, new in }` 是 iOS 17 才引入的重载，
        // 而 Seal 的部署目标已降到 iOS 16.0（2026-09-21 适配）⇒ 双参数写法在 16 上编译失败 ✗。
        // 这里只用新值、不用旧值，所以单参数写法语义完全等价 ✓。
        .onChange(of: viewModel.signingSession?.status) { newStatus in
            if case .running(.installing)? = newStatus,
               viewModel.signingSession?.app.isSeal == true {
                withAnimation(.easeInOut(duration: 0.45)) {
                    isReturningHome = true
                }
            }
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
        // 逐帧驱动。旧实现把进度写成 `SigningStage` 的纯函数（10 个阶段 → 10 个写死的
        // 常数），两次阶段推送之间界面只能冻结、阶段一变就跳一格 —— 这就是用户说的
        // 「跳着走 / 看着像卡住」。现在阶段内部按「已过时间」连续收敛
        // （`SigningProgressBudget`），所以需要一个按帧走的时钟。
        //
        // 30Hz 而不是默认的 60Hz：这只是一张弹窗卡片，30Hz 已经看不出台阶，省一半重绘。
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            runningBody(stage, now: context.date)
        }
    }

    private func runningBody(_ stage: SigningStage, now: Date) -> some View {
        let elapsed = stageElapsed(now)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                progressRing(stage, now: now)
                VStack(alignment: .leading, spacing: 3) {
                    Text(stage.stageTitle(isRenewal: isRenewal))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    if SigningProgressBudget.showsOwnElapsed(stage: stage, elapsed: elapsed) {
                        // 只给明显偏长的阶段显示计时（门槛见 `elapsedDisplayThreshold`）。
                        // 最关键的是 `preparingBundle`：抖音 780 MB 在那里要 112 秒，
                        // 旧实现全程只显示「23%」，用户无法判断是在解压还是卡死了。
                        //
                        // `.installing` / `.verifying` 刻意排除：那两段由 `InstallWaitNote`
                        // 统一报「已等待 m:ss」，同一个数字在一张卡片上出现两次会像故障。
                        Text("本阶段已用时 \(InstallWaitNote.elapsedText(Int(elapsed)))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.sealTextSecondary)
                            .monospacedDigit()
                    }
                }
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
                Text(renewalTipText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.sealAccent)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(isReturningHome ? 0.72 : 1)
            }

            // 上传完成 → installd 接管，进度进入「估算」区间（`installing` 的地板是 88%，
            // 估算上界 95%，**永远不会声称装完**）。这段时间安装通道不再回报任何数值，
            // 不给说明就会被读成「卡死」（2026-09-16 真机反馈）。
            // 计时 + 扫光让「还在走」变成可见事实。
            if stage == .installing || stage == .verifying {
                InstallWaitNote(startedAt: session?.installStartedAt)
            }

            stageProgressSection(stage, now: now)
        }
        .padding(14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    /// 底部阶段轨道。
    ///
    /// 每一格的填充来自 `SigningProgressBudget.bucketFill`（格内已完成阶段数 +
    /// 本阶段完成比例），**不再用写死的 0.33 / 0.5 / 0.67**。旧实现那三个常数与真实
    /// 完成度无关，于是「当前格」看起来像随机卡在某个位置，而阶段一过又整条变绿 ——
    /// 那是轨道上最大的一跳。
    private func stageProgressSection(_ stage: SigningStage, now: Date) -> some View {
        let elapsed = stageElapsed(now)
        let sweep = sweepPhase(now)
        return VStack(alignment: .leading, spacing: 8) {
            Text(isRenewal ? "续签进度" : "签名进度")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.sealTextSecondary)
            HStack(spacing: 6) {
                ForEach(Array(0..<SigningProgressBudget.bucketCount), id: \.self) { bucket in
                    progressSegment(bucket: bucket, stage: stage, elapsed: elapsed, sweepPhase: sweep)
                }
            }
        }
    }

    @ViewBuilder
    private func progressSegment(
        bucket: Int,
        stage: SigningStage,
        elapsed: TimeInterval,
        sweepPhase: Double
    ) -> some View {
        let segmentFill = SigningProgressBudget.bucketFill(
            bucket,
            stage: stage,
            elapsed: elapsed,
            realProgress: session?.installProgress
        )
        if bucket == SigningProgressBudget.plan(for: stage).bucket {
            // ⚠️ 2026-09-19：不再传 `showsSweep` / `sweepPhase`（扫光已移除，见上面结构体注释）。
            CurrentSegmentFill(fraction: CGFloat(segmentFill))
        } else {
            Capsule()
                .fill(segmentFill >= 1 ? Color.sealSuccess : Color.sealTextSecondary.opacity(0.22))
                .frame(height: 6)
                .frame(maxWidth: .infinity)
        }
    }

    /// 进入当前阶段到现在过了多少秒。
    ///
    /// 起点为 `nil` 时返回 0（回看历史会话、或起点丢失）—— 此时进度停在阶段地板值上，
    /// 仍是个有效显示，不会出现负进度或跳变。
    private func stageElapsed(_ now: Date) -> TimeInterval {
        guard let startedAt = session?.stageStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// 扫光相位（0–1）。周期固定 1.1 秒：比呼吸快一点，才像「在跑」而不是「在喘」。
    ///
    /// 用 `now` 直接算，而不是叠一个 `repeatForever` 动画 —— 卡片整体已经由
    /// `TimelineView` 逐帧重绘，再挂一层隐式动画会互相打架（表现为黏滞或抖动）。
    private func sweepPhase(_ now: Date) -> Double {
        let period = 1.1
        let remainder = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return remainder / period
    }

    private func progressRing(_ stage: SigningStage, now: Date) -> some View {
        // Seal 自续签的 .installing 是「覆盖运行中的自己」：这段进度**完全不可知**
        //（进程随时可能被 iOS 替换掉），所以继续用不确定动效，不给数字。
        if case .installing = stage, sealRenewal {
            return AnyView(selfReplacementInstallingRing(now: now))
        }
        // ⚠️ **只画已确认的进度，不画估算**（2026-09-19，用户明确要求「圈圈不要假预估」）。
        //
        // 之前这里画两段弧：深色 = 已确认、浅色 = 按 τ 指数收敛的**估算**，数字也取估算值。
        // 问题在于：**阶段内部我们并不知道真实进度** —— 让环和数字跟着一个推测值爬，
        // 就是在**编数字**，用户看久了会当成真进度（这正是「假预估」）。
        //
        // ⇒ 现在环与数字都只反映 `confirmedProgress`：
        //   - **没有**真实进度信号的阶段（大多数）：环**停在原地不动** —— 这是**诚实**的，
        //     我们确实不知道；
        //   - **有**真实信号的阶段（`.pushing` 的 AFC 上传回调、`.installing` 的 installd 进度）：
        //     环跟着真实值走 ✓。
        //
        // ⚠️ 「还在动」这个信号**不靠圈**表达，而由「**本阶段已用时 m:ss**」的秒数跳动承担 ✓
        //（`SigningProgressBudget.showsOwnElapsed`，守卫 R36 钉着它必须存在）。
        let confirmed = SigningProgressBudget.confirmedProgress(
            stage: stage,
            realProgress: session?.installProgress
        )
        return AnyView(
            ZStack {
                Circle()
                    .stroke(Color.sealTextSecondary.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.03, confirmed / 100))
                    .stroke(Color.sealAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(confirmed))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.sealAccent)
                    .monospacedDigit()
            }
            .frame(width: 50, height: 50)
        )
    }

    // ⚠️ 2026-09-19：`leadingAngle` 与 `leadingPulse` 已删除。
    //
    // 它们是「估算弧 + 弧前端呼吸点」的辅助函数，随用户要求的「圈圈不要假预估」
    // 一起去掉（估算弧与呼吸点都不再画）。
    // `sweepPhase` **保留**：Seal 自替换的「替换中」转圈仍在用它 ✓。

    /// Seal 自续签的「替换中」转圈。
    ///
    /// 旋转角由 `now` 算出，**不再用 `repeatForever` 动画**：这张卡片已由
    /// `TimelineView` 逐帧重绘，再挂一层隐式动画会互相打架
    ///（表现为转速忽快忽慢，或者干脆停住）。
    private func selfReplacementInstallingRing(now: Date) -> some View {
        let spin = sweepPhase(now) * 360
        return ZStack {
            Circle()
                .stroke(Color.sealTextSecondary.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color.sealAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(spin))
            Text("替换中")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.sealAccent)
        }
        .frame(width: 50, height: 50)
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
                .fixedSize(horizontal: false, vertical: true)
            // Only show recovery hint when it differs from primary action button
            let recovery = recoveryText(failure)
            if recovery.isEmpty == false, recovery != primaryRecoveryTitle(failure) {
                Text(recovery)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.sealAccent)
                    .fixedSize(horizontal: false, vertical: true)
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
            Button("取消") {
                viewModel.cancelSigning()
                dismiss()
            }
            .sealOutlineAction(cornerRadius: 14)

        case .succeeded:
            Button("完成") { finish() }
                .sealPrimaryAction(cornerRadius: 14)

        case .failed(let failure):
            if failure.code == "SEAL-APPID-DEVICELIMIT" {
                VStack(spacing: 10) {
                    Button("已用 Lara 绕过，继续安装") {
                        viewModel.continueBypassingDeviceLimit()
                    }
                    .sealPrimaryAction(cornerRadius: 14)
                    Button(primaryRecoveryTitle(failure)) {
                        performPrimaryRecovery(failure)
                    }
                    .sealOutlineAction(cornerRadius: 14)
                }
            } else {
                Button(primaryRecoveryTitle(failure)) {
                    performPrimaryRecovery(failure)
                }
                .sealPrimaryAction(cornerRadius: 14)
            }
        case nil:
            EmptyView()
        }
    }

    private func signingRuntimeCard(_ session: SigningSession) -> some View {
        VStack(spacing: 0) {
            runtimeRow("签名账户", viewModel.fullEmail(for: session.account))
            Divider().padding(.leading, 14)
            runtimeSerialRow("证书序列号", certificateDisplayName(session))
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

    /// 证书序列号行：标题左、值右，同一行展示；超长中间省略（保留头尾便于核对）。
    private func runtimeSerialRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.sealTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: 42)
        .padding(.vertical, 4)
    }

    /// 续签提示：Seal 自续签与普通 App 同文案；进入安装阶段后换成「正在退回主屏幕」，
    /// 让自动切后台有预期，不再要求用户手按 Home。
    private var renewalTipText: String {
        if sealRenewal, case .running(.installing)? = session?.status {
            return AppSigningPresentationHelpers.sealReturningHomeTip
        }
        return AppSigningPresentationHelpers.keepSealOpenTip
    }

    private func certificateDisplayName(_ session: SigningSession) -> String {
        // 与详情页 AppDetailView.certificateName 共用同一个 helper，用会话真实的
        // selectedCertificateSerialNumber（签名时由 onCertificateResolved 回写）作序列号，
        // 使签名进度页与详情页展示完全同步；证书尚未确定时保持“未准备”。
        // 展示值只有序列号本身（不再带「序列号 · 」前缀），且完整不截断。
        guard let serial = session.selectedCertificateSerialNumber ?? session.account.certificateSerialNumber,
              serial.isEmpty == false else {
            return "未准备"
        }
        return AppSigningPresentationHelpers.certificateSerialText(serial: serial)
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
    private var sealRenewal: Bool { session?.app.isSeal == true }

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
        if isNonRetryableFailure(failure) { return "知道了" }
        if failure.code == "SEAL-CERT-204e" { return "撤销并继续签名" }
        if failure.code.hasPrefix("SEAL-NET-") { return "重试" }
        if isResignRequired(failure) { return "重新签名" }
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
        } else if failure.code == "SEAL-CERT-204e" {
            // 一键盘活：撤销无钥匙证书 → 自动重试本次签名 → 自动重签受影响已装 App。
            viewModel.confirmCertificateSacrificeAndRetry()
        } else if failure.code.hasPrefix("SEAL-NET-") {
            viewModel.retrySigning()
        } else if isResignRequired(failure) {
            viewModel.retrySigningFromScratch()
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
        InstallFailureActionPolicy.action(for: failure.code) == .reinstall
    }

    /// 签名包「内容本身」出错（缺失/损坏/过期/设备不符/Team 不符/结构不完整），
    /// 重复安装同一个坏包不会改变结果，必须重新签名。
    ///
    /// 码集合在 `InstallFailureActionPolicy` 里显式列出：原先这里用
    /// `hasPrefix("SEAL-INSTALL-71"/"72"/"73")` 做数字区间匹配，把 738
    /// （上一笔安装仍在跑，recovery 写的是「重新启动 Seal 后再试」）与 737 也算成了
    /// 「重新签名」，一次点击即触发全量重签 + 重传，正好造出并发安装。
    private func isResignRequired(_ failure: ImportFailure) -> Bool {
        InstallFailureActionPolicy.action(for: failure.code) == .resign
    }

    /// 确定性失败：重试 / 重新安装都无法改变结果，只能按指引手动处理后重试。
    /// 按钮统一为「知道了」并关闭，不做无效重试。
    private func isNonRetryableFailure(_ failure: ImportFailure) -> Bool {
        CertificateRequestFailurePolicy.isNonRetryableFailure(failure)
            || InstallFailureActionPolicy.action(for: failure.code) == .acknowledge
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
}

/// 底部阶段轨道里「当前格」的填充。
///
/// 旧实现只填一个**写死的常数**（0.33 / 0.5 / 0.67），与真实完成度无关 ——
/// 于是这一格看起来像随机卡在某个位置，而阶段一过又整条变绿（轨道上最大的一跳）。
/// 现在比例来自 `SigningProgressBudget.bucketFill`：格内已完成阶段数 + 本阶段完成比例。
///
/// ## 扫光
///
/// 「后端在干活、界面一动不动」是这次改版要解决的头号观感问题。扫光**不推进百分比**，
/// 只表达「在动」—— 数字可能几十秒不变，但这条光一直在跑。它比任何假百分比都可信：
/// iOS 自己的不确定进度用的就是这个信号。
///
/// 只在「估算中」的当前格才画：有真实上传进度的格子本身就在动，再叠一层会像两个进度打架。
private struct CurrentSegmentFill: View {
    let fraction: CGFloat

    // ⚠️ 2026-09-19 清理：`showsSweep` / `sweepPhase` / `sweepWidth` 已删除 ——
    // 白色扫光在 2026-09-18 被移除后（用户反馈「横杠的煽动效果不好看」），
    // 这三个成员就再没有读者了 ✓。

    private static let barHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let filled = max(0, geo.size.width) * clampedFraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.sealTextSecondary.opacity(0.22))
                Capsule()
                    .fill(Color.sealAccent)
                    .frame(width: filled, height: Self.barHeight)
                    // ⚠️ **白色扫光已移除**（2026-09-18，用户实测反馈）。
                    //
                    // 原来这里有一道 `Color.white.opacity(0.55)`、宽 18pt 的矩形扫过填充区，
                    // 目的是「数字几十秒不变时表达『在动』」。但用户看到的是：
                    // 「横杠的煽动效果不好看」「**圆点走前面中间都灰白了**」——
                    // 白色扫过蓝色，**中段就被读成灰白** ✗。
                    //
                    // 「还在动」这个信号现在由 **`本阶段已用时 0:20` 的秒数跳动**承担
                    //（`SigningProgressBudget.showsOwnElapsed`，守卫 R36 钉着它必须存在），
                    // 不再需要用视觉噪点表达。
                    .clipShape(Capsule())
            }
            .frame(height: Self.barHeight)
        }
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
    }

    private var clampedFraction: CGFloat { max(0, min(1, fraction)) }
}

/// Seal 自续签的「回主屏幕」动作。
///
/// Seal 自续签 = 覆盖安装正在运行的自己：iOS 只有在旧进程退出前台后才会用新版完成替换。
/// 旧实现是「静止等 2 秒 → `perform("suspend")`」，一旦 `suspend` 在某个系统版本上不再
/// 响应就会静默什么都不做，最后由 installd 直接杀进程 —— 用户看到的就是「闪退」。
/// 现在：
///   1. UI 先渲染「正在退回主屏幕」（由 SigningProgressView 的 withAnimation 负责）；
///   2. 先看当前前台状态（见 `ReturnHomeStep`）：`.background` 说明用户已离开，
///      交给 iOS 自己完成替换；`.inactive` 是**瞬时**失焦，进程仍占着前台，必须等它恢复
///      —— 早退会连 `exit(0)` 兜底一起跳过，安装永远完不成（2026-09-16 真机：永久停在 93%）；
///   3. 触发与「按 Home」等价的系统级转场，交给系统播放退场动画；
///   4. 转场后等 3 秒，若进程仍存活（说明转场没生效）才用 `exit(0)` 兜底，
///      保证进程一定结束、iOS 才能完成替换；转场成功时进程已被挂起，不会走到这里。
/// 本类型只做「切后台 / 退出」，不碰签名、证书、自替换事务：安装结果仍由重新打开的
/// 新进程 `SelfReplacementCoordinator` 对账确认。
///
/// ## 为什么每一步都要写日志（2026-09-16 补）
///
/// 真机反馈「续签卡在 93%」时，这条链路**一行日志都没有** —— 于是「转场到底有没有触发」
/// 只能靠猜。现在入口、`.standDown` / `.triggerTransition` / `.waitForForeground` 三个
/// 分支、以及 `exit(0)` 兜底都各留一条，且**每条立刻 `flush()`**：`suspend` 一旦生效
/// 进程即被冻结，之后写的日志出不来。
///
/// ## 真机证据推翻了「suspend 截断安装」的假设（2026-09-17 补）
///
/// 上一条曾记着「未定论」：本类型说「iOS 只有在旧进程退出前台后才会完成替换」，
/// 而 `MinimuxerInstallChannel` 说「提前 suspend 会冻结当前连接」。查两份真机日志
/// （`Seal-log(7).txt` / `Seal-log(8).txt`，各自两次自续签）后结论变了：
///
/// - 自续签安装起点之后**没有任何安装结论**，界面永久停在 93%；
/// - 但进程**既不转场也不退出**：起点之后照常写后台日志（`[BatchDebug]`、账号同步、
///   `安装 LocalDevVPN 正常`），同一天普通 App（LiveContainer）**7 秒**装完。
///
/// 若 `suspend` 生效，进程会被冻结 ⇒ 日志停止；若 `exit(0)` 执行，进程会终止。
/// 两者都没发生 ⇒ **动作在到达 `suspend` 之前就被丢掉了**。丢掉它的正是
/// `.standDown` 分支的「立即放弃」（详见 `backgroundWaitSeconds`）。
///
/// 所以真正的因果链是：**进程不退出 ⇒ iOS 不完成替换 ⇒ installd 一直等 ⇒
/// `stageAndInstall` 一直不返回**。`suspend` 时机不是原因，`MinimuxerInstallChannel`
/// 那条注释描述的也是「别在安装返回前挂起」这个**后果**，与这里的修复方向一致。
enum SelfInstallAutoBackground {
    /// 转场前的可感知停顿：既让 UI 的「正在退回主屏幕」渲染出来，也给 Rust 暂存落盘留余量。
    private static let transitionBeatNanoseconds: UInt64 = 1_200_000_000
    /// `exit(0)` 兜底的等待时间。取 3 秒：远长于系统退场动画（约 0.3–0.5 秒），
    /// 确保转场成功时进程早已被挂起，这段代码不会执行，不会打断动画。
    private static let exitFallbackNanoseconds: UInt64 = 3_000_000_000

    /// 等待 `.inactive`（瞬时失焦）自行恢复为 `.active` 的重试间隔与次数。
    /// 3 秒足够覆盖控制中心 / 通知横幅 / 来电浮层这类短暂遮挡。
    private static let inactiveRetryNanoseconds: UInt64 = 500_000_000
    private static let inactiveRetryLimit = 6

    /// `.background`（用户切走了）等待「回到前台」的时长上限与轮询间隔。
    ///
    /// 旧实现在 `.background` 时**立即放弃**（`return false`），前提是「进程已让出前台，
    /// iOS 会自己完成替换」。这个前提对**覆盖安装运行中的自己**不成立：iOS 需要旧进程
    /// **终止**，而后台进程不会自己终止 —— 自续签还主动开了后台保活
    ///（真机日志「续签 Seal 自续签事务：后台保活已启动，覆盖证书、描述文件、签名和安装」），
    /// 等于主动把这个前提破坏掉了。
    ///
    /// 2026-09-16 两份真机日志是决定性证据：两次自续签（`16:53:57` / `19:43:50`）都停在 93%，
    /// 而进程**既不转场也不退出**、照常写后台日志。`.triggerTransition` 必然调 `suspend`
    /// （生效则进程冻结、日志停止），`.waitForForeground` 超时必然 `exit(0)`（进程终止）——
    /// 两者都没发生，只剩「这条分支把动作丢掉了」一种解释。
    ///
    /// 取 8 秒：覆盖「切出去看一眼再回来」的常见情形；超时后强杀 —— 此时用户在别处，
    /// 看不到闪退，而不终止进程 iOS 就永远完不成替换。
    private static let backgroundWaitSeconds: TimeInterval = 8
    private static let backgroundPollNanoseconds: UInt64 = 500_000_000

    /// 前台状态下该怎么走。抽成纯函数是为了**能单测** ——
    /// 这段判断原先直接读 `UIApplication.shared.applicationState`，没有任何测试覆盖，
    /// 而它的 `.inactive` 分支正是「Seal 自续签永久停在 93%」的根因（2026-09-16 真机反馈）；
    /// `.background` 分支则是同一现象在 2026-09-17 被坐实的**另一个**根因。
    /// 这类「错了也不会崩、只会在真机上卡死」的分支必须有测试钉住。
    ///
    /// `@MainActor`：`UIApplication` 在 Swift 6 严格并发下是主 actor 隔离的，
    /// 这里显式跟着走，避免「读它的枚举」被当成跨 actor 访问。它的调用点
    /// `waitUntilItIsTimeToExit` 与 `poll(for:waited:rounds:)` 都在主 actor 上。
    enum ReturnHomeStep: Equatable {
        /// `.background`：用户把 App 切走了（或自续签的后台保活生效）。
        ///
        /// **不再「立即放弃」** —— 见 `backgroundWaitSeconds`：先等用户回到前台走转场，
        /// 等不到就强杀。旧实现在这里直接放弃（`return false`），是 2026-09-16 真机
        /// 两次自续签都停在 93% 的直接原因：进程既不转场也不退出，永久占着前台，
        /// iOS 永远等不到替换时机。
        case standDown
        /// `.active`：正常触发与「按 Home」等价的系统转场。
        case triggerTransition
        /// `.inactive`：瞬时失焦（控制中心、通知横幅、来电、App 切换器预览、系统弹窗），
        /// **进程仍在前台** —— iOS 不会完成替换，所以必须等它恢复，绝不能直接放弃。
        case waitForForeground
    }

    @MainActor
    static func step(for state: UIApplication.State) -> ReturnHomeStep {
        switch state {
        case .active:
            return .triggerTransition
        case .inactive:
            return .waitForForeground
        case .background:
            return .standDown
        @unknown default:
            // 未知状态按「还没离开前台」处理：宁可多等一轮，也不能静默放弃安装。
            return .waitForForeground
        }
    }

    /// 一轮轮询之后该做什么。抽成纯函数是为了**能单测**：
    /// 「再等等」和「该动手了」的区别，在真机上就是「正常替换」和「永久停在 93%」，
    /// 而这段判断本身不会崩、不会编译失败、也不会跑挂失败的单测。
    enum PollOutcome: Equatable {
        /// 执行该状态对应的动作：`.active` 触发转场，其余两个走 `exit(0)` 兜底。
        case act
        /// 再等一轮。
        case wait
    }

    /// - Parameters:
    ///   - step: 当前前台状态对应的走法。
    ///   - waited: 从开始等待算起已经过了多少秒（总预算）。
    ///   - rounds: `.inactive` 已经轮询过多少轮（次数预算）。
    @MainActor
    static func poll(
        for step: ReturnHomeStep,
        waited: TimeInterval,
        rounds: Int
    ) -> PollOutcome {
        switch step {
        case .triggerTransition:
            return .act
        case .waitForForeground:
            // 瞬时失焦：进程仍占着前台，等够 3 秒（6 轮 × 0.5 秒）就自己退出 ——
            // 否则 iOS 永远等不到替换时机。这里用**次数**而不是总时长：
            // 这段等待的语义是「等系统浮层消失」，用轮数表达更贴切。
            return rounds < inactiveRetryLimit ? .wait : .act
        case .standDown:
            // 后台：等用户回到前台（最多 8 秒），等不到就强杀。
            // **绝不能像旧实现那样直接放弃** —— 不终止进程 iOS 就完不成替换，
            // 而「iOS 会自己完成替换」这个前提对覆盖安装自己并不成立。
            return waited < backgroundWaitSeconds ? .wait : .act
        }
    }

    @MainActor
    static func returnToHomeAfterSealUpload(logStore: SealLogStore? = nil) {
        Task { @MainActor in
            await log(logStore, "Seal 自替换：上传完成，1.2 秒后判断前台状态并回主屏")
            try? await Task.sleep(nanoseconds: transitionBeatNanoseconds)
            let app = UIApplication.shared
            // 这个调用**总会返回**（转场已触发，或等到该强杀为止），所以没有返回值可判。
            // 旧实现返回 `false` 表示「用户已切到后台，交给 iOS 自己替换、不强杀进程」——
            // 那条路会让进程永久占着前台，iOS 永远完不成替换（见 `backgroundWaitSeconds`）。
            await waitUntilItIsTimeToExit(app, logStore: logStore)
            // 兜底：3 秒后进程还活着，说明转场没生效（会永久停在进度页），此时才强制退出。
            // 转场成功的话进程已被挂起，这行不会执行 —— 所以不会打断退场动画。
            await log(logStore, "Seal 自替换：3 秒内进程仍存活（转场未生效），强制 exit(0)")
            try? await Task.sleep(nanoseconds: exitFallbackNanoseconds)
            exit(0)
        }
    }

    /// 阻塞到「该退出」为止：要么已经触发过转场，要么等到该强杀为止。
    ///
    /// - `.active` ⇒ 触发转场后立即返回；
    /// - `.inactive`（进程仍占着前台，此时强杀会闪退）⇒ 最多等 `inactiveRetryLimit` 轮；
    /// - `.background`（用户切走了，进程不会自己终止）⇒ 最多等 `backgroundWaitSeconds`。
    ///
    /// **刻意没有「什么都不做就返回」的路径**：旧实现把 `.background` 当成
    /// 「用户已离开、iOS 会自己完成替换」直接返回，结果进程既不转场也不退出、
    /// 永久占着前台 —— 2026-09-16 真机两次自续签都停在 93% 正是这条路径造成的。
    ///
    /// 每个分支要么 `return`、要么 `sleep`，所以既不会忙循环，也一定有界。
    @MainActor
    private static func waitUntilItIsTimeToExit(
        _ app: UIApplication,
        logStore: SealLogStore?
    ) async {
        let startedAt = Date()
        var didLogWaitingInBackground = false
        var inactiveRounds = 0
        while true {
            // 刻意不叫 `step`：`let step = step(for:)` 会让右侧解析到尚未初始化的局部变量，
            // 直接编译失败（`use of local variable 'step' before its declaration`）。
            let currentStep = step(for: app.applicationState)
            let outcome = poll(
                for: currentStep,
                waited: Date().timeIntervalSince(startedAt),
                rounds: inactiveRounds
            )
            switch currentStep {
            case .triggerTransition:
                // 这行必须在 `triggerHomeTransition` **之前**落盘：`suspend` 一旦生效，
                // 本进程就被冻结，之后写的任何日志都出不来。
                await log(logStore, "Seal 自替换：触发回主屏转场（suspend）")
                triggerHomeTransition(app)
                return
            case .standDown:
                guard outcome == .wait else {
                    await log(
                        logStore,
                        "Seal 自替换：在后台等待 \(Int(backgroundWaitSeconds)) 秒仍未回到前台，"
                        + "强制 exit(0) 让 iOS 完成替换"
                    )
                    return
                }
                // 只写一次：这里每 0.5 秒轮询一轮，逐轮都写会把日志刷满，
                // 反而把真机排查最需要的那几行淹掉。
                if didLogWaitingInBackground == false {
                    didLogWaitingInBackground = true
                    await log(
                        logStore,
                        "Seal 自替换：当前在后台，等待回到前台再触发转场"
                        + "（最多 \(Int(backgroundWaitSeconds)) 秒）"
                    )
                }
                try? await Task.sleep(nanoseconds: backgroundPollNanoseconds)
            case .waitForForeground:
                guard outcome == .wait else {
                    await log(logStore, "Seal 自替换：一直未能回到前台，走 exit(0) 兜底")
                    return
                }
                inactiveRounds += 1
                await log(logStore, "Seal 自替换：当前为瞬时失焦，等待回到前台")
                try? await Task.sleep(nanoseconds: inactiveRetryNanoseconds)
            }
        }
    }

    /// 最佳努力日志：**每条都立刻 `flush()`**。
    ///
    /// 这段代码的终点是进程被挂起（`suspend`）或被 `exit(0)` 结束 —— 留在内存缓冲里的行
    /// 会随进程一起消失。而这几行正是判定「先挂起、还是先等 installation_proxy 返回」的
    /// 唯一依据：2026-09-16 真机上自替换卡在 93% 时，**这条链路一行日志都没有**，
    /// 只能靠猜（见 `docs/qa/2026-09-16-install-stage-feedback-and-self-replacement-freeze.md` §6）。
    /// 与安装通道的 `log` 同样处理：写不进去也绝不阻断转场。
    private static func log(_ store: SealLogStore?, _ message: String) async {
        guard let store else { return }
        try? await store.append(category: .installation, message: message)
        await store.flush()
    }

    /// 触发与「按 Home」等价的系统转场。`suspend` 是私有 selector：
    /// 先直接 perform，不响应时再用「借 UIControl 发消息」的经典写法兜底。
    ///
    /// **刻意不返回「是否成功」**：`UIControl.sendAction(_:to:for:)` 的返回类型是 `Void`，
    /// 不是 `Bool`，无法据其判断转场是否真的触发。早期版本按 `Bool` 用，直接编译失败
    ///（`cannot convert return expression of type 'Void' to return type 'Bool'`）。
    /// 现在的判据是「给足时间后进程是否仍存活」，见 `exitFallbackNanoseconds`。
    @MainActor
    private static func triggerHomeTransition(_ app: UIApplication) {
        let selector = NSSelectorFromString("suspend")
        if app.responds(to: selector) {
            _ = app.perform(selector)
            return
        }
        UIControl().sendAction(selector, to: app, for: nil)
    }
}
