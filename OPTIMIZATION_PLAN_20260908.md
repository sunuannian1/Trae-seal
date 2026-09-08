# 自签链路优化计划（2026-09-08 讨论整合）

> 依据当天一轮讨论（现状核查 / 待优化清单 / 大包提速）整合。
> 目标：定位当前自签/续签链路的问题，列出可执行、可按优先级推进的优化项。
> 状态约定：`[待做]` `[进行中]` `[已完成]` `[暂缓]`

---

## 1. 背景与目标

Seal 为纯 iOS 自签工具，运行在手机上，经 LocalDevVPN 无线隧道 + Minimuxer 把 IPA
传给自己并调用 installation_proxy 安装，支持免费 Apple ID 签名、安装与 7 天续签。

本轮围绕四类反馈做核查，目标是弄清「哪些已实现、哪些缺、以及大包如何提速」。

---

## 2. 现状核查结论（4 点逐一对照）

### 2.1 微信 / 黄豆短剧可签名安装 —— ✅ 已完成
- 已提交的签名修复：清理空 `Frameworks/PlugIns` 目录（iOS 18 installd 对空目录的
  bundle discovery 直接抛 `APIInternalError`）；ESign 布局归一化（根目录 framework
  移入 `Frameworks/` + `@executable_path`→`@rpath`）；ESign 注入引用全二进制字节级替换。
- 微信 / 黄豆短剧 / LCSign / lanmanga 均列入回归样本（见 `REWRITE_ROADMAP.md`）。
- 二期「zsign 核心 + ZIPFoundation 重写」仍为待做，当前签名走 rork-sign。

### 2.2 第 4 个转圈、无「已装 3 个」提示 —— ⚠️ 意图已标注，实现缺失（当前编译不过）
- `Seal/Core/Signing/SigningCoordinator.swift` 第 102–108 行有未提交改动：
  注释声明「免费账号每台设备最多同时装 3 个自签应用（含 Seal 自身），按本机记录提前拦截」，
  并调用 `try await enforceFreeAccountInstallLimit(app: app)`。
- **但该函数全仓库无定义**（仅此一处调用，未存在于提交历史）→ 工作区处于编译失败中间态。
- 结果：签第 4 个不会提前拦截，照常进入传输，最终靠 installd 模糊报错 / 上传 30 分钟
  封顶超时收场，期间一直转圈，无提示。
- **处置：P0 补全该函数（见 §4.1）。**

### 2.3 大内存应用传输慢、续签 20 分钟 —— 部分覆盖，无进度 / 无分块
- 已做：合并调用上传+安装（上传预算 `min(1800, 180+MB*5)`s + 安装 600s）；安装期后台保活；
  `MissingPackagePath`/socket 类错误自动重试（最多 3 次）。
- 缺：传输是单次阻塞 FFI（`Minimuxer.stageAndInstall`），无分块写、无进度回读，
  UI 只有「正在传输到设备」转圈；超时后 `MissingPackagePath` 触发**整包重传**（大包灾难）。
- 慢的根因：无线 AFC 带宽为物理上限（1GB 必慢，无 USB 选项）。

### 2.4 插件 / App ID 问题 —— 代码逻辑正确，需编译后实测复验
- **插件各占 1 个 App ID**：`provisioningProfiles()` 用 `appExtensions` 枚举全部扩展，
  Phase 1 逐个 `addAppID`；免费账号 10 个 App ID 上限预检（`SEAL-APPID-LIMIT`），
  装不下的扩展在 `allowDroppingExtensions=true` 下自动跳过只签主 App。
  → 「插件占用 App ID」为正常且符合 Apple 规则；但插件**不计入**「每台 3 个」设备槽位。
- **续签应刷新插件日期**：续签走 `signAndInstall(forceResign:true)` 完整重签，
  `RorkAppSigner` 重新嵌入主 App 与每个扩展的新描述文件，
  `applySigningResult` 回写 `app.extensions[i].provisioningProfileExpirationDate`；
  原 bundle 相同 → 复用已注册 App ID，不新增消耗。
- 配套未提交改动：`AppDetailView.swift` 新增逐插件到期时间展示并着色
  （过期红 / 2 天内黄 / 正常绿），用于实测验证续签后插件 profile 是否刷新。
- **处置：P0 修编译后，用该页复验；若仍不刷新再查 `provisioningProfiles`/`RorkAppSigner`。**

---

## 3. Apple 官方限制（任何工具相同，代码层不可消除）

