# 上游对齐（Seal 是二开，必须跟上游）

- 建立：2026-09-19
- 依据：`AGENTS.md` 第 1 节「改动前自查清单」**第 5 条** ——
  「上游是否已有 —— Seal/AltStore/SideStore/jas/zsign 已有等价实现则**优先对齐/复用**，不自造轮子」
- 起因：用户指出「**seal 就是二开上游的，当然需要上游已经实现的方法**」✓

---

## 一、上游是谁（用户 2026-09-19 明确）

**上游 = AltStore + SideStore** ✓

两者的关系：**SideStore 是 AltStore 的 fork**，官方描述是
> *"SideStore is a fork of AltStore that doesn't require an AltServer."*（AGPL-3.0，6.5k stars）

**⇒ 这句话和 Seal 的定位一字不差** ✓（设备内签名 + LocalDevVPN，不需要电脑）
⇒ **SideStore 是更近的上游**，它的做法比 AltStore 更有参考价值 ✓

### 补充：另外两类「上游」

| 上游 | 关系 | 处置 |
|---|---|---|
| **`rorkai/rork-sign`** | **内置源码**（`Vendor/rork-sign/`，Apache-2.0） | 同步时要**保住 Seal 的补丁** ✓（见第三节） |
| **`rileytestut/AltSign`** | **SwiftPM 依赖**（`ALTAppleAPI` / `ALTTeam` / `ALTCertificate`） | 跟版本号 + 对照**用法** ✓ |

---

## 二、为什么不能靠 `git merge upstream`

Seal 的 git 历史**被重建过** ✗：全部 659 个提交都是同一个作者（`Seal Developer`），
**历史里没有上游的任何提交** ⇒ 与上游**没有共同祖先** ⇒ `git merge` / `git rebase` **不可用** ✗。

⇒ **只能做「语义对照」**：把上游的关键文件拉下来读，
对照的是**做法**而不是文本（语言/结构/框架都不同，文本 diff 没有意义 ✗）。

---

## 三、~~`Vendor/rork-sign/` 的补丁清单~~ 🔴 **已作废**（2026-09-19）

> 🔴 **`Vendor/rork-sign` 整个目录已删除** ✗ —— 签名器换成了上游 **`SideSign` + `CodeSignKit`** ✓
> （用户死命令：「**一个代码不漏地给我抄 不要打补丁 签名器不一样你就换啊**」✓）。
> ⇒ **下面这一节只作历史记录** ✓，**不要再照它去改代码** ✗（那些文件已经不在仓库里了）。
> ⇒ 现在生效的是**第九节**（换签名器之后的对齐台账 ✓）。

> **这是本仓唯一能真正做到「一字一码」的地方** ✓ ——
> `Vendor/rork-sign` 就是 `rorkai/rork-sign` **0.6.5** 的副本 + **4 个文件**的补丁 ✓
> （`upstream/rork-sign` 已按 0.6.5 拿进来；完整 diff 见
> [`docs/upstream/rork-sign-0.6.5-vs-Vendor.diff`](./upstream/rork-sign-0.6.5-vs-Vendor.diff) ✓）
>
> ⚠️ **对比时必须加 `--strip-trailing-cr`** ✗ —— 两边换行符不同，
> 不加会把整个文件算成差异（实测：2949 行 → 实际 15 行 ✓）。

| 文件 | 改动 | 性质 | 守卫 |
|---|---|---|---|
| `MachO/MachOSigner.swift` | 125+ / 13- | **Seal 补丁**：`clearFairPlayCryptid`（修**启动崩溃**）+ `adjustedCodeLimit`/symtab（处理「已签名二进制再签」）| **R52** ✓ |
| `Bundle/AppBundleSigner.swift` | 13+ / 2- | mmap（`readEntitlementsXML` 不再整块读 ✗） | R50 ✓ |
| `Bundle/BundleSigner.swift` | 26+ / 7- | mmap（3 处） | R50 ✓ |
| `Bundle/BundleSignatureCache.swift` | 4+ / 2- | mmap（缓存条目） | R50 ✓ |

