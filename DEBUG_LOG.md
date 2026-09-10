# Seal Debug 记录（问题排查与修复日志）

> 用途：每次查出并修改的问题在此登记，记录「现象 → 根因 → 修复 → 涉及文件 → 验证状态」，
> 避免同类问题重复发生。新条目追加到「历史记录」顶部（最新在前）。
>
> 关联文档：`REWRITE_ROADMAP.md`（链路取舍）、`OPTIMIZATION_PLAN_*.md`（优化计划）、
> `ERROR_COPY_AUDIT_*.md`（报错文案口径）。

---

## 一、常犯坑位（教训沉淀，动手前先看）

### 1. 证书序列号跨来源比对必须先归一化
- **现象**：同一份证书，一处比对通过、另一处误判成「证书已被轮换 / 不在授权列表」。
- **根因**：序列号存在两种来源，格式不一致——
  - **AltSign**（`ALTCertificate.serialNumber` / `ALTX509Certificate.serialNumber`）走 big-number 十六进制，会剥掉最高半字节的前导 `0`（如 `E76A893…`）。
  - **Security 框架**（`ProvisioningProfileReader` 经 `SecCertificateCopySerialNumberData` 按 DER 字节 `%02X` 拼串）保留前导 `0`（如 `0E76A893…`）。
  - 直接 `caseInsensitiveCompare` 会把同一序列号当成两个不同值。
- **规矩**：凡是「AltSign 序列号 ↔ 描述文件/证书列表序列号」的比对，一律先过
  `SigningCertificateSelectionPolicy.normalizedSerialNumber(_:)`（去前导 0、转大写、只留十六进制）。
  同一来源内部的比对（如 AltSign↔AltSign，两端都剥前导 0）无需归一化，不要画蛇添足。
- **涉及文件**：`SigningCertificateSelectionPolicy.swift`（方法定义）、`ApplePortalSigningService.swift`、
  `SigningCoordinator.swift`、`ProvisioningProfileBinding.swift`、`AppPresentation.swift`、`SettingsViewModel.swift`。

### 2. 进度条「卡在 100%」的根因是阶段切换时机，不是进度值本身
- **现象**：大 IPA（如微信 ~500MB）上传进度到 100% 后，进度条长时间停在「正在传输 100%」，
  几十秒后才变「正在安装」。
- **根因**：上传（AFC 分块写）结束 ≠ 安装开始。中间隔着 Rust 侧预检（lookup / afcd 快照）以及
  installd 的解压/复制。旧逻辑只在「上传完成=100」处刷新进度，之后直到 installd 返回才切阶段，
  于是 UI 干等。
- **规矩**：需要三个信号的区分，不能把「上传完成」和「安装开始」混为一谈：
  - `0–100`：上传阶段真实进度。
  - **哨兵 `101`**（`INSTALL_ISSUED_PCT`，Rust 侧）：表示预检结束、installd 安装命令**即将下发**。
  - Swift 侧 trampoline 把 u64 的 `101` 换算成 `1.01`（`Double(pct)/100.0`），
    `p > 1.0` 即触发阶段从 `.pushing` 切到 `.installing`（文案「正在安装」），进度归 `1.0` 收尾。
- **涉及文件**：Rust `Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs`、
  `bridge_idevice.rs`；Swift `MinimuxerBridgeIdevice.swift`（trampoline）、
  `MinimuxerInstallChannel.swift`（哨兵透传）、`AppsViewModel.swift`（`updateInstallProgress` 切阶段）。

### 3. rg 命令别用 `-r` 当行号标志
- `rg -rn` 里的 `-r` 是「替换」flag（会把匹配内容替换成 `n`），不是行号；行号用 `-n`。
  避免 `-r` 与 `-n`、`-l` 混用导致的输出错乱。

### 4. 云编译结果别用 `gh run watch --exit-status` 的退出码当「成败」信号
- `gh run watch` 后台任务返回非零 exit code，是命令自身/超时问题，**不代表工作流失败**。
  判断成败一律看 `gh run list` / `gh run view` 的 `completed success/failure` 状态；
  别拿后台任务的 exit code 反推「云编译失败」，否则会把成功的构建误报成失败。

