# Seal 应用内更新（内置下载 + 覆盖安装）技术规范

> 日期：2026-09-10　版本：v2（含实现明细与编译失败根因）　状态：已实现，待真机回归
> 关联：`REWRITE_ROADMAP.md` · `DEBUG_LOG.md` · `ERROR_COPY_AUDIT_20260909.md`

---

## 1. 背景与目标

更新公告弹窗原来的「下载更新」仅跳转浏览器打开 GitHub Release 页，需要用户手动下载 `.ipa`、再导入、再签名，链路冗长。

本方案实现「**App 内点一下 → 自动下载 → 自动导入 → 自动弹出签名抽屉 → 覆盖安装 Seal**」，把用户操作从多步收窄为「点下载 → 点签名安装」。

### 目标（最终形态）

| 阶段 | 行为 |
|---|---|
| 点「下载更新」 | 立即原地显示下载进度（转圈 + 百分比） |
| 下载完成 | 自动关闭弹窗、切到主列表、触发导入 |
| 导入完成（Seal 自身） | **自动弹出签名抽屉**（选账号/证书即可签） |
| 签名完成 | 覆盖安装 Seal 最新版，列表不残留重复记录 |

### 非目标（明确不做）

- 不做「所有 App 内置下载新版覆盖」的通用能力 —— **仅限 Seal 自身更新**。
- 不绕过签名：云编译产出是 **unsigned IPA**，iOS 安装必须先签名，本方案不可能做到「下载即装」。
- 不放宽第三方同 Bundle ID 去重（`SEAL-BUNDLE-004`）。

---

## 2. 核心约束：为什么必须重新签名

云编译工作流 `ios-fast.yml` 产出的是 **未签名 IPA**（步骤名 `Build fast unsigned IPA`）。iOS 安装任何 App 都必须带有效签名，且只能用用户**本机当前有效的证书 + 描述文件**签名（免费账号受证书 7 天有效期约束）。

因此「下载更新」的终点不是「安装完成」，而是「**已下载并导入，等你点一次签名**」。签名覆盖安装对 Seal 自身是**替换**（同 Bundle ID），不占免费账号 3 设备名额，不改 Bundle ID。

---

## 3. 关键标识与常量

| 标识 | 值 | 出处 |
|---|---|---|
| Seal Bundle ID | `com.mjorb.seal` | `project.yml` → `PRODUCT_BUNDLE_IDENTIFIER`、`SealOriginalBundleIdentifier` |
| 更新仓库 | `sunuannian1/Seal-Releases` | `UpdateChecker.repo` |
| 下载目录 | `<Application Support>/Seal/Downloads` | `UpdateIPADownloader.downloadsDirectory` |
| 自更新判定 | `AppRecord.isSeal == true` | `AppRecord.swift` |
| 下载错误码前缀 | `SEAL-UPDATE-DL-*` | 见 §8 |
| 自更新待生效标记 | `AppRecord.hasPendingSelfUpdateSource` | `ImportWorkflow.makeSelfUpdateRecord` |

---

## 4. 现状盘点（已存在的自我更新通道，本次在其上叠加）

以下机制**代码已存在**，本方案不做推翻，只复用：

| 职责 | 位置 | 说明 |
|---|---|---|
| 判定「导入 IPA 是 Seal 自身更新」 | `SelfAppRecordSelection.preferredExistingSealRecordForImportedIPA` | 用 `isSeal` + 归一化匹配 `original / mapped / preferred` 三字段，命中返回既有 Seal 记录 |
| 覆盖时复用旧记录 id（替换而非新建） | `ImportWorkflow.makeSelfUpdateRecord` | `id: existingSeal.id`，继承旧签名/证书/描述文件/Team，仅更新版本/构建号/图标/IPA 路径 |
| 待生效自更新源标记 | `AppRecord.hasPendingSelfUpdateSource = true` | 安装成功后由 `SigningCoordinator` 归位为 `false` |
| 签名抽屉对 Seal 续签的 Bundle ID 豁免 | `AppSigningSheet.resetBundleIDDraftIfNeeded` | `workingApp.isSeal` 保留已注册 Bundle ID，不重新生成 |

> **结论**：导入路径对 Seal 自身**已经做到覆盖替换**，缺的是「从弹窗直接下载 + 自动进签名抽屉」。本次补齐这两段。

---

## 5. 总体链路（数据流）