**⇒ 同步上游时这 4 个文件的补丁必须逐条保住** ✓

Seal 改过它 ✗ —— 每次同步上游前先确认这些补丁仍在（守卫已钉 ✓）：

| 补丁 | 守卫 |
|---|---|
| 判 Mach-O 时**不许整块读入**（`.mappedIfSafe`） | R37 / R49 |
| 读可执行文件用 mmap（`readEntitlementsXML` 两条链路 + 签名主路径 + host 校验 + 缓存条目） | R50 |
| 签名缓存必须真的传进去 | R38 |

---

## 三点五、依赖层的上游（`project.yml` 指向的用户 fork，均为**未改动镜像** ✓）

| Seal 的依赖 | 用户 fork | **真正的上游** | 版本 |
|---|---|---|---|
| `AltSign`（`project.yml:17`） | `sunuannian1/AltSign` | **`SideStore/AltSign`** | `35b68f1a…`（2026-08-26） |
| `AnisetteKit`（`project.yml:20`） | `sunuannian1/AnisetteKit` | **`mahee96/AnisetteKit`** | `db8b4102…`（2026-09-18） |

### 🔴 `AnisetteKit` 的接口契约（2026-09-19 实测）

```swift
public protocol AnisetteDataProvider: Sendable {
    func getAnisetteHeaders(libDir:provisioningDir:identifier:adiPb:) throws -> AnisetteDataResponse
}
```

**⇒ 「调一次产生一份新 headers」，库里没有任何会话/缓存概念** ✓
⇒ **⇒ 把 anisette 存进会话复用**就是**调用方的错** ✗（1100 根因最硬的证据 ✓）。

⚠️ **注意**：Seal 的 `Seal/Infrastructure/Accounts/AnisetteClient.swift` 与
`AnisetteDataProvider.swift` **与上游同名但角色不同** ✗ ——
Seal 的是**自己的 wrapper**（`struct AnisetteV3Client: AnisetteEnvironmentManaging`），
上游的是**库本身** ⇒ **同名不代表同角色，别按名字配对** ✓。

---

## 四、对照台账（**改签名/续签链路前先查这里**）

> 规矩：**对照过就记一条** —— 免得同一个问题重复查 ✓。
> 结论分两种：**「跟」（上游更对 ✓）** 与 **「不跟」（Seal 已更好 / 上游没有 ✓）**。

