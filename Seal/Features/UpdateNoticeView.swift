import SwiftUI

/// 更新通知弹窗（iOS 原生风格，居中布局，内容自适应并可限高滚动）
struct UpdateNoticeView: View {
    let notice: UpdateNotice
    let onDismiss: () -> Void

    /// 把 Release 的 Markdown body 拆成更新内容列表（逐行去 markdown 标记）
    private func changeItems(from markdown: String) -> [String] {
        var items: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            var text = line
            text = text.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "^\\s*[-*•·]\\s+", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "^\\s*\\d+[.)]\\s+", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: "`(.+?)`", with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\[(.+?)\\]\\(.+?\\)", with: "$1", options: .regularExpression)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                items.append(trimmed)
            }
        }
        if items.isEmpty {
            let full = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            items = full.isEmpty ? ["点击查看详情并更新"] : [full]
        }
        return items
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: 0) {
                // 顶部：提醒图标 + 标题 + 版本号（居中）
                VStack(spacing: 12) {
                    Image("UpdateBell")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(Color.sealAccent)
                        .frame(width: 56, height: 56)
                    Text(notice.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(notice.version)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)

                Divider()
                    .padding(.horizontal, 20)

                // 更新内容（内容自适应延长，超出限高滚动）
                VStack(alignment: .leading, spacing: 8) {
                    Text("更新内容")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(changeItems(from: notice.message), id: \.self) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(Color.sealAccent)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 7)
                                    Text(item)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                // 按钮
                Button(action: onDismiss) {
                    Text("知道了")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.sealAccent)
                        )
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
            .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 12)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
}