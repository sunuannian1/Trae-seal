import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct AppSigningSheet: View {
    let app: AppRecord
    @ObservedObject var viewModel: AppsViewModel
    let onFinish: (SigningCompletionMode) -> Void
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccountID: UUID?
    @State private var targetBundleID = ""
    @State private var hasUserEditedBundleID = false
    @State private var isBundleIDEditorPresented = false
    @State private var isNameEditorPresented = false
    @State private var isIconActionsPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var isIconFileImporterPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        Group {
            if viewModel.signingSession?.app.id == app.id {
                SigningProgressView(viewModel: viewModel, onFinish: onFinish)
            } else {
                configuration
            }
        }
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isRunning)
        .task {
            await viewModel.load(force: true)
            await viewModel.refreshActiveAccountSelection()
            selectDefaultAccount()
            resetBundleIDDraftIfNeeded()
        }
        .onChange(of: viewModel.verifiedAccounts) { _ in
            selectDefaultAccount()
        }
        .sheet(isPresented: $isBundleIDEditorPresented) {
            if BundleIDPolicy.isEditable(workingApp) {
                BundleIDEditorSheet(initialValue: targetBundleID) { value in
                    let saved = await viewModel.updatePreferredBundleIdentifier(for: workingApp, value: value)
                    if saved {
                        targetBundleID = value
                        hasUserEditedBundleID = true
                    }
                    return saved
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $isNameEditorPresented) {
            AppNameEditorSheet(initialValue: workingApp.displayName) { value in
                await viewModel.updatePreferredDisplayName(for: workingApp, name: value)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isIconActionsPresented) {
            AppIconSelectionSheet { action in
                isIconActionsPresented = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    switch action {
                    case .photos:
                        isPhotoPickerPresented = true
                    case .files:
                        isIconFileImporterPresented = true
                    case .original:
                        _ = await viewModel.updatePreferredIcon(for: workingApp, data: nil)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { item in
            guard let item else { return }
            Task {
                defer { selectedPhotoItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                _ = await viewModel.updatePreferredIcon(for: workingApp, data: data)
            }
        }
        .fileImporter(isPresented: $isIconFileImporterPresented, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                _ = await viewModel.updatePreferredIcon(for: workingApp, data: data)
            }
        }
        .alert(item: $viewModel.alertFailure) { failure in
            standardAlert(failure)
        }
    }

    private var configuration: some View {
        let presentation = AppOperationPresentation(app: workingApp)
        return SealDrawer(title: isRenewal ? "正在续签" : "签名") {
            VStack(spacing: 14) {
                appIdentity(presentation: presentation)
                operationSummaryCard
            }
            .padding(.bottom, 12)
        } footer: {
            VStack(spacing: 10) {
                Button(primaryActionTitle(for: presentation)) {
                    startSigning(completionMode: .signAndInstall)
                }
                .sealPrimaryAction(cornerRadius: 14)
                .disabled(bundleIDValidationError != nil)
                .opacity(bundleIDValidationError == nil ? 1 : 0.48)

                if isRenewal == false {
                    if let onDelete {
                        Button("删除 IPA", role: .destructive) {
                            dismiss()
                            onDelete()
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                } else {
                    Button("取消") { dismiss() }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundColor(Color.sealTextSecondary)
                }
            }
        }
        .onAppear { resetBundleIDDraftIfNeeded() }
    }

    private func startSigning(completionMode: SigningCompletionMode) {
        if let selectedAccountID = resolvedSelectedAccountID {
            Task {
                await viewModel.beginSigning(
                    for: workingApp,
                    accountID: selectedAccountID,
                    requestedBundleIdentifier: requestedBundleIDForSigning,
                    completionMode: completionMode
                )
            }
        } else {
            viewModel.openSettings(route: .account)
            dismiss()
        }
    }

    private func appIdentity(presentation: AppOperationPresentation) -> some View {
        HStack(spacing: 14) {
            appIcon(size: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text(workingApp.displayName)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("v\(workingApp.version) · \(Self.fileSizeFormatter.string(fromByteCount: workingApp.size))")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Color.sealTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
    }

    private var operationSummaryCard: some View {
        VStack(spacing: 0) {
            if isRenewal == false {
                summaryRow(title: "状态", value: statusText)
                Divider().padding(.leading, 14)
            }

            if workingApp.importWarnings.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(workingApp.importWarnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.sealWarning)
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(Color.sealTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider().padding(.leading, 14)
            }

            if isRenewal == false {
                Button { isNameEditorPresented = true } label: {
                    summaryRow(title: "App 名称", value: workingApp.displayName, showsDisclosure: true)
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 14)

                Button { isIconActionsPresented = true } label: {
                    summaryRow(title: "App 图标", value: workingApp.preferredIconRelativePath == nil ? "使用原图" : "已自定义", showsDisclosure: true)
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 14)
            }

            if BundleIDPolicy.isEditable(workingApp) {
                Button { isBundleIDEditorPresented = true } label: {
                    bundleIDRow(title: "Bundle ID", value: displayBundleIdentifier, showsDisclosure: true)
                }
                .buttonStyle(.plain)
            } else {
                bundleIDRow(title: "Bundle ID", value: displayBundleIdentifier)
            }
            Divider().padding(.leading, 14)

            if isRenewal {
                summaryRow(title: "签名账户", value: selectedAccountCompactSummary)
            } else if viewModel.verifiedAccounts.isEmpty {
                Button {
                    viewModel.openSettings(route: .account)
                    dismiss()
                } label: {
                    summaryRow(title: "Apple ID", value: "去添加", showsDisclosure: true)
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(viewModel.verifiedAccounts) { account in
                        Button(accountPickerTitle(account)) {
                            selectedAccountID = account.id
                            Task { await viewModel.selectActiveAccount(id: account.id) }
                        }
                    }
                } label: {
                    summaryRow(title: "Apple ID", value: selectedAccountCompactSummary, showsDisclosure: true)
                }
                .tint(.primary)
            }
            Divider().padding(.leading, 14)

            summaryRow(title: "Apple ID 证书", value: certificateSummary)
            Divider().padding(.leading, 14)
            summaryRow(title: "扩展", value: extensionSummary)
        }
        .padding(.horizontal, 14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    private func bundleIDRow(
        title: String,
        value: String,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 96, alignment: .leading)
                .layoutPriority(1)

            HighlightedBundleIDText(value: value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.sealTextSecondary.opacity(0.75))
            }
        }
        .frame(minHeight: 42)
        .contentShape(Rectangle())
    }
    private func summaryRow(
        title: String,
        value: String,
        monospaced: Bool = false,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .regular, design: monospaced ? .monospaced : .default))
                .foregroundColor(Color.sealTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.sealTextSecondary.opacity(0.75))
            }
        }
        .frame(minHeight: 42)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func appIcon(size: CGFloat) -> some View {
        Group {
            if let data = viewModel.iconData[workingApp.id], let image = UIImage(data: data) {
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

    private var displayBundleIdentifier: String {
        targetBundleID.isEmpty
            ? ((try? BundleIDPolicy.targetBundleIdentifier(for: workingApp)) ?? workingApp.originalBundleIdentifier)
            : targetBundleID
    }

    private var requestedBundleIDForSigning: String? {
        guard isRenewal == false else { return nil }
        let trimmed = targetBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var bundleIDValidationError: String? {
        guard isRenewal == false else { return nil }
        let trimmed = targetBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return BundleIDPolicy.validationError(for: trimmed)
    }

    private func resetBundleIDDraftIfNeeded() {
        // 已签名/已安装/Seal 自身（续签）保留已记录的 Bundle ID，不重新生成
        if workingApp.belongsInInstalledList || workingApp.belongsInSignedList || workingApp.isSeal {
            guard targetBundleID.isEmpty else { return }
            targetBundleID = (try? BundleIDPolicy.targetBundleIdentifier(for: workingApp)) ?? workingApp.originalBundleIdentifier
            return
        }
        // 用户手动编辑过 Bundle ID → 保留用户编辑，不自动重新生成
        if hasUserEditedBundleID, !targetBundleID.isEmpty {
            return
        }
        // 未签名且用户未手动编辑：
        // - 有 preferredBundleIdentifier → 用已保存的
        // - 否则每次打开/回到配置抽屉都重新生成 0-999 随机后缀
        if let preferred = workingApp.preferredBundleIdentifier,
           !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            targetBundleID = preferred
            hasUserEditedBundleID = true
        } else {
            // 传入当前选中账号的 teamID，确保 UI 显示的推荐 Bundle ID 与实际签名时一致
            if let teamID = selectedAccount?.teamID, !teamID.isEmpty {
                targetBundleID = BundleIDPolicy.recommendedBundleIdentifier(
                    for: workingApp.originalBundleIdentifier,
                    teamID: teamID
                )
            } else {
                targetBundleID = BundleIDPolicy.recommendedBundleIdentifier(
                    for: workingApp.originalBundleIdentifier
                )
            }
        }
    }

    /// 切换 Apple ID 后，全新未签且未手动改过 Bundle ID 的，用新账号 teamID 重算推荐 Bundle ID，
    /// 使 `.seal.<TeamID>` 跟随所选账号变化；已签/已安装/Seal 自身不动（Bundle ID 已注册）。
    private func regenerateBundleIDForAccountChange() {
        guard isRenewal == false else { return }
        guard workingApp.belongsInInstalledList == false,
              workingApp.belongsInSignedList == false,
              workingApp.isSeal == false else { return }
        guard hasUserEditedBundleID == false else { return }
        if let teamID = selectedAccount?.teamID, teamID.isEmpty == false {
            targetBundleID = BundleIDPolicy.recommendedBundleIdentifier(
                for: workingApp.originalBundleIdentifier,
                teamID: teamID
            )
        } else {
            targetBundleID = BundleIDPolicy.recommendedBundleIdentifier(
                for: workingApp.originalBundleIdentifier
            )
        }
    }

    private var workingApp: AppRecord {
        viewModel.apps.first(where: { $0.id == app.id }) ?? app
    }

    private var selectedAccount: AppleAccountRecord? {
        if isRenewal, let accountID = workingApp.accountID {
            return viewModel.accounts.first { $0.id == accountID }
        }
        guard let resolvedSelectedAccountID else { return nil }
        return viewModel.verifiedAccounts.first { $0.id == resolvedSelectedAccountID }
    }

    private var selectedAccountCompactSummary: String {
        guard let selectedAccount else { return "请选择" }
        return viewModelFullEmail(for: selectedAccount)
    }

    private func viewModelFullEmail(for account: AppleAccountRecord) -> String {
        viewModel.fullEmail(for: account)
    }

    private func accountPickerTitle(_ account: AppleAccountRecord) -> String {
        let email = viewModelFullEmail(for: account)
        if let serial = account.certificateSerialNumber, serial.isEmpty == false {
            let compact = AppSigningPresentationHelpers.compactSerial(serial)
            return "\(email) · \(compact)"
        }
        return "\(email) · 无证书"
    }

    private var certificateSummary: String {
        guard let selectedAccount else { return "未准备" }
        let serial = try? SigningCertificateSelectionPolicy.resolvedSerialNumber(
            for: workingApp,
            account: selectedAccount
        )
        guard let serial, serial.isEmpty == false else { return "签名时创建" }
        return AppSigningPresentationHelpers.certificateName(serial: serial)
    }

    private var statusText: String {
        workingApp.belongsInInstalledList ? "已安装" : "待签名"
    }

    private var extensionSummary: String {
        workingApp.extensions.isEmpty ? "无" : "\(workingApp.extensions.count) 个"
    }

    private func primaryActionTitle(for presentation: AppOperationPresentation) -> String {
        resolvedSelectedAccountID == nil ? "去添加 Apple ID" : presentation.primaryAction
    }

    private var isRenewal: Bool {
        workingApp.belongsInInstalledList
    }

    private var isRunning: Bool {
        if case .running = viewModel.signingSession?.status { return true }
        return false
    }

    private func selectDefaultAccount() {
        if isRenewal {
            selectedAccountID = workingApp.accountID
            return
        }
        guard selectedAccountID == nil else { return }
        selectedAccountID = resolvedSelectedAccountID
    }

    private var resolvedSelectedAccountID: UUID? {
        let verifiedAccounts = viewModel.verifiedAccounts.sorted { $0.lastVerifiedAt > $1.lastVerifiedAt }
        if let selectedAccountID,
           verifiedAccounts.contains(where: { $0.id == selectedAccountID }) {
            return selectedAccountID
        }
        if isRenewal {
            return workingApp.accountID
        }
        if let activeAccountID = viewModel.activeAccountID,
           verifiedAccounts.contains(where: { $0.id == activeAccountID }) {
            return activeAccountID
        }
        return verifiedAccounts.first?.id
    }

    private func validityColor(_ tone: AppValidityTone) -> Color {
        switch tone {
        case .success: .sealSuccess
        case .neutral: .sealTextSecondary
        case .warning: .sealWarning
        case .danger: .sealDanger
        }
    }

    private func standardAlert(_ failure: ImportFailure) -> Alert {
        Alert(
            title: Text(failure.title),
            message: Text(failure.userMessage),
            dismissButton: .default(Text(failure.recovery)) {
                viewModel.performAlertRecovery(for: failure)
            }
        )
    }

    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}


private struct HighlightedBundleIDText: View {
    let value: String

    var body: some View {
        BundleIDSealHighlighter.text(
            value,
            baseColor: Color.sealTextSecondary,
            highlightColor: Color.sealAccent
        )
        .font(.system(size: 13, weight: .regular, design: .monospaced))
    }
}

private struct HighlightedBundleIDTextField: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.keyboardType = .URL
        textField.returnKeyType = .done
        textField.clearButtonMode = .whileEditing
        textField.font = BundleIDSealHighlighter.uiFont
        textField.tintColor = UIColor(Color.sealAccent)
        textField.defaultTextAttributes = BundleIDSealHighlighter.defaultTypingAttributes
        textField.typingAttributes = BundleIDSealHighlighter.defaultTypingAttributes
        textField.attributedPlaceholder = NSAttributedString(
            string: "Bundle ID",
            attributes: [
                .font: BundleIDSealHighlighter.uiFont,
                .foregroundColor: UIColor.placeholderText
            ]
        )
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        if textField.text != text {
            context.coordinator.setHighlightedText(text, on: textField)
        } else {
            context.coordinator.refreshHighlight(on: textField)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: HighlightedBundleIDTextField

        init(parent: HighlightedBundleIDTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            parent.text = textField.text ?? ""
            refreshHighlight(on: textField)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        func setHighlightedText(_ value: String, on textField: UITextField) {
            let selectedRange = textField.selectedTextRange
            textField.attributedText = BundleIDSealHighlighter.attributedString(value)
            textField.typingAttributes = BundleIDSealHighlighter.defaultTypingAttributes
            if let selectedRange {
                textField.selectedTextRange = selectedRange
            }
        }

        func refreshHighlight(on textField: UITextField) {
            setHighlightedText(textField.text ?? "", on: textField)
        }
    }
}

private enum BundleIDSealHighlighter {
    static let marker = ".seal"
    static let uiFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    nonisolated(unsafe) static let defaultTypingAttributes: [NSAttributedString.Key: Any] = [
        .font: uiFont,
        .foregroundColor: UIColor.secondaryLabel
    ]

    static func text(
        _ value: String,
        baseColor: Color,
        highlightColor: Color
    ) -> Text {
        guard let range = value.range(of: marker, options: [.caseInsensitive]) else {
            return Text(value).foregroundColor(baseColor)
        }
        let before = String(value[..<range.lowerBound])
        let highlighted = String(value[range])
        let after = String(value[range.upperBound...])
        return Text(before).foregroundColor(baseColor)
            + Text(highlighted).foregroundColor(highlightColor)
            + Text(after).foregroundColor(baseColor)
    }

    static func attributedString(_ value: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: value,
            attributes: defaultTypingAttributes
        )
        let range = (value as NSString).range(of: marker, options: [.caseInsensitive])
        if range.location != NSNotFound {
            attributed.addAttributes(
                [
                    .font: uiFont,
                    .foregroundColor: UIColor(Color.sealAccent)
                ],
                range: range
            )
        }
        return attributed
    }
}
private struct AppIconSelectionSheet: View {
    enum Action {
        case photos
        case files
        case original
    }

    let onSelect: (Action) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SealDrawer(title: "修改 App 图标") {
            Text("选择新的主屏幕图标。修改会写入签名后的 IPA；选择原图会清除当前草稿图标。")
                .font(.subheadline)
                .foregroundColor(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
        } footer: {
            VStack(spacing: 10) {
                Button("从照片选择") { onSelect(.photos) }
                    .sealPrimaryAction(cornerRadius: 14)
                Button("从文件选择") { onSelect(.files) }
                    .sealOutlineAction(cornerRadius: 14)
                Button("使用原图") { onSelect(.original) }
                    .sealOutlineAction(cornerRadius: 14)
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(Color.sealTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
        }
    }
}

private struct BundleIDEditorSheet: View {
    let initialValue: String
    let onSave: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var isSaving = false

    init(initialValue: String, onSave: @escaping (String) async -> Bool) {
        self.initialValue = initialValue
        self.onSave = onSave
        _draft = State(initialValue: initialValue)
    }

    var body: some View {
        SealDrawer(title: "修改 Bundle ID") {
            VStack(alignment: .leading, spacing: 10) {
                HighlightedBundleIDTextField(text: $draft)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 48)
                    .background(Color.sealSurfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let error = validationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.sealDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 12)
        } footer: {
            HStack(spacing: 12) {
                Button("取消") { dismiss() }
                    .sealOutlineAction(cornerRadius: 12)
                Button {
                    isSaving = true
                    Task { @MainActor in
                        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        let saved = await onSave(value)
                        isSaving = false
                        if saved { dismiss() }
                    }
                } label: {
                    if isSaving { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("保存") }
                }
                .sealPrimaryAction(cornerRadius: 12)
                .disabled(validationError != nil || isSaving)
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var validationError: String? {
        BundleIDPolicy.validationError(for: draft)
    }
}

private struct AppNameEditorSheet: View {
    let initialValue: String
    let onSave: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var isSaving = false

    init(initialValue: String, onSave: @escaping (String) async -> Bool) {
        self.initialValue = initialValue
        self.onSave = onSave
        _draft = State(initialValue: initialValue)
    }

    var body: some View {
        SealDrawer(title: "修改 App 名称") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("App 名称", text: $draft)
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 48)
                    .background(Color.sealSurfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if trimmed.isEmpty {
                    Text("App 名称不能为空")
                        .font(.caption)
                        .foregroundStyle(Color.sealDanger)
                }
            }
            .padding(.bottom, 12)
        } footer: {
            HStack(spacing: 12) {
                Button("取消") { dismiss() }
                    .sealOutlineAction(cornerRadius: 12)
                Button {
                    isSaving = true
                    Task { @MainActor in
                        let saved = await onSave(trimmed)
                        isSaving = false
                        if saved { dismiss() }
                    }
                } label: {
                    if isSaving { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("保存") }
                }
                .sealPrimaryAction(cornerRadius: 12)
                .disabled(trimmed.isEmpty || isSaving)
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