| 日期 | 对照对象 | Seal 侧 | 上游做法 | 结论 |
|---|---|---|---|---|
| 2026-09-19 | **anisette 的取用时机** | `signOnce` 取一次、用一整轮 ✗ | AltStore `AppManager`：本地打补丁**之后**、第一个 Apple 请求**之前**刷新，并**显式声明依赖** | **跟** ✓ → 已修（`921fa4e`）；因 Seal 的 Apple 窗口更长（9 个 App ID × 2 次写 ✗），**加了更多刷新点**（`83084d0`） |
| 2026-09-19 | **证书轮换的撤销判据** | **必须 `sealSignerConfirmed`** ✓ + 撤销后**立刻持久化、立刻重建、成功即停** ✓ | AltStore 只看 `machineName` 前缀是否 `"AltStore"` | **不跟** ✓ —— Seal 的判据更严、顺序更谨慎 |
| **2026-09-19** | 🔴 **免费账号只有「一张」活动证书（Apple 硬限制）** | `CertificateTakeoverPolicy.swift:28` 已记录：「免费团队只有一个『活动 iOS 开发证书』槽位（Apple 硬限制，非两个）」✓ | SideStore `CertificateProvisioningFlow` 同样是「先创建、失败才撤销」—— **在免费账号上「先创建」必然 3022** ✗ | **关键约束，必须记住** ✓：<br>① **只有 1 张 ⇒「先创建」在免费账号上必然失败** ✗ ⇒ **必须先撤销** ✓；<br>② ⇒ **「撤销 → 创建」的窗口无法消除** ✗（腾槽位才能建 ✓）；<br>③ ⇒ 能做的只有：**撤销后立刻创建** ✓ + **失败给清晰说明** ✓ + **撤销前确保会话新鲜**（anisette ✓）；<br>④ ⇒ 本轮的 anisette 修复**顺带**降低了这个风险 ✓（会话过期是创建失败的主因之一 ✓） |
| **2026-09-19** | **证书的整体策略（顺序 / 谁来撤）** | **先撤销旧证书、再创建** ✗ —— 撤销成功但创建失败 ⇒ **账号变 0 张证书** ⇒ 用它签过的 App 全部打不开 ✗✗ | **SideStore `CertificateProvisioningFlow`**：<br>① 先找活跃证书/embedded 复用 ✓<br>② 否则**先尝试创建** ✓<br>③ 创建失败才进 `replaceCertificate`：候选 = `name` 含 `ios development`/`iphone developer` ✓；**弹窗让用户选** `keepExisting`（不撤，直接再试 ✓）/ `revokeSelected` ✓<br>⇒ **「先创建」⇒ 不存在「撤了没建成」的窗口** ✓✓ | **跟** ✓ —— 按用户指示「**Seal 比 SideStore 严格就去除，按 SideStore 来**」<br>⇒ 改成「**先创建；失败才处理撤销，且由用户选**」<br>⇒ **顺带消灭「0 张证书」这个灾难** ✓✓<br>**已实施 `ff718d9`** ✓（**自动撤销能力保留** ✓ —— 撞 3022 后仍自动撤销 + 重建）<br>⚠️ 那条既有守卫的文案本就写着 **`or`**（「rotate before a free-team request **or** after exact 3022」），实现却写成 `and` ✗ ⇒ 按意图更新 ✓ |
| **2026-09-19** | **扩展的 App ID 准备顺序** | 主 App **排最前** ✓（`ApplePortalAppIDResolver.preparationOrder`）；扩展**串行**、且每请求**节流 0.4 秒**（`AppleRequestThrottle`）✗ | SideStore `FetchProvisioningProfilesOperation`：<br>① **主 App 先准备** ✓（`provisionAndFetchProfile(for: targetAppBundle, parentAppBundle: nil)`，在扩展之前）<br>② 扩展用 **`withThrowingTaskGroup` 并发** ✓<br>③ **没有节流** ✓<br>（`PrepareAppExtensionBundleIDsOperation` 只做「扩展 BundleID 跟着主 profile 改写」✓，不涉及注册顺序） | **一半一致、一半待定**：<br>① **主 App 先 = 上游一致** ✓ ⇒ **不用改** ✓；<br>② **串行 + 节流 vs 并发无节流** ✗ ⇒ **待定** —— 节流是为「1100 短时频率限制」加的 ✓，<br>但**本轮的 anisette 修复可能才是 1100 的真因** ✗（gap 前成功 / gap 后失败的时间线支持这点 ✓）<br>⇒ **建议先跑一次带 anisette 修复的构建**：若不再 1100 ⇒ 再考虑去掉节流、改成并发 ✓<br>（并发还能**缩短 Apple 窗口** ⇒ 对 anisette 寿命有利 ✓✓） |
| **2026-09-19** | **证书「有效性」的判据** | **本机有私钥 + 剩余有效期 > 7 天** ✓（`SigningCertificateMaterialPolicy` / `CertificateTakeoverPolicy`） | SideStore `VerifyCertificateOperation`：先看证书在不在 **portal 列表**里 ✓，不在才退到 **OCSP** 校验 ✓ | **保留 Seal 的判据** ✓ —— 两者**目的不同**：SideStore 问「这张证书还有效吗」（可否**继续用**）✓；Seal 问「这张证书够不够签**满 7 天**」✓<br>⚠️ **7 天那条不是「多余的严格」** ✗ —— 只判「当下未过期」会把**次日到期**的证书签进新包 ⇒ iOS 判「尚未验证」**闪退** ✗（`AGENTS.md` 第 3 节有记载 ✓）<br>⇒ 按判据属于「**更完整/防缺陷**」⇒ **保留** ✓（不是「更严格」✗）|
| **2026-09-19** | **描述文件批量安装** | **不逐个装 profile** ✗ —— 走 `installPushedIpa` / `install(ipaData:)`（**profile 随 IPA 一起进设备** ✓） | SideStore 的 `InjectBatchProfilesOperation` + `addPendingProfileBatch` **只在 `isCellularRefreshGroup` 时触发** ✗ —— 那是**蜂窝网络下批量续签**的场景，目的是**少切几次数据网络**（`turnOffDataIfNeeded` ✓） | **不用跟** ✓ —— **Seal 里没有「蜂窝」这个概念** ✓（grep 为空 ✓），也没有对应场景；而且两边装 profile 的路径本来就不同（Seal 随 IPA 装 ✓） |
| **2026-09-19** | **会话过期（1100）的重试与退避** | `withSessionRecovery`：退避重试 + 重建会话 ✓ | **两个上游都完全不处理** ✗ —— `AltSign` 里没有 1100/retry/backoff/sessionExpired 任何一处 ✓；`SideStore` 里唯一的 "1100" 是个**端口号** ✓ | **保留** ✓ —— **上游「没有」≠「更好」** ✗：上游把会话过期完全交给**用户手动重试** ✗，而 Seal 自动恢复是**必要的健壮性** ✓（今天的 1100 就是证据 ✓） |
| **2026-09-19** | 🔴 **签大包的内存峰值** | **整块读 + 原地改（COW 复制）⇒ 峰值 2×** ✗<br>真机 `JetsamEvent`：Seal `rpages 129697 × 16KB = **2.11 GB**` ⇒ 被杀 ✓ | **`CodeSignKit`（SideStore 用的签名器）**：<br>① `MachOParser.swift:154,157` **`Data(contentsOf:…, options: .mappedIfSafe)`**（mmap 读，0 内存 ✓）<br>② `MachOSigner.swift:301` **`workingData.subdata(in: 0..<codeLimit)`**（复制出新 Data 再改，1× ✓）<br>⇒ **全程只有 1 份** ✓<br>⚠️ **上游也没有流式** ✗（`InputStream`/`FileHandle(forWriting` 全空 ✓）⇒ 说明 **1× 就够** ✓ | **跟** ✓ 已实施 `db2463a` —— 把 `BundleSigner` 的 `input` 与 `var executable` 改成 mmap 读 ✓ |
| **2026-09-19** | 🔴🔴 **mmap 的统一判据**（今天所有纠结的答案 ✓） | — | — | **不是「哪里该用 mmap」，而是「这份 Data 会不会被原地写」** ✓<br>· **只读 ⇒ mmap 安全** ✓（签名器 input/executable ✓ / `readEntitlementsXML` ✓ / `inspectMachO` ✓ / 缓存条目 ✓）<br>· **原地写 ⇒ 必须整块读** ✓（`SigningWorkspace.rewriteExecutablePathReferences` ✓ —— R49 钉住 ✓）<br>⚠️ 违反它的后果：**SIGBUS 崩溃** ✗（构建 160 ✓） |
| **2026-09-19** | **`ALTAppleAPISession` 与 anisette 的关系** | 认证时建会话，之后**替换/重建**它来更新 anisette ✓ | `AltSign` 的 `authenticate(... anisetteData: ALTAnisetteData ...)` 把 anisette 当**入参** ✓；`ALTAppleAPISession(dsid:authToken:anisetteData:xcodeVersion:)` 在**认证那一刻**建会话 ✓ ⇒ **库不管 anisette 的生命周期** ✗ | **已跟** ✓ —— `anisetteData` 只是会话的**一个字段**，调用方必须在**每次 Apple 工作前**替换它 ✓（AltStore 的做法：`session?.anisetteData = anisetteData` ✓）|