| 限制 | 数值 | 说明 |
|---|---|---|
| 应用有效期 | 7 天 | 续签必须连 Apple 服务器 |
| 每台设备同时安装 | **3 个**自签应用（含签名工具自身） | 超限 installd 报最大应用错误 `[已完成拦截：SEAL-APPID-DEVICELIMIT]` |
| App ID 上限 | 10 个 / 7 天 | 插件独立占用；无法手动删除，到期自动回收 |
| 证书设备数 | 3 台 / 证书 | |
| 网络 | gsa.apple.com 国内时通时断 | 已内置 3s/8s 自动重试；持续 503 需梯子或等待 |

参考：免费账号 3 应用 / 10 App ID 限制为 SideStore FAQ 与 Sideloadly 等工具共同确认
[[SideStore FAQ]](https://docs.sidestore.io/zh/docs/faq)
[[Sideloadly]](https://github.com/SideloadlyiOS/Sideloadly-Download/blob/main/README.md)。

---

## 4. 优化项清单（按优先级）

### P0 · 必须修（当前工程编译不过）
1. **补全 `enforceFreeAccountInstallLimit(app:)`** `[待做]`
   - 位置：`Seal/Core/Signing/SigningCoordinator.swift`。
   - 语义：按本机已安装记录计数（含 Seal 自身），达到 3 → 抛明确 `ImportFailure`
     （标题/原因/恢复建议），在进入 Apple 服务器与传输前拦截。
   - 归属依据：免费账号 3 应用设备上限；需统计本地已装应用数。
   - **实现注意**：按「同一签名账号/团队」维度计数，跨账号累计会误判
     （不同免费 Apple ID 的 3 个槽位互相独立）；Seal 自身占用 1 个槽位须计入。
   - 一并确认 `AppDetailView.swift` 未提交改动保留且编译通过。

### P1 · 体验优化（痛点 2.2 / 2.3）
2. **分块流式传输 + 进度回读** `[已完成 2026-09-08：实现，待 Xcode 编译 RustBridge + 真机]`
   - Rust：`stage_via_afc` 改分块写，每块按已写字节折算 0-100 回调（对齐上游 jas）；
     新增 `rust_bridge_idevice_stage_and_install_with_callback` FFI，旧 FFI 传空闭包保持兼容；
   - Swift：`Minimuxer`/`RustIdevice` 新增带进度重载 → `InstallChannel.install(onProgress:)` 升级
     为**协议要求**（extension 默认回退，保证经 `any InstallChannel` 正确派发）→
     `SigningCoordinator.onInstallProgress` → `SigningSession.installProgress` →
     `SigningProgressView` 在 `.pushing` 显示线性进度条 + 百分比；
   - 说明：此改动为**体感进度反馈**（AFC 底层已按 1MiB 分块，带宽上限不变，不缩短总时长）；
     「超时后整包重传」暂未覆盖，需断点续传，归入续签/传输加速评估。
3. **续签专用加速** `[部分落地 2026-09-08：低风险档，其余按决策暂缓]`
   - **已落地**：`RenewalCoordinator.interAppDelay` 由 1.5s 保守降至 0.75s（仅时间常量，
     不触碰签名/安装/续签三链路逻辑；需真机回归批量续签）。
     `baseRetryDelay` 刻意不动——关联 Apple 限流 503 自愈，激进缩短反而更慢。
   - **决策记录**：经评估后仅做低风险时间常数优化，下列两项**暂缓**：
     - 续签跳过改 ID / 剥架构：剥架构 arm64e 是瘦身关键必须保留，续签本不改 Bundle ID，
       实际几乎无收益，不投入。
     - 按剩余有效期阈值「按需续签」（未临期不重签）：改变「全部刷新」按钮用户预期，
       且本机（Windows）无法编译验证，需真机回归，暂缓。
   - 批量续签耗时根因：20 分钟大头是「无线带宽 + 整包重传」，非固定间隔；代码层削峰有限。

### P2 · 复验 / 少量优化
4. **插件续签日期实测复验** `[待做]`：P0 修编译后，用逐插件到期页核实。
5. **压缩级别明确 + 包体膨胀校验** `[待做]`（仅当大包提速需要再推进，见 §5）。

---

## 5. 大包提速专项

> 已确认结论：瓶颈是**无线传输带宽**（硬上限），签名/解压 CPU 非瓶颈。
> 提速 = 减少传输字节 + 减少无效等待重传。

### 5.1 已落地优化（勿重复）
| 环节 | 现状 | 意义 |
|---|---|---|
| 解压 | 系统 `unzipItem` 流式解压 | 500MB+ 不因内存失败 |
| 剥架构 | `stripArm64eArchitecture` 只留 arm64 | **直接瘦身**，传输/解压双向受益 |
| 重打包 | 显式 `deflate` | 比 store 小且兼容 installd |

### 5.2 可进一步推进（按性价比排序）
1. **明确压缩级别 + 包体校验** `[待做/暂缓]`
   - `package()` 的 `zipItem` 未显式指定级别；可显式 `.deflate` + 高压缩级别；
   - 加「签名后 IPA 体积 vs 原 IPA」日志/校验，确认剥离 arm64e 后确实更小、未膨胀。
   - 传输时间 ∝ 体积，线性收益；
   - **补充瘦身**：除已有的 arm64e 剥离外，可评估一并剥离 armv7 等遗留 32-bit slice
     （iOS 17/18 真机均 arm64，`REWRITE_ROADMAP` 已列为待覆盖，属同策略延续）。
2. **分块传输 + 进度** `[待做]`：见 §4-P1-2（带宽上限不变，但消除黑洞与无效重传）。
3. **续签跳过可省步骤 / 按需续签** `[待做]`：见 §4-P1-3（续签 20 分钟的主要削峰手段）。
4. **并发重打包压缩** `[暂缓]`：`zipItem` deflate 单线程，可并行压缩大条目；
   CPU 本地不吃紧，优先级低于 1–3。

### 5.3 明确不可突破（不投入）
- 无线 AFC 带宽（Seal 运行于手机、经 LocalDevVPN 无线传给自己，无 USB 选项）。
- installd 设备端安装耗时（覆盖安装需整包重传重装）。
- 7 天有效期 / 10 App ID / 3 台设备（Apple 政策）。

---

## 6. 建议推进顺序与验收

1. **P0** 补 `enforceFreeAccountInstallLimit` → 已完成（第 4 个提前明确提示，待真机复验）。
2. **P1** 分块传输+进度 → 已实现，待 Xcode 编译 RustBridge + 真机复验（消转圈黑洞）。
3. **P1** 续签提速（跳非必要步骤 / 按需续签）→ 削 20 分钟峰值，下一步。
3. **P2** 逐插件页复验续签刷新；需要再加压缩/包体校验。

每个优化落地后用 `REWRITE_ROADMAP.md` 的回归样本（微信 / 黄豆短剧 / LCSign / lanmanga）
做真机验证：可安装、续签覆盖安装且沙盒数据保留、断连自愈。

---

## 7. 涉及文件

| 文件 | 改动 |
|---|---|
| `Seal/Core/Signing/SigningCoordinator.swift` | 实现 `enforceFreeAccountInstallLimit`（SEAL-APPID-DEVICELIMIT）+ `onInstallProgress` 接线 |
| `Seal/Features/Apps/AppDetailView.swift` | **未提交**：逐插件到期时间展示（字段名已存在，可编译） |
| `Seal/Infrastructure/Signing/SigningWorkspace.swift` | 已含大包优化（流式解压 / 剥 arm64e / deflate） |
| `Seal/Infrastructure/Signing/ApplePortalSigningService.swift` | App ID 上限预检（`SEAL-APPID-LIMIT`）、逐扩展注册 App ID |
| `Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift` |安装合并调用、超时预算、无进度回读 |
| `Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs` | `stage_via_afc` 分块写 + 0-100 回调 |
| `Vendor/Minimuxer/RustBridge/src/bridge_idevice.rs` | 新增 `_with_callback` FFI |
| `Vendor/Minimuxer/RustBridge/MinimuxerBridgeIdevice.swift` | C 回调 trampoline + 带进度 wrapper |
| `Vendor/Minimuxer/Sources/Minimuxer.swift` | 带进度 `stageAndInstall` 重载 |
| `Seal/Core/Installation/InstallChannel.swift` | 带进度 `install` 升级为协议要求 + 默认回退 |
| `Seal/Core/Signing/SigningSession.swift` | 新增 `installProgress` |
| `Seal/Features/Apps/AppsViewModel.swift` | 接 `onInstallProgress` → 更新 session |
| `Seal/Features/Apps/SigningProgressView.swift` | `.pushing` 显示进度条 + 百分比 |

---

## 8. 风险与回退

> 沿用 `REWRITE_ROADMAP` 原则：每项改动独立可用、可回退，与现有链路并存做双保险。

| 优化项 | 风险 | 回退策略 |
|---|---|---|
| P0 补 `enforceFreeAccountInstallLimit` | 计数维度/账号归属判断错误 → 误拦截 | 只读本机记录、纯前置拦截，失败放行（不阻塞签名）；先 UI 文案后收紧 |
| P1 分块传输 + 进度 | 改 Rust FFI 桥，session 不变量依赖广 | 保留现有整块 `stageAndInstall` 作兜底；分块路径异常自动回退 |
| P1 续签加速 / 批量并行 | 触发 Apple 限流、安装通道独占冲突 | 保持逐 app 串行兜底；并行默认关闭，仅按需开启 |
| P2 压缩级别 / 剥 armv7 | 高压缩增 CPU、剥错 slice 致闪退 | 逐包校验、失败自动用默认级别/原包重签 |

验证一律走 `REWRITE_ROADMAP` 回归样本（微信 / 黄豆短剧 / LCSign / lanmanga）
真机实测：可安装、续签覆盖安装且沙盒数据保留、断连自愈。

---

## 8A. 真机验证清单（四批改动统一待测）

> 本机（Windows）无法编译。以下 P0 / P1 / 续签间隔 / UI-数据一致性 四批改动均已代码就位，
> 需在 **Xcode 编译 RustBridge + 真机回归**后，才能把「已完成」改为「已落地验证」。
> 顺序：先编译打通，再逐项真机回归；逐项打勾并记录结果。

### 步骤 0 · 编译打通（先决）
- [ ] 打开工程，Xcode 编译 Swift + RustBridge（`cargo` 目标链），无编译错误
- [ ] 便于回退：确认三批改动均可通过 git 单独回放（每个改动独立可用）

### 项 1 · P0 免费账号 3 个安装上限拦截
- 目标：超限时**提前明确报错**，不再进传输转圈。
- 验收：
  - [ ] 免费 Apple ID，设备上已装 3 个自签应用（含 Seal），再签第 4 个 → 直接弹
        `SEAL-APPID-DEVICELIMIT` 及「先卸载一个 / 换 Apple ID」指引，**不进入传输阶段**
  - [ ] 续签既有 App 时自身不计入，不误拦（同一账号续签 3 个中的某个，正常放行）
  - [ ] 跨账号验证：不同免费 Apple ID 槽位独立，A 账号装 3 个不影响 B 账号继续签
  - [ ] 未达上限（<3）时不拦截，正常签名安装

### 项 2 · P1 分块流式传输 + 进度回读
- 目标：大包传输不黑洞，实时显示线性进度 + 百分比。
- 验收：
  - [ ] 微信（大包）签名后传输阶段，`SigningProgressView` `.pushing` 显示进度条 +
        `N%`，随传输推进
  - [ ] 进度一路上升到 100%，无跳变卡顿、无中途回退
  - [ ] 传输完成进入安装/校验，进度条结束，状态正常流转
  - [ ] 断连自愈：传输中断时重连恢复（沿用现有自动重试），不整包重推补偿到物流
  - [ ] 旧路径兜底：整块 `stageAndInstall` 通道在异常时仍可用（不分块路径不破坏）

### 项 3 · P1 续签提速（低风险档）
- 目标：批量续签 app 间固定缓冲由 1.5s 降至 0.75s，缩短连续序列总时长。
- 验收：
  - [ ] 批量续签（2+ 个应用连续刷新）正常跑完，互不干扰，无 503 限流触发
  - [ ] app 间间隔缩短后，Apple 服务器未限流、安装通道未独占冲突
  - [ ] Seal 自身 + 其他 app 续签覆盖安装成功，沙盒数据保留

### 项 4 · P2 插件续签日期实测复验（P0 编译后）
- 目标：核实续签后逐插件到期时间是否刷新。
- 验收：
  - [ ] 用 `AppDetailView` 逐插件到期页，记录插件 profile 到期日
  - [ ] 续签后再次查看，插件到期日更新为新到期（而非保留旧值）
  - [ ] 若未刷新再查 `provisioningProfiles` / `RorkAppSigner` 是否回写插件日期

### 项 5 · UI 与数据一致性 + 证书状态（2026-09-08 增补）
- 改动：扩展折叠入口、Bundle ID/插件单行省略、已签名 App 页扩展时间同步、证书失效误判修复。
- 涉及文件：`AppDetailView.swift` / `SigningProgressView.swift` / `AppleAccountDetailView.swift` / `CertificateHealthStatus.swift`。
- 验收：
  - [ ] 已安装详情：扩展区显示「扩展 N 个 + chevron」，点击展开逐插件到期时间，再点收起
  - [ ] 签名失败页：Bundle ID 单行展示（缩小字号/中间省略 `.seal.TeamID` 后缀仍在），不换行溢出
  - [ ] 详情页「插件·xxxx」单行，长插件名缩小/尾部省略，不挤压到期时间列
  - [ ] 续签后「应用详情」与「Apple ID 已签名 App」两处插件到期日一致（均为新值）
  - [ ] 证书详情页：Apple 侧同步失败/网络不可达时，本机证书与私钥完好者显示「可用」而非「失效」；
        仅当 Apple 明确判定证书不存在/已过期、或本机私钥缺失时才显示「失效」
  - [ ] 重登 Apple ID 后（`persistAuthenticatedAccount` 保留 p12/serial）：可正常签名；若签名失败导出日志定位
        `SEAL-*NET*`（网络）还是 `SEAL-CERT-*`（本机私钥丢失，会自动重签新证书）

### 回归样本统一
- [ ] 微信 / 黄豆短剧 / LCSign / lanmanga 均：可签名安装、续签覆盖安装且沙盒数据保留、断连自愈
- [ ] 导出日志脱敏：无 keychain 凭据、Apple ID 明文

> 全部打勾后，回写 §4 对应条目状态为「已落地验证」，并同步项目 memory。

---

## 9. 执行纪律（Seal 工作纪律全清单）

> 用户要求（2026-09-08）：**每次决定干一件事，先反问自己再动手。**
> 已同步到项目 memory（跨会话生效）。以下 A–D 四组为 Seal 建议遵守的完整工作纪律。

### A. 动手前 · 5 步自查（用户要求）
1. **做完结果会怎么样** —— 预期产出/行为变化明确，有可验收结果。
2. **有没有遗漏** —— 边界、关联路径、未覆盖分支都想全。
3. **会不会导致其他出错** —— 不牵动无关模块、不破坏签名/安装/续签既有链路；明确回退/兜底。
4. **规不规范** —— 与项目风格、`REWRITE_ROADMAP` 原则、Apple 官方规范一致。
5. **上游是否有一样的代码** —— 先对齐上游 Seal/AltStore/SideStore/jas/zsign 的等价实现，复用而非自造。

### B. 动手时 · 代码规范
6. **绿色基线** —— 任何离开工作区的改动都必须能编译通过；绝不留下「调用了未定义函数/字段」的中间态
   （`enforceFreeAccountInstallLimit` 已于 2026-09-08 补齐，见 §4-P0-1）。
7. **最小改动** —— 只改目标所需，拒绝顺手重构无关代码；对齐 `REWRITE_ROADMAP`
   「删除为主、零新增 Rust 逻辑」与「可回退双保险」原则。
8. **根因不绕绕** —— 从真机日志定位根因再改，不走绕过（如 `--no-verify`）；
   延续日志「真机日志闭环」：现象 → 根因 → 修复 → 回归 一条链。
9. **大包内存纪律** —— 500MB+ 只流式处理（`unzipItem` 等），禁止整块载入内存，防 `DataError`/崩溃。
10. **错误码规范** —— 新失败一律走 `ImportFailure(title/reason/recovery/code)`，code 遵循现有
    `SEAL-<模块>-<类别><序号>` 体系（`SEAL-INSTALL-/PAIR-/SIGN-/AUTH-/CERT-/RENEW-/APPID-`），唯一且带可恢复引导。
11. **跨层约束** —— Swift ↔ Rust(Bridge) 的签名/安装改动，先确认「上传与安装须同一缓存隧道会话」这一
    核心不变量不被破坏（否则复现 MissingPackagePath）。

### C. 验证时
12. **真机优先** —— 涉及安装/web/installd 的改动必须走回归样本（微信 / 黄豆短剧 / LCSign / lanmanga）
    真机验证；单测/编译通过 ≠ 可用。
13. **完成前自证** —— 不声称「已修复/已完成」，直到有验证证据。
14. **日志脱敏** —— 导出/上报日志不携带 keychain 凭据、Apple ID 明文等敏感信息（沿用现有「脱敏日志」）。

### D. 决策与同步
15. **重大取舍落记录** —— 下线/更换链路、换签名器等决策记入 `REWRITE_ROADMAP`（问题/根因/状态三列风格），不丢上下文。
16. **文档随代码更新** —— `REWRITE_ROADMAP` / `OPTIMIZATION_PLAN` / 项目 memory 与代码同步，避免决策失忆。
17. **限并发** —— 并行子代理（Explore 等）单轮 ≤ 3，防止环境与上下文失控。

> 每项优化落地时，把自查结论写回 §4 / §5 对应条目的「实现注意 / 风险与回退」。