```
UpdateChecker.check()
    │  解析 GitHub Release JSON（tag/name/body/html_url/assets）
    │  └─ 若有 .ipa 附件 → 记录 ipaDownloadURL + ipaSize
    ▼
UpdateNoticeView（更新公告弹窗）
    │  底部双按钮：取消 / 下载更新
    ▼
点击「下载更新」
    │  hasIPAAsset? 无 → 回退 openURL(html_url)
    │              有 → UpdateIPADownloader.download(...)
    ▼
UpdateIPADownloader（流式下载 + 进度回调）
    │  下载到 <AppSupport>/Seal/Downloads/seal-update-<uuid>.ipa
    │  完成回调 onInstall(localURL)
    ▼
RootTabView.onInstall
    │  withAnimation 关弹窗 → selection = .apps
    │  Task { await appsViewModel.importSelfUpdateFile(localURL) }
    ▼
AppsViewModel.importSelfUpdateFile
    │  置 autoOpenSigningAfterImport = true
    │  → ImportWorkflow.prepare(...)
    │      └─ 命中 existingSeal → makeSelfUpdateRecord（覆盖旧 id）
    │  → consumeWorkflowState → .completed(record)
    ▼
consumeWorkflowState .completed
    │  load(force: true)
    │  if autoOpenSigningAfterImport → selectedOperationApp = 刷新后的记录
    ▼
AppsRootView .sheet(item: $selectedOperationApp)
    │  AppSigningSheet 弹出（isSeal 记录保留原 Bundle ID）
    ▼
用户点「签名并安装」→ SigningCoordinator
    │  enforceBundleIdentifierUniqueness: isSeal 直接放行（不拦）
    │  签名 + 安装（覆盖）→ hasPendingSelfUpdateSource 归位 false
    ▼
完成：Seal 列表单条记录，版本更新
```

---

## 6. 逐文件实现明细（本次改动）

### 6.1 `Infrastructure/UpdateChecker.swift`
- `UpdateNotice` 新增字段：`ipaDownloadURL: URL?`、`ipaSize: Int64`。
- `check()` 解析时从 `json["assets"]` 数组取第一个 `.ipa` 后缀附件，读 `browser_download_url` + `size`；无附件时为 `nil`/`0`。
- 保留 `downloadURL`（`html_url`）作为无附件时的回退跳转地址。

### 6.2 `Infrastructure/UpdateIPADownloader.swift`（新增）
- `struct UpdateIPADownloader`（**无实例可变状态**，满足 Swift 6 并发），`static let shared`。
- `download(from:onProgress:)`：`URLSession.download(for:delegate:)` 流式下载，进度回传 `onProgress`（0–1），完成后 `moveItem` 到 `Seal/Downloads`，返回本地 URL。
- `deleteDownloadedFile(at:)`：导入成功后清理下载文件。
- `UpdateDownloadError`：`badHTTPStatus` / `saveFailed` / `transport(Error)`。
- `ProgressDownloadDelegate`：`URLSessionDownloadDelegate`，实现 `didWriteData`（换算进度）与 required 的 `didFinishDownloadingTo`（空实现，由调用方 moveItem）。

### 6.3 `Features/UpdateNoticeView.swift`
- 新增 `let onInstall: ((URL) -> Void)?`（可选，为 `nil` 时回退浏览器）。
- 新增 `@State phase: DownloadPhase`（`idle / downloading(Double) / failed(String)`）。
- 底部「下载更新」按钮按 `phase` 显示：待下载 / 进度百分比 / 失败「重试」。
- `handleUpdate()`：有 IPA 附件且 `onInstall != nil` → 下载；否则 `openURL(downloadURL)` + 关闭。
- 下载成功 `onInstall(localURL)`；失败 `phase = .failed(...)`。

### 6.4 `App/RootTabView.swift`
- overlay 中 `UpdateNoticeView` 传入 `onInstall`：关弹窗 → `selection = .apps` → `importSelfUpdateFile(localURL)` → 完成后 `deleteDownloadedFile`。

### 6.5 `Features/Apps/AppsViewModel.swift`
- 新增私有标志 `autoOpenSigningAfterImport`。
- 新增公开 `importSelfUpdateFile(_:)`（`autoOpenSigning: true`）；原 `importSelectedFile(_:)` 保持 `false`，普通导入行为不变。
- `consumeWorkflowState` `.completed(record)`：`load(force:true)` 后若 `autoOpenSigningAfterImport`，从刷新后的 `apps` 取 `record.id` 对应记录赋给 `selectedOperationApp`（触发签名抽屉），并重置标志。

### 6.6 `Core/Signing/SigningCoordinator.swift`
- `enforceBundleIdentifierUniqueness`：在归一化后、查库去重前，加 `if app.isSeal { return }` —— **Seal 自身覆盖放行**；第三方同 Bundle ID 仍走原拦截。

### 6.7 `Features/Settings/AboutView.swift`
- 关于页手动「检查更新」调用 `UpdateNoticeView` 时传 `onInstall: nil`（保持旧跳浏览器行为，AboutView 无导入能力）。

---

## 7. 并发与 Swift 6 规范（含本次编译失败根因）

项目编译参数为 **`-swift-version 6`**（严格并发检查）。本次首次提交在云编译 run #42 失败，根因是两个并发红线：