| **2026-09-19** | 🔴🔴 **整个签名器（内核 ＋ 重签层）** | `Vendor/rork-sign` ＋ Seal 自写的 `RorkAppSigner` ✗ | **`SideSign` → `CodeSignKit`**（SideStore 在手机上签大包用的就是它 ✓） | **跟** ✓ —— 用户死命令「**签名器不一样你就换啊**」⇒ 整个换掉 ✓（详见**第九节** ✓）<br>⚠️ 代价：签名缓存 ✗、逐 bundle 诊断 ✗、FairPlay 补丁 ✗（**三个已知风险** ✓） |
| **2026-09-20/21** | 🔴 **配对助手该生成「哪种」配对文件** | 覆盖层把上游的「配对类型」单选**删掉了** ✗ ⇒ 只剩硬编码默认值 `PairingMode::RemotePairing` ⇒ **iOS 17.0–17.3.1 的设备必然生成失败** ✗，且界面不说原因 ✗ | `idevice_pair` **README（固定版 0.1.14 也一样）**：*"RPPairing for **iOS 17.4+**, Lockdown for older verions"*；上游界面用 `radio_value` **让用户自己选** ✓ | **跟** ✓ —— 判据照上游，但按 Seal 的极简 UI **不做单选**，按设备版本自动选：**< 17.4 ⇒ Lockdown** / **≥ 17.4 ⇒ RemotePairing**。版本未知时禁用生成，不能把不确定设备送进远程配对。另补齐 Lockdown 端到端前提：导入必须含完整 pair-verify 身份；启动前重定向 usbmuxd；安装/续签走 AFC + installation_proxy，不能误走 RSD 合并入口。<br>**根因**：iOS **17.4 才引入 `CoreDeviceProxy`** ✓（上游 README ＋ pymobiledevice3 文档双向印证 ✓）⇒ 17.0–17.3.1 在 USB 上引导不了远程配对 ✗ |

