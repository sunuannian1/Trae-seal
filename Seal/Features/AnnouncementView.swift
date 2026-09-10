import SwiftUI

/// 公告弹窗（三态：普通 notice / 重要 important / 更新 update）
struct AnnouncementView: View {
    let announcement: Announcement
    let onDismiss: () -> Void
    let onHideThisTime: (() -> Void)?

    private var kind: Announcement.Kind { announcement.kind }
    private var isNotice: Bool { kind == .notice }
    private var isImportant: Bool { kind == .important }
    private var isUpdate: Bool { kind == .update }

    private var iconName: String {
        switch kind {
        case .notice: return "megaphone.fill"
        case .important: return "exclamationmark.triangle.fill"
        case .update: return "bell.badge.fill"
        }
    }

    private var iconColor: Color {
        isImportant ? .sealDanger : .sealAccent
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: 0) {
                // 顶部：图标 + 标题(+角标) + 正文
                VStack(spacing: 12) {
                    Image(systemName: iconName)
                        .font(.system(size: 24, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(iconColor)
                        )

                    HStack(spacing: 6) {
                        Text(announcement.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if isImportant {
                            badge("重要", color: .sealDanger)
                        } else if isUpdate {
                            badge("更新", color: .sealAccent)
                        }
                    }

                    Text(announcement.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)

                // 按钮区
                VStack(spacing: 8) {
                    Button(action: onDismiss) {
                        Text("我知道了")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.sealAccent)
                            )
                    }
                    if let onHideThisTime {
                        Button(action: onHideThisTime) {
                            Text("本次不再显示")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 0.7)
            }
            .overlay(alignment: .topTrailing) {
                if isNotice {
                    Button {
                        onHideThisTime?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.secondary.opacity(0.15)))
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                    .accessibilityLabel("关闭")
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 12)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}