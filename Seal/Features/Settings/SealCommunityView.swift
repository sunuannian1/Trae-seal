import SwiftUI
import UIKit

struct SealCommunityView: View {
    @Environment(\.openURL) private var openURL

    @State private var showRewardCode = false
    @State private var saveCoordinator: AlbumSaveCoordinator?

    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    private let qqGroupNumber = "1093450608"
    private let qqJoinURL = URL(string: "https://qm.qq.com/q/OHpPXyHryI")
    private let telegramURL = URL(string: "https://t.me/addlist/vQ5-N-_q0qYzNWNl")
    private let rewardTitle = "请作者喝杯奶茶"

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                header
                VStack(spacing: 12) {
                    rewardCard
                    qqCard
                    telegramCard
                }
                footerNote
            }
            .padding(20)
        }
        .navigationTitle("加入 Seal 社群")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground()
        .sheet(isPresented: $showRewardCode) { rewardCodeSheet }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("好的", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.sealSurfaceElevated)
                    .frame(width: 84, height: 84)
                Image("SealCommunityIcon")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Color.sealAccent)
            }
            Text("加入 Seal 社群")
                .font(.system(size: 22, weight: .bold))
            Text("在这里相遇，让 Seal 走得更远")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.sealTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var rewardCard: some View {
        Button { showRewardCode = true } label: {
            HStack(spacing: 14) {
                iconBadge("heart.fill", tint: .white, background: Color.white.opacity(0.20))
                VStack(alignment: .leading, spacing: 3) {
                    Text(rewardTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("你的支持，是作者更新的动力")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.82))
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(16)
            .background(Color.sealAccent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var qqCard: some View {
        communityCard(
            icon: "bubble.left.and.bubble.right",
            title: "加入 QQ 交流群",
            subtitle: "点击直接跳转 QQ 加群",
            value: nil,
            action: joinQQGroup
        )
    }

    private var telegramCard: some View {
        communityCard(
            icon: "paperplane",
            title: "加入 Telegram 频道",
            subtitle: "国内需科学上网",
            value: nil,
            action: joinTelegram
        )
    }

    private var footerNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.sealTextSecondary)
            Text("欢迎加入 Seal 社群，交流使用心得、反馈问题、获取最新动态。")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.sealTextSecondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.sealSurfaceElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var rewardCodeSheet: some View {
        VStack(spacing: 20) {
            Text(rewardTitle)
                .font(.title2.weight(.bold))
                .padding(.top, 24)

            if let image = UIImage(named: "SealCommunityReward") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.sealSurfaceElevated)
                    .frame(width: 240, height: 240)
                    .overlay {
                        Text("赞赏码未加载")
                            .font(.footnote)
                            .foregroundStyle(Color.sealTextSecondary)
                    }
            }

            Text("保存图片后，到微信「扫一扫」选择该图片即可")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button {
                saveRewardCode()
            } label: {
                Text("保存到相册")
            }
            .sealPrimaryAction(cornerRadius: 14)
            .padding(.horizontal, 24)

            Button("关闭") { showRewardCode = false }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.bottom, 12)
        }
        .presentationDetents([.medium, .large])
    }

    private func iconBadge(_ systemName: String, tint: Color, background: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(background)
                .frame(width: 46, height: 46)
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    private func communityCard(
        icon: String,
        title: String,
        subtitle: String?,
        value: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                iconBadge(icon, tint: Color.sealAccent, background: Color.sealAccent.opacity(0.12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color.sealTextSecondary)
                    }
                }
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.sealTextSecondary)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func joinQQGroup() {
        // qm.qq.com 短链在系统浏览器里会先落到展示群二维码的落地页（即「扫一扫」），
        // 再唤起 QQ；改用 mqqapi scheme 直接打开 QQ 群资料卡，跳过中间落地页。
        let scheme = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=\(qqGroupNumber)&card_type=group&source=external")
        if let scheme {
            UIApplication.shared.open(scheme) { opened in
                if !opened, let fallback = qqJoinURL {
                    openURL(fallback)
                }
            }
        }
    }

    private func joinTelegram() {
        if let url = telegramURL {
            openURL(url)
        }
    }

    private func saveRewardCode() {
        guard let image = UIImage(named: "SealCommunityReward") else {
            presentAlert("保存失败", "赞赏码未加载，请稍后重试")
            return
        }
        let coordinator = AlbumSaveCoordinator { error in
            Task { @MainActor in
                handleSaveResult(error == nil)
            }
        }
        saveCoordinator = coordinator
        UIImageWriteToSavedPhotosAlbum(
            image,
            coordinator,
            #selector(AlbumSaveCoordinator.image(_:didFinishSavingWithError:contextInfo:)),
            nil
        )
    }

    private func handleSaveResult(_ success: Bool) {
        if success {
            presentAlert("已保存到相册", "感谢你的支持")
        } else {
            presentAlert("保存失败", "请在系统设置中允许 Seal 访问相册后重试")
        }
    }

    private func presentAlert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

private final class AlbumSaveCoordinator: NSObject, @unchecked Sendable {
    private let completion: @Sendable (Error?) -> Void

    init(completion: @escaping @Sendable (Error?) -> Void) {
        self.completion = completion
    }

    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        completion(error)
    }
}