| **2026-09-21** | 🔴 **Lockdown 配对文件的字段（助手生成 ↔ Seal 校验）** | 新增完整性校验 `PairingStore.isCompleteLockdownPairing`：要求 **7 个键** —— `UDID`/`HostID`/`SystemBUID` 为 `String`，`HostCertificate`/`HostPrivateKey`/`RootCertificate`/`RootPrivateKey` 为 `Data` ✓ | 生成侧 = `idevice_pair` @ `e3abb34` → **`idevice` crate 0.1.61**：`PairingFile::serialize()` → `RawPairingFile`，键名由 **`#[serde(rename_all = "PascalCase")]` 派生**（`SystemBUID`/`HostID`/`UDID`/`WiFiMACAddress` 另用显式 `rename`）；四份证书/私钥声明为 plist **`Data`** ✓。与 `Vendor/DeviceSupport/libimobiledevice`（`userpref.h` 的 `USERPREF_*_KEY` ＋ `lockdown.c` 的 `plist_new_data`）标准 pair record 一致 ✓ | **一致 ⇒ 不用改** ✓ —— 键名**逐字相同**、类型匹配（3 String ＋ 4 Data）、`UDID` 由助手显式赋 `Some(dev.udid)` 不会缺 ✓ ⇒ **导入校验不会误拒**。<br>⚠️ **查法教训**：直接 `grep HostCertificate` 在上游源码里**命中为 0** ✗ —— 键名是 serde 从字段名派生的，不是字面量。**「grep 不到」≠「不存在」**，要读 serde 属性才对 ✓（同族：Seal 自己的中文文案常写成 `\u{...}`，grep 中文同样会零命中 ✓） |

