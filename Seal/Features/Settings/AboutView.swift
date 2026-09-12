import SwiftUI
import UIKit

struct AboutView: View {
    private let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    private let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    private let bundleID = Bundle.main.bundleIdentifier ?? "com.mjorb.seal"

    /// 应用内更新安装回调（下载完成后触发）；为 nil 时回退跳转浏览器。
    private let onInstall: ((URL) -> Void)?

    init(onInstall: ((URL) -> Void)? = nil) {
        self.onInstall = onInstall
    }

    @State private var isCheckingUpdate = false
    @State private var updateNotice: UpdateNotice?
    @State private var showNoUpdateAlert = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                headerCard
                versionCard
            }
            .padding(20)
        }
        .navigationTitle("关于 Seal")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground()
        .overlay {
            if let notice = updateNotice {
                UpdateNoticeView(
                    notice: notice,
                    onDismiss: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            updateNotice = nil
                        }
                    },
                    onInstall: installCallback
                )
            }
        }
        .alert("已是最新版本", isPresented: $showNoUpdateAlert) {
            Button("好的", role: .cancel) { }
        } message: {
            Text("当前版本 \(version) (\(build))")
        }
    }

    private var headerCard: some View {
        VStack(spacing: 10) {
            appIcon
            Text("Seal")
                .font(.title.weight(.semibold))
            Text("个人 IPA 签名与续签工具")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let image = Self.currentAppIcon() {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Color.sealAccent)
                .frame(width: 72, height: 72)
                .background(Color.sealSurfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var versionCard: some View {
        VStack(spacing: 0) {
            infoRow("版本", "\(version) (\(build))")
            Divider()
            infoRow("Bundle ID", bundleID)
            Divider()
            infoRow("当前系统", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
            Divider()
            infoRow("最低支持", "iOS 17.0")
            Divider()
            checkUpdateRow
            Divider()
            NavigationLink { OpenSourceLicensesView() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("开源许可")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 16, weight: .regular))
                .frame(minHeight: 54)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
        }
    }

    private var checkUpdateRow: some View {
        Button(action: checkUpdate) {
            HStack(spacing: 16) {
                Text("检查更新")
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                if isCheckingUpdate {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 16, weight: .regular))
            .frame(minHeight: 54)
        }
        .buttonStyle(.plain)
        .disabled(isCheckingUpdate)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(Color.sealTextSecondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.72)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
        }
        .font(.system(size: 16, weight: .regular))
        .frame(minHeight: 54)
    }

    private func checkUpdate() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        Task {
            if let notice = await UpdateChecker.shared.check(force: true) {
                updateNotice = notice
            } else {
                showNoUpdateAlert = true
            }
            isCheckingUpdate = false
        }
    }

    /// 下载完成后先收起弹窗，再交给上层执行导入安装。
    private var installCallback: ((URL) -> Void)? {
        guard let onInstall else { return nil }
        return { localURL in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                updateNotice = nil
            }
            onInstall(localURL)
        }
    }

    private static func currentAppIcon() -> UIImage? {
        guard
            let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
            let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let files = primaryIcon["CFBundleIconFiles"] as? [String],
            let iconName = files.last
        else { return nil }
        return UIImage(named: iconName)
    }
}