### 5. 掉签根因别一上来就甩给「证书过期/描述文件来源」
- 「今天签、明天掉」不是证书过期（免费证书有效期一年），也不该先怀疑 `SelfAppRegistrar`
  用当前 bundle 的 `expirationDate` 写库（签名安装成功时 `installSignedIPA` 会用签名当时的
  profile 过期时间覆盖它）。
- 真正要查的是「签名/续签时 profile 是否被复用、有没有刷新有效期」：
  `fetchProvisioningProfile`（`ApplePortalSigningService.swift:1213-1215`）对免费账号
  删除 profile 失败会直接复用现有 profile，其过期时间就是签名后 App 的有效期。
  先把 `provisioningProfiles → fetchProvisioningProfile → expirationDate` 这条链追清，
  再决定改哪，别先动 UI/文案。

---

## 二、历史记录

### 2026-09-10 · 定位「今天签 Seal、明天掉签」根因

- **现象**：用户报告「今天签名安装 Seal，明天就掉签、闪退打不开」；真机日志另有
  TLS 握手失败（NSURLErrorDomain -1200）与设备存储满（No space left / errno 28/ENOSPC）。
- **排查过程（含两次误判，均已纠正）**：
  1. 误判一：把 `gh run watch --exit-status` 的后台任务返回非零 exit code 当成「社群页
     云编译失败」，实际 `gh run list` 显示 `completed success`（8m55s）。教训见「常犯坑位 4」。
  2. 误判二：一度把 `SelfAppRegistrar`（`expiryDate: metadata.expirationDate`，
     `SelfAppRegistrar.swift:161/165`）当掉签根源。深读后发现签名安装成功时
     `installSignedIPA`（`SigningCoordinator.swift:608`）会用签名当时的 profile 过期时间
     覆盖 `expiryDate`，该写法语义正确，不是根因。
- **决定性根因（2026-09-09 20:37 crash 报告 `diskwrites_resource` 一锤定音）**：
  **这不是「掉签」，也不是「存储满」——是 iOS「磁盘写入资源保护」终止。**
  - 报告数据：`Event: disk writes`；29 分钟（1745s）写 **1073.76 MB**（615 KB/s 平均），
    超过系统 86400s 周期限额 1073.74 MB；`Free disk space: 19.48 GB`（磁盘未满，
    「存储满」判断被推翻）。
  - 栈证据：栈顶 `libswift_Concurrency`（一个 Task 持续 active）→ Seal 函数 →
    `Foundation`（Data 写文件）→ `libsystem_c` → `libsystem_kernel write`。
    即 SealLogStore.append 的「全量重写 + atomic 写」在某个高频日志任务下放大成 1GB 写入。
  - 真正代码缺陷：`SealLogStore.append`（`SealLogStore.swift:23-44`）**每条日志都做**
    ① `read()` 全量读 + JSON decode 200 条 → ② 全量 JSON encode + `write(to:.atomic)`
    （临时文件+rename 双写）+ `fileProtector.protect` → ③ error 级别再 `mirrorToDocuments()`
    （全量 exportText + 写整个 Seal-log.txt）。任意高频日志（每秒几条）都会被放大成
    615 KB/s 的持续磁盘写入，最终触发 iOS 磁盘写保护被杀。
- **已排除的假设（记录防回头重复推理）**：
  - 免费账号 profile 复用（`fetchProvisioningProfile` 删除失败 `return profile`）——被「7 天」推翻。
  - `SelfAppRegistrar` 用 `metadata.expirationDate` 写库——语义正确，非根因。
  - 证书序列号归一化——已修（`34e6ae7` + rork-sign `formattedSerialNumberHex` 已剥前导零）。
  - 设备存储满（ENOSPC）、证书过期、TLS 中断——均非本次「闪退」直接根因。
- **修复方向**：根治 `SealLogStore` 的 O(n) 全量重写放大问题——
  (1) append 改为内存缓冲 + 节流批量落盘（debounce，去掉每条日志的全量读/写）；
  (2) 落盘用非 atomic 覆盖写，去掉 `protect` 的每次调用（或大幅降低频率）；
  (3) error 镜像 `mirrorToDocuments` 节流。同时定位「高频打日志」的任务源头一并收敛。