| **2026-09-21** | 🔴🔴 **`SC_Info` / sinf 清理（DRM 包装不上）** | `SigningWorkspace.removeMissingAppExtensionReferences`（:540）：找 **`SinfOptions` / `SinfIDs`** 两个键 ✗，判据是 **`PlugIns/<扩展名>` 是否存在** ✗ | **AltStore `ResignAppOperation:279` 与 SideStore `ResignAppOperation:205` 逐字相同**：只处理 **`SinfReplicationPaths`**（`[String]`），判据是 **`URL(string: path, relativeTo: bundleURL)` 解析后文件是否存在** ✓ —— 绝对路径 / `../` 越界 ⇒ 解析后落在 bundle 外 ⇒ 自动被删 ✓；SideStore `RemoveAppExtensionsOperation:146` 另按 `PlugIns/` 前缀过滤；`rork-sign` 则把 `SC_Info` **排除**出签名计算 | **跟（但不够）** ✓ —— Seal 的键名与判据**双双偏离上游** ⇒ 代码在真机上**从未生效**（`manifest["SinfOptions"] as? [String: Any]` 恒 nil ⇒ `changed` 恒 false ⇒ 一字节不写）✗；真机错误 `ApplicationSINFCaptureFailed (Root sinf URL points outside of bundle)` 正是它本应处理的那种形态 ✗<br>🔴 **照抄上游也不够**：上游**从不碰 `SinfPaths`**（真实 `Manifest.plist` 的另一个顶层键，登记 root sinf 本身），而错误说的就是 "**Root** sinf" ⇒ 修复必须**额外处理 `SinfPaths`** ✓<br>⚠️ **查法教训**：**真实样本 > 上游源码** —— 键名是猜不出来的。取证靠「设备 dump 的真实 `Manifest.plist`」（顶层只有 `SinfPaths` / `SinfReplicationPaths` 两个键，实测 `SinfOptions`/`SinfIDs` **不存在**）+ 全仓 grep（`SinfOptions\|SinfIDs` 只命中 Seal 自己 6 行，三家上游零命中）✓<br>✅ **2026-09-21 真机验证通过**（**构建 193**，iOS 17.0–17.3.1 设备）：同一个「源阅读」IPA **装得上、点开也能正常打开** ⇒ 本修复生效，「有图标点不开」症状消失 ✓（该包**未被** `SEAL-IPA-107` 拦下 ⇒ 顺带证明它是已砸壳的）<br>📄 完整分析见仓库外 `Seal-日志分析-源阅读安装失败.md` |

> **⚠️ 分清两种「Seal 多出来的东西」**（用户 2026-09-19 指示「比 SideStore 严格就去除」时）：
>
> | 类型 | 例子 | 处置 |
> |---|---|---|
> | **更严格**（额外的**限制/保守** ✗） | 白撤证书 / 过度节流 | **去掉** ✓ |
> | **更完整**（额外的**健壮性/恢复** ✓） | `withSessionRecovery` / 守卫 | **保留** ✓ |
>
> **上游「没有」不等于「更好」** ✗ —— 今天的 1100 恰恰证明：上游不处理它，Seal 必须自己处理 ✓。

---

## 五、SideStore 流水线的对照入口（27 个操作，按相关度排序）

SideStore 的签名/刷新是一条**显式流水线** ✓（`SideStore/Core/Operations/PipelineOperations/`）：

| 与 Seal 的哪个问题相关 | SideStore 的操作 |
|---|---|
| **证书轮换**（「0 张证书」风险区） | `UpdateAppCertificateOperation` / `VerifyCertificateOperation` / `CacheSigningCertOperation` / `EmbedSigningCertOperation` |
| **扩展的 App ID**（Seal 写死顺序 ✗） | `PrepareAppExtensionBundleIDsOperation` / `RemoveAppExtensionsOperation` |
| **Apple 请求窗口**（anisette 寿命） | `FetchProvisioningProfilesOperation` |
| **安装 / 上传** | `StageAppOperation` / `SendAppOperation` / `InstallAppOperation` / `CleanStagedAppOperation` |
| **自定义名称 / 图标** | `UserCustomizationOperation` / `ChangeAppIconOperation` |
| **前置检查** | `PreflightChecksOperation` |

另外 SideStore 把 anisette 单独做成一个模块 ✓：
`SideStore/Core/Anisette/{AnisetteProvider, OnDeviceAnisetteManager, AnisetteServersManager}.swift`
（Seal 对应 `AnisetteClient` / `AnisetteServerStore` ✓ —— 命名都几乎一样 ✓）

---

## 六、怎么执行（每次改签名/续签链路之前）

1. **查台账**（第四节）：有相关条目 ⇒ 直接用结论 ✓；
2. **没查过** ⇒ 用下面第七节的命令把上游对应文件拉下来读；
3. **读完写台账** ✓（一行：日期 / 对象 / 两边做法 / 跟或不跟 ✓）；
4. **如果「跟」** ⇒ 按 Seal 的结构改造（**不是照抄** —— 语言与结构不同 ✓）；
5. **跑守卫** ✓（守卫是「本仓已踩过的坑」的沉淀 ✓）。