| # | 错误 | 根因 | 修复 |
|---|---|---|---|
| 1 | `static property 'shared' is not concurrency-safe because non-'Sendable' type 'UpdateIPADownloader' may have shared mutable state` | 原为 `final class` 且持有 `let fileManager`，非 Sendable 却暴露共享单例 | 改为 `struct`（无实例可变状态），`fileManager` 内联用 `FileManager.default` |
| 2 | `type 'ProgressDownloadDelegate' does not conform to protocol 'URLSessionDownloadDelegate'` + `onProgress` 非 Sendable | 缺 required `didFinishDownloadingTo`；`onProgress` 为非 `@Sendable` 闭包 | 补 `didFinishDownloadingTo` 空实现；`onProgress` 改为 `@Sendable (Double) async -> Void`（对齐 `InstallChannel`/`SigningCoordinator` 既有约定） |

### 并发约定（本项目统一）
- 跨线程进度回调签名：**`@Sendable (Double) async -> Void`**（见 `InstallChannel.install(onProgress:)`、`SigningCoordinator.onInstallProgress`）。
- UI 侧闭包用 `@MainActor` 参数标注，直接更新 `@State`，无需内层再套 `Task`。
- 下载器为无状态 `struct`，避免 `class` + `static` 共享可变状态。

---

## 8. 错误码规范

| 错误码 | 含义 | 触发场景 |
|---|---|---|
| `SEAL-UPDATE-DL-501` | 服务器响应异常 | `HTTPURLResponse` 非 200 |
| `SEAL-UPDATE-DL-502` | 文件保存失败 | `moveItem` 到下载目录失败 |
| `SEAL-UPDATE-DL-503` | 网络下载失败 | `URLSession` 抛错（断网/超时等） |

> 保持 `SEAL-<模块>-<类别><序号>` 唯一且可恢复引导；不得与既有 `SEAL-SIGN-404`、`SEAL-APPID-DEVICELIMIT`、`SEAL-BUNDLE-004` 等复用。

---

## 9. 风险与回退

| 风险 | 说明 | 对策 / 回退 |
|---|---|---|
| Release 无 `.ipa` 附件 | `browser_download_url` 解析不到 | `hasIPAAsset == false` → 回退**跳转浏览器**（`downloadURL`），不中断 |
| 下载文件被系统清理 | 大文件可能被系统释放 | 存到 **Application Support**（非 Caches/tmp），且失败可点「重试」 |
| 去重豁免误放行 | 若 Seal 判定过宽 → 放行非 Seal | 严格 `app.isSeal`，第三方仍走 `SEAL-BUNDLE-004`；回归样本验证不回归 |
| 覆盖安装残留重复记录 | 同 Bundle ID 覆盖可能残留第二条 | 复用 `makeSelfUpdateRecord` 复用 `existingSeal.id`，替换而非新增 |
| 下载中断/弱网 | 大文件下载失败 | 进度 + 失败「重试」；错误码引导恢复 |
| 导入后自动开抽屉时机 | `load(force:true)` 未刷新即赋值 | 先从刷新后 `apps` 取 `record.id` 对应项再赋值 `selectedOperationApp` |
| 编译/真机 | Windows 无法编译 Swift | 云编译 RustBridge + Seal；回归样本（微信/黄豆短剧/LCSign/lanmanga）验证普通去重不受影响 |

---

## 10. 验证清单

- [ ] 更新弹窗「下载更新」→ 下载进度百分比平滑递增（深/浅色、强调色下样式正常）
- [ ] 下载完成 → 关弹窗 → 切主列表 → **自动弹出签名抽屉**
- [ ] 签名抽屉中 Seal 记录保留原 Bundle ID（`isSeal` 不重新生成）
- [ ] 点「签名并安装」→ 覆盖安装，`hasPendingSelfUpdateSource` 归位 `false`
- [ ] Seal 列表仅一条记录，版本号更新
- [ ] 普通第三方 IPA 导入仍触发 `SEAL-BUNDLE-004`（去重未被放宽）
- [ ] 无附件 Release → 回退跳浏览器，不报错
- [ ] 免费账号 3 设备限额：覆盖 Seal 不占新名额

---

## 11. 发版流程约定（Release 必须挂 IPA）

应用内下载依赖 Release 的 `assets` 里有 `.ipa` 附件，否则回退浏览器。发布新版时必须：

1. 云编译产出 `Seal.ipa`（`Seal-<run_number>` artifact）。
2. 在 `sunuannian1/Seal-Releases` 创建 Release 时，用 `gh release create <tag> Seal.ipa` 挂载 IPA 附件。
3. Release 的 `name` ／ `body` 即弹窗标题与更新内容（`body` 支持 Markdown，弹窗内会逐行去标记）。

> 若某个 Release 忘了挂 IPA，弹窗会自动降级为「跳转浏览器」，不会白屏或崩溃。

---

## 12. 已知限制 / 待办

1. **下载完成 → 签名仍需用户点一次**：受自签逻辑约束，无法「全自动装完」；当前已做到最短路径（下载→自动导入→自动弹抽屉）。
2. **进度不支持取消/断点续传**：下载中「取消」按钮仍可用（关闭弹窗即取消 Task），但无断点续传。
3. **关于页手动检查**仍走旧跳浏览器行为（`onInstall: nil`），与首页自动弹窗行为有意区分。
4. 若未来要做「通用 App 内置更新」，需另评审去重与签名策略，不在本方案范围。