- **涉及文件**：`SealLogStore.swift`（核心）；`AppsViewModel.swift` / `SettingsViewModel.swift`
  （高频 append 调用点）。
- **验证状态**：待修复后真机复验（观察 crash 是否消失 + 日志是否仍可读/导出）。

### 2026-09-09 · 修复 Seal 无法自续签

- **现象**：Seal 自续签失败，日志/报错指向「证书已被轮换 / 不在授权列表」，
  但用户并未更换证书。更换 Apple ID、清缓存后依旧。
- **根因**：证书序列号跨来源比对未归一化（见「常犯坑位 1」）。AltSign 返回的本地证书序列号
  剥掉了前导 0，描述文件 `certificateSerialNumbers` 保留前导 0，同一证书被判成两个，
  触发「证书已轮换」误报 → 续签链路中断。
- **修复**：新增 `SigningCertificateSelectionPolicy.normalizedSerialNumber(_:)`，
  统一「去前导 0、转大写、只留十六进制」；在 5 个跨来源比对点全部改用该方法：
  - `ApplePortalSigningService.swift`：签名前证书授权校验（`chosenSerial` vs 描述文件授权序列号清单）。
  - `SigningCoordinator.swift`：安装前描述文件授权证书匹配校验。
  - `ProvisioningProfileBinding.swift`：描述文件绑定校验（`normalizedSerial` 委托复用）。
  - `AppPresentation.swift`：证书匹配展示状态（`.mismatch` 误判）。
  - `SettingsViewModel.swift`：证书健康状态 / 关联应用计数。
- **涉及文件**：上述 5 个 + `SigningCertificateSelectionPolicy.swift`。
- **验证状态**：本机 Windows 无法编译 Swift，待 Xcode 编译 + 真机回归样本
  （微信 / 黄豆短剧 / LCSign / lanmanga）验证自续签与「本地证书复用前与 Apple 生效列表比对」路径。

### 2026-09-09 · 修复签名微信进度卡在 100%

- **现象**：签名微信时（约 500MB+），上传到 1 分 30 秒显示 100%，进度条一直停到 2 分 20 秒
  才消失、才变「正在安装」，进度不精准。附带观察：此前报「内存不足」（清理设备空间后重试可见
  进度问题）。
- **根因**：见「常犯坑位 2」。上传完成（=100）后 UI 仍停在「正在传输」，直到 installd 完成
  安装才切换阶段，中间几十秒的解压/复制被误显示为「传输中」。
- **修复**：Rust 侧在本轮之前已新增 `INSTALL_ISSUED_PCT = 101` 哨兵，在 `run_install_chain`
  即将向 installd 下发安装命令时回调。本轮补齐 Swift 侧消费逻辑：
  - `MinimuxerInstallChannel.swift`：`syncProgress` 收到 `p > 1.0` 时统一转发 `1.01` 给上层
    （普通安装也消费该哨兵，不再像旧逻辑直接 `return` 丢弃）。
  - `AppsViewModel.swift`：`updateInstallProgress` 收到 `progress > 1.0` 时把 `installProgress`
    归 `1.0`，并把阶段从 `.pushing` 切到 `.installing`。
  - UI 层 `SigningProgressView` 只在 `.pushing` 且 `0 <= progress <= 1` 显示进度条，
    `.installing` 显示「正在安装」，故哨兵触发后进度条立即消失、文案切换。
- **涉及文件**：`MinimuxerInstallChannel.swift`、`AppsViewModel.swift`（Rust 侧已在此前提交）。
- **验证状态**：待 Xcode 编译 RustBridge + 真机回归样本验证「上传 100% → 正在安装」切换是否及时、无闪烁。

### 附注（待真机核实，暂未改代码）

- 微信签名期初的「内存不足」：代码库中无字面「内存不足」文案，存储类错误已统一分类为
  「设备存储空间不足」（`SEAL-INSTALL-702s`，识别 `No space left / ENOSPC / errno 28 / code 28 /
  空间不足 / 储存空间 / 存储空间`）。该现象疑似 = 设备存储不足（已被现有分类覆盖）或设备侧瞬时
  RAM 压力，待真机日志复核，暂不新增代码。