---

## 七、拉取上游文件（`gh` 已登录）

```bash
# AltStore
gh api "repos/altstoreio/AltStore/contents/<路径>" --jq '.content' | base64 -d

# SideStore
gh api "repos/SideStore/SideStore/contents/<路径>" --jq '.content' | base64 -d
```

落盘建议放 `build/upstream/`（`build/` 不进版本库 ✓）。

---

## 八、不要对齐的部分（Seal 独有，别去「跟」）

- 免费账号 **App ID 名额**与主 App/扩展的**准备顺序**策略；
- **设备端描述文件回收**（含「扩展随父保留」的判定）；
- 「**两张表同源**」「**同一规则只落一条链路**」这类本仓历史坑的守卫；
- 自替换 / 续签事务（`SelfReplacementTransaction`）；
- 本地准备的**分段时间日志**（解压 / 改写 / 瘦身 / 归一化 —— 为 CPU 预算服务 ✓）。

---

## 九、🔴 **签名器已换成上游**（2026-09-19，用户死命令）

> 原话：「**一个代码不漏地给我抄 不要打补丁 签名器不一样你就换啊 这个签名不是签不了大包吗**」
> ＋「**禁止乱发明**」＋「**照抄吧**」。
> 方案 **B**：**只抄 SideSign 的签名能力**，不带它的 anisette / 门户 ✓。

### 9.1 换之前 → 换之后

| | 换之前 | 换之后 |
|---|---|---|
| 签名内核 | `Vendor/rork-sign`（`rorkai/rork-sign` 0.6.5 ＋ **4 个文件**的 Seal 补丁 ✗） | **`Vendor/CodeSignKit`**（`mahee96/CodeSignKit`，**原样 vendor** ✓） |
| 重签层 | `Seal/Infrastructure/Signing/RorkAppSigner.swift`（Seal 自写 ✗） | **`Vendor/SideSign`**（`mahee96/SideSign` ✓）＋ 薄适配 `SideSignAppSigner.swift` ✓ |
| 内存策略 | 整块读 ＋ 原地改 ⇒ 峰值 **2.11 GB** ⇒ jetsam 批量杀后台 ✗ | **mmap 读 ＋ `subdata` 复制后改 ⇒ 全程 1 份** ✓（**R57** 钉住 ✓） |
| 签名缓存 | `SigningCacheOptions`（`rork-sign` **独有** ✓） | **没有** ✗ ⇒ 每次**全量重签**（`SigningCacheStats` 恒 `(0,0)` ✓） |
| 逐 bundle 诊断 | `AppSigningOptions.diagnostics` ✓ | **没有** ✗（上游 `verboseLog` 走 `print` ⇒ **进不了导出日志** ✗） |
| FairPlay cryptid 清零 | 有补丁 ✓ | **没有** ✗ ⇒ **可能「装完启动崩」** ✗✗（**最高风险** ✓） |
| 签名身份读取 | `RorkSigner.checkMachOCodeSignatures`（**整块读** ✗） | `CodeSignKit.MachOParser`（**mmap** ✓）—— **R55** 钉住 ✓ |

### 9.2 为什么「整个仓库拿来」

用户指示「**直接整个仓库拿来，不允许你有什么什么太大、什么什么太多的想法**」✓
⇒ 上游仓库已放进 `upstream/`（7 个：`AltSign` / `AltStore` / `AnisetteKit` /
`CodeSignKit` / `SideSign` / `SideStore` / `rork-sign` ✓），
实际参与编译的是 `Vendor/` 下的**副本** ✓（`project.yml` 用 `path:` 引用 ✓）。

### 9.3 `Vendor/SideSign` 的删减（方案 B）

