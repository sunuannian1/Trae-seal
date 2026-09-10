# Seal 应用内更新（内置下载 + 覆盖安装）规范

> 日期：2026-09-10　状态：待评审　范围：更新公告弹窗「下载更新」→ 内置下载 IPA → 覆盖安装 Seal 自身

## 1. 背景与问题

更新公告弹窗当前「下载更新」按钮跳转浏览器打开 GitHub Release 页，用户需手动下载 .ipa 再导入安装。我们希望改为**直接在 App 内下载并覆盖安装 Seal 最新版**。

但遇到核心矛盾：

- **导入 Seal.ipa 命中既有去重**：`SigningCoordinator.enforceBundleIdentifierUniqueness`（`SEAL-BUNDLE-004`）对「目标 Bundle ID 已被同 ID 已装应用占用」提前拦截。
- 之所以会被拦：**再次导入 Seal.ipa 会新建一条记录（新 `id`）**，而该检查排除的是「`record.id == app.id`」的同一条记录（续签覆盖场景）。新条目的 `id ≠ 已装旧 Seal 的 id`，于是被判为冲突。

本规范确定处理方式（已与负责人确认）：

> **只豁免 Seal 自身 + 覆盖时替换旧记录 + 仅用于 Seal 更新弹窗。**

## 2. 现状：Seal 自我更新通道（已存在，需理解并复用）

以下机制**已经实现**，本次不做推翻，只在其之上让「应用内下载」自动接入：

| 职责 | 位置 | 说明 |
|---|---|---|
| 判定「导入的 IPA 是 Seal 自身更新」 | `SelfAppRecordSelection.preferredExistingSealRecordForImportedIPA` | 用 `isSeal` + 归一化匹配 `originalBundleIdentifier / mapped / preferred` 三字段，命中返回既有 Seal 记录 |
| 覆盖时复用旧记录 id（替换而非新建） | `ImportWorkflow.makeSelfUpdateRecord` | 直接 `id: existingSeal.id`，继承旧签名/证书/描述文件/Team 等全部字段，仅更新版本/构建号/图标/IPA 路径 |
| 标记待更新源 | `AppRecord.hasPendingSelfUpdateSource = true` | 记录来自自我更新，供后续续签/刷新识别 |

结论：**导入路径对 Seal 自身已经做到「覆盖替换旧记录」**。缺的只是「从更新弹窗直接下载 .ipa 并喂给导入流程」，以及确认去重检查不会拦下这条 Seal 覆盖路径。

## 3. 目标方案（三段式）

### 3.1 Release 带 IPA 附件
- `Seal-Releases`（`sunuannian1/Seal-Releases`）发布的每个**新版本 Release** 需挂载 `.ipa` 附件。
- `UpdateChecker` 从 `assets` 数组解析出 `browser_download_url` + `size`（.ipa 附件），供下载与进度条使用。

### 3.2 内置下载服务（新增 `DownloadService`）
- 用 `URLSession.downloadTask` / `download(for:)` 流式下载到 App 的 Documents（大文件不进内存，遵循项目「大包流式」纪律）。
- 带 0–100 进度回调和完成回调；失败可重试。
- 下载完成返回本地 `.ipa` 文件 URL，交给现有 `AppsViewModel.importSelectedFile(_ url:)`。

### 3.3 弹窗 UI 与覆盖安装
- 「下载更新」按钮：先显示下载进度（转圈/进度条）→ 下载完成自动进入导入流程。
- 导入 Seal.ipa → `existingSeal` 命中 → `makeSelfUpdateRecord` 覆盖旧记录 → 用户确认后走既有签名 + 安装链，**覆盖安装 Seal 新版**。
- 覆盖安装完成后，Seal 列表只保留一条记录（旧记录被替换，不残留重复）。

## 4. Seal 专属去重豁免（改动点）

### 4.1 在 `enforceBundleIdentifierUniqueness` 增加 Seal 豁免
在抛 `SEAL-BUNDLE-004` 之前，增加判断：**若目标 Bundle ID 与「同一款 Seal」的已装记录一致，属于升级覆盖，放行**。

判定依据（安全原因，仅 Seal 自身）：
- 目标记录 `isSeal == true`，且其 ID（`original/mapped/preferred`）命中同一 Seal 的已装记录。
- **不放行第三方同 Bundle ID 覆盖**：普通用户没有能力做「同 Bundle ID 覆盖安装」，且项目纪律明确要防「重复身份记录与文件夹」，第三方仍走原去重。

实现注意（对照 `SelfAppRecordSelection.preferredExistingSealRecordForImportedIPA` 的匹配逻辑，避免两边不一致）：
- Bundle ID 一律先 `trim + lowercase` 归一化再比较。
- 目标 Seal 记录的判定用 `isSeal`；匹配集合为 `originalBundleIdentifier / mappedBundleIdentifier / preferredBundleIdentifier`。

### 4.2 不重复造轮子
- 覆盖时「替换旧记录」复用 `ImportWorkflow.makeSelfUpdateRecord`（已实现），本次**不新增记录合并逻辑**。
- 下载后导入复用 `AppsViewModel.importSelectedFile`，**不新建导入分支**（仅当 URL 为本地下载文件时走同一入口）。

## 5. 入口限定

- 此「应用内下载 + 覆盖」**仅用于更新公告弹窗的 Seal 更新**。
- 不进普通导入列表、不开放给第三方 App、不做「所有应用下载新版覆盖」的通用能力。
- 保证影响面最小，不牵动签名/续签/安装三环节的既有链路。

## 6. 实现注意 / 风险与回退

| 风险 | 说明 | 对策 / 回退 |
|---|---|---|
| 去重豁免误放行 | 若 Seal 判定写宽→可能放行非 Seal | 严格以 `isSeal` + 归一化 ID 匹配，单测覆盖 Seal 与非 Seal 案例 |
| 下载文件被系统清理 | Documents 大文件可能被系统释放 | 存到不被清理的目录（如 Application Support），且下载失败可重试 |
| 覆盖安装残留重复记录 | memory 警告同 Bundle ID 覆盖会残留第二条记录 | 沿用 `makeSelfUpdateRecord` 复用 `existingSeal.id`，替换而非新增；安装后走 `removeDuplicateInstalledRecords`（已排除 Seal） |
| Release 无 .ipa 附件 | `browser_download_url` 解析不到 | 回退为当前「跳转浏览器 Release 页」，不中断 |
| 下载中断/限流 | 大文件、弱网 | 进度 + 失败重试按钮；错误码规范 `ImportFailure(title/reason/recovery/code)` |
| 编译/真机验证 | Windows 无法编译 Swift | 云编译 RustBridge + Seal target；回归样本（微信 / 黄豆短剧 / LCSign / lanmanga）验证普通去重不受影响 |

## 7. 验证清单

- [ ] 更新弹窗「下载更新」→ 显示下载进度 → 完成后进入导入
- [ ] Seal.ipa 导入命中 `existingSeal`，覆盖旧记录（id 不变），列表不残留重复
- [ ] 普通第三方 IPA 导入仍走 `SEAL-BUNDLE-004`（去重不被放宽）
- [ ] Release 无附件时回退跳转浏览器，不报错
- [ ] 深/浅色主题、强调色下弹窗与进度 UI 显示正常

## 8. 待确认项（实现前）

1. `DownloadService` 存放路径（Documents vs Application Support）——建议 Application Support，避免系统清理。
2. 下载完成是否**自动进入签名抽屉**（推荐）还是停留在弹窗由用户点下一步。
3. Release 附件命名/大小限制（建议明确「每个新版本必须挂 .ipa」写入发版流程）。