| 删掉 | 为什么 |
|---|---|
| `Sources/Anisette/`、`Sources/DeveloperPortal/` | Seal 用自己的 anisette（`AnisetteClient`）＋ `AltAppleAPI` ✓ |
| `Models/{AnisetteData,Session,AuthSession,AuthDevice,CertificateRequest,CertificateType,DeveloperPortalResponses,AppID,AppGroup,ProfileType}.swift` | 属于上面两层 ✓ |
| `Compatibility.swift`、`Constants.swift` 的 `Anisette` 段 | 同上 ✓ |
| `Logging.swift` 的 `import AnisetteKit` ＋ `AnisetteKitLogging.setLogging` | 同上 ✓（⚠️ 注释里两个标识符曾被 `python -c` 的**反引号**掏空 ✗，2026-09-19 已修 ✓） |
| `CLI/` ＋ `Package.swift` 的 `sidesign` 产品与 `executableTarget` | 整段建立在已删的门户层上 ⇒ **根本编译不过** ✗ |
| `Tests/SideSignTests` 里 2 个用例（CSR / DeveloperPortal） | 同上 ✓（其余 3 个：`Device` 模型 ＋ 两个 `Archive` 往返 ⇒ **保留** ✓） |

### 9.4 `Vendor/CodeSignKit` 的改动（**只有 Package.swift** ✓）

其余**逐字节原样** ✓（`diff -r -w` 核实 ✓）。`Package.swift` 只改了一处：
`swift-crypto` 由 `4.3.1` → **`4.5.2`** ✓ —— 不改会与根包冲突，CI 实报
「gsacryptokit depends on swift-crypto 4.3.1 and root depends on 4.5.2」✗。

### 9.5 🔴 换签名器带来的三个已知风险 → ✅ **真机已验证**（2026-09-20，构建 175）

> 真机日志 `Seal-log(28).txt`，**定版 `构建 1.1.16 (175)`** ✓

1. ✅ **装完能不能启动** —— **两个 App 都能打开**（LiveContainer 4.8 MB ＋ 抖音 657.6 MB）
   ⇒ **FairPlay `cryptid` 这条风险排除** ✓
   （上游 `CodeSignKit/MachOParser.swift:555` 仍只有「读」没有「清零」✓，
     但实测**不影响启动** ✓；若将来出现「装完点开就闪退」，原型补丁见历史提交 `b548021` ✓）；
2. ✅ **大包会不会被 CPU 预算杀掉** —— **没被杀** ✓：抖音（657.6 MB ＋ 9 bundle）全程走完
   —— 本地准备 44 秒（解压 7 ＋ 归一化 37）＋ **重签 78 秒** ＋ 打包 43 秒 ＋ 安装 121.6 秒 ✓
   （对比构建 147：签抖音 90 秒 CPU / 166 秒 ⇒ 撞「180 秒内 50%」上限被系统杀掉 ✗）；
3. 🟡 **日志里还能不能看出「死在哪个 bundle」** —— ⚠️ **仍是已知的能力退化** ✓
   （上游 `verboseLog` 走 `print` ⇒ 进不了 Seal 的导出日志 ✗；本次没崩所以没暴露 ✓）。

**⚠️ 真机暴露的另一处（与签名器无关）**：描述文件回收多轮 `回收中止：阳性对照未通过` ✗
> 🔴 **更正（2026-09-20）**：阳性对照用的是 `Bundle.main.bundleIdentifier`
>（**当前正在运行的 Seal 自己** ✓）⇒ **选得对** ✓；早先写的「挑错了对象」是**错的** ✗。
> **真实规律**：两次中止都在**刚启动**（冷启动后 22 秒 / 自替换重启后 60 秒），
> 同行都带 `dump 尝试 N 次`，16 秒后再跑就正常 ✓
> ⇒ 强烈指向「**启动早期安装通道还没就绪**」✓ —— fail closed **正确** ✓（**保护，不是回归** ✓）。
> ⚠️ 根因未最终确认（`unavailable` 把**超时**与**抛错**折叠成一个值 ✗）
> ⇒ 已补诊断（守卫 **R58**：探测带**耗时** ＋ **再问同一个 ID 一次**）⇒ 下份日志即可定性 ✓。

