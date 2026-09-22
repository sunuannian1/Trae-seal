# AGENTS.md — Seal 项目工作纪律与约束

> 本文件是跨工具、跨会话的项目规则（含换账号后继续工作的约定）。所有改动请先读这里；
> 「改动前自查清单」是硬门槛。
> 复盘台账（现象→根因→修复→涉及文件→验证状态）在 `DEBUG_LOG.md`，按日期倒序；
> 每次修 bug 或发现常犯坑位必须追加一条。`RELEASE_NOTES.md` 是每次发布的正文来源。
>
> 本文件取代原 `CODE_AUDIT_20260915.md`（其内容已并入 `DEBUG_LOG.md` 与 `docs/qa/`）。
> 文中所有「文件:行号」是写稿时的核对点，代码会变 —— 冲突时以代码为准，并回来更新本文件。

## 0. 项目本质

以**签名 / 安装 / 续签**三条链路为焦点（自签 iOS 应用工具 Seal）。改动常跨 Swift + Rust(Bridge) 两层，
Windows 本机**无法编译**，一切以云 CI 编译 + 真机回归为准。

## 1. 改动前必过自查清单（硬性，5 项缺一不可）

1. **做完结果会怎么样** —— 明确可验收的产出/行为变化。
2. **有没有遗漏** —— 边界、关联路径、未覆盖分支。
3. **会不会导致其他出错** —— 签名/续签/安装三环节尤其防互相牵连；回退/兜底是什么。
   - 🔴 若这次要动的是「**问设备 → 按答案删本地数据**」的路径，
     先读 §4 的「**用设备查询结果决定「删不删」的路径（通用硬规则）**」——
     本仓已因此**两次**静默删数据，那**五件套是必抄的**，别自己设计。
4. **规不规范** —— 与项目既有风格、Apple 官方规范一致。
5. **上游是否已有** —— Seal/AltStore/SideStore/jas/zsign 已有等价实现则优先对齐/复用，不自造轮子。
   🔴 **改签名 / 续签链路之前，必须先查 [`docs/upstream-alignment.md`](docs/upstream-alignment.md)** ✓
   —— 那里有**上游清单**、**对照台账**（对照过什么、结论、日期）和**拉取命令**。
   - **上游 = AltStore + SideStore**。SideStore 是 AltStore 的 fork，官方描述
     *"doesn't require an AltServer"* —— **与 Seal 的定位相同** ⇒ **它是最有参考价值的上游** ✓；
   - ⚠️ **Seal 的 git 历史被重建过**（659 个提交同一作者，历史里没有上游提交）
     ⇒ **与上游没有共同祖先 ⇒ `git merge` / `git rebase` 都不可用** ✗
     ⇒ 只能做**语义对照**：读上游对应文件、比**做法**、把结论写回台账 ✓；
   - **对照结论有两种，都要记**：「**跟**」（上游更对 ⇒ 按 Seal 结构改造，不是照抄 ✓）
     与「**不跟**」（Seal 已更好 / 上游没有 ✓）—— 后者同样省钱（避免去修没坏的东西 ✓）。

## 2. 代码规范

- **绿色基线**：离开工作区的改动必须能编译通过，绝不留下「调用了未定义函数/字段」的中间态。
- **最小改动**：只改目标所需，不顺手重构；根因修完即停。
- **根因不绕绕**：从真机日志定位根因再改，禁止 `--no-verify` 类绕行；现象→根因→修复→回归闭环。
- **大包内存纪律**：500MB+ 只流式处理（`unzipItem` 等），禁止整块载入内存。
  注意还有两条**未走流式**的历史路径：`AppFileStore.extractNestedIPAIfNeeded`（嵌套包整份进内存）、
  `IPAParserService` 为读 Mach-O 头而 `extract` 整个主二进制 —— 改到它们时顺手改掉。
- **错误码规范**：一律 `ImportFailure(title/reason/recovery/code)`，code 用 `SEAL-<模块>-<类别><序号>`，
  唯一且带可恢复引导。改动错误分类前先跑 `Scripts/` 里的码清单核对（全仓已有 327 个码 / 29 个模块前缀）。
- **并发基线**：`Config/Base.xcconfig` 已开 `SWIFT_VERSION = 6.0` + `SWIFT_STRICT_CONCURRENCY = complete`。
  全仓在最严档下编译，新增 `@unchecked Sendable` 需要写清「谁在保护它」，不要靠它消警告。
  仓里已有 5 份手写锁保护的 continuation 盒（`ContinuationBox` / `HardTimeout.RaceState` /
  `BlockingCall.Outcome` / `AppleAccountClient.LegacyCallbackBox` / `AnisetteClient.InFlightGeneration`）——
  **不要再加第 6 份**，需要新盒时先看能否复用现有语义。

## 3. 三链路关键约束（改动必查）

### 签名
- 证书复用只允许剩余有效期 **> 7 天**（覆盖免费 profile 7 天寿命）：只判「当下未过期」会把次日到期的
  证书签进新包 → iOS 判「尚未验证」闪退。复用/新建各分支（快速路径列表命中、网络失败回退、
  慢速路径选中、账户证书、新建证书收尾）都要过 `SigningCertificateMaterialPolicy.reuseStatus` /
  `certificateReusable(_:)`。**网络失败回退本地证书也必须查有效期。**
  ⚠️ 其中「快速路径列表命中」与「网络失败回退」两支目前既无守卫也无单测（`signingIdentity` 是
  actor private 且含网络）—— 改这两支时先把它抽成纯函数再改。
- 序列号跨来源比对必须**归一化（去前导零/大小写）**，否则误判「证书已轮换」（`normalizedSerialNumber`）。
- 签名/续签处于 LocalDevVPN 环境，无法可靠自动重登 Apple；会话过期统一引导到「我的」页重新验证，
  **不要实现会触发 2FA 的签名页验证码路径**。
- `SigningCoordinator` 里预拉起隧道的 `channelStart = Task { installChannel.start() }` 在缓存命中
  提前 return / 抛错路径上不会被取消，会与安装阶段的 `start()` 并发 —— 碰这块时一并处理。

### 安装
- 上传与安装必须在**同一条缓存 RemotePairing 会话**上（jas / IdeviceGateway 共同不变量）；
  跨会话一定 `MissingPackagePath`。
- **确定性拒绝必须立即终止、不得重传重试**，且「两张表同源」包含两层意思：
  1. **词表同源**：`isTerminalInstallError`（重试前判定）与 `installationFailure`（最终归类）
     必须是同一份词表。
  2. **取词同源**：两处必须用同一个函数从错误里取文本。历史上第二次踩坑就是词表一致、
     但重试侧用 `NSError` 桥接取词，而生产路径抛 `MinimuxerError.InstallApp(deviceError)`
     （该枚举只遵循 `Error` + `CustomStringConvertible`），桥接后 `ApplicationVerificationFailed`
     / `No space left` 等设备原文**全部丢失** ⇒ 500MB 整包被空推 3 轮。
     现在两处都经 `MinimuxerInstallChannel.diagnostic/errorDetail`，验收测试在
     `SealTests/Installation/InstallChannelDiagnosticClassificationTests.swift`。
- 新增错误名时 grep 上面两处，一次改全。
- **错误码 → 按钮动作必须用显式码集合**（`InstallFailureActionPolicy`），禁止
  `hasPrefix("SEAL-INSTALL-71"/"72"/"73")` 这类数字区间：区间会把 `SEAL-INSTALL-738`
  （上一笔安装仍在跑）与 `737`（事务未就绪）算成「重新签名」，把 `702t`（超时 ≠ 失败）
  算成「重新安装」—— 一次点击就造出并发 installd。
- 存储不足（`No space left`/`ENOSPC`/`code 28`）显示「设备存储空间不足」而非 WiFi 提示；
  iOS 拒绝用「知道了」按钮、立即终止、不重试。
- **超时 ≠ 失败**：`Minimuxer.stageAndInstall` 是同步阻塞 FFI、无取消机制，上层超时只是不再等待，
  底下很可能还在装。所以超时不得自动重试、`cancelsWorkOnTimeout: false` 的路径不得连带取消工作。
- 未配对 / 未信任 / 握手失败 / 隧道不可达必须由 `classifyDiscoveryFailure` 分开归类，
  不许一律显示成「检查 Wi-Fi/LocalDevVPN」。
- **有外层重试的地方，内层预算必须短**（2026-09-20 真机，构建 184）。就绪探测
  （`Minimuxer.ready()` / `fetchUDIDDetailed()`）跑在 `diagnose()` 的 36 轮重试循环里，
  却各自用 `Device.getFirstDevice()` 的默认轮询预算（**15 秒**）⇒ 真机上「验证中」卡
  **12 分钟以上**没有任何结论 ✗；而且**设备不可达时每轮都走满**（最坏路径 = 最常见路径 ✗）。
  现改为 `probeDeviceFetchTimeoutMs`（1 秒）＋ `ready()` 里**便宜判据提到最贵那步之前**
  ⇒ **约 20–60 秒**（隧道没通 ~20 秒；隧道通了、只差设备 ~56 秒）；
  守卫 **R61** 按**下标顺序**钉住（只查「传了短预算」会被上游顺序骗过去 ✗）。
  ⚠️ **`offThread(seconds:)` 到点就返回，但里面不会停**（`BlockingCall` 明文写着「FFI 仍在后台跑完、
  结果被丢弃」）⇒ 于是有两件事要分开算：
  ① **等待** = 「外层有界等待」与「内层预算」中的**较小者**（`isReady()` 外面就套着
  `offThread(5 秒)` ⇒ 修复前每轮只等 5 s ＋ 500ms 睡眠 = **5.5 s** ⇒ 名义上限 **≈ 3.4 分钟**，
  那 15 秒**从来没有延长过等待**）；
  ② **代价** = 每轮**丢掉一个还在跑 15 秒的后台阻塞调用**，它一直占着 Swift 协作线程池的线程，
  把后续 `Task.sleep` 与计时器的恢复一并推迟 ⇒ 这才是实测 **12 分钟以上**（≈ 每轮 20 秒）
  的来源 ✓。**修复的关键那一刀是把它缩到 1 秒**，不是那点算术。
  ⚠️ 还要**逐行读控制流、确认哪些调用真的会到达** ——「可能很贵的调用」≠「一定会被调用」
  （`readyDeviceIdentifier()` 第一行是 `guard await isReady() else { return nil }` ⇒
  `ready()` 为假时 `fetchUDIDDetailed()` 根本不会被调用）。
  **这个数字我改过三轮**（3.5 分钟 → 9–18 分钟 → ~9 分钟 → 名义 **3.4 分钟** / 实测 12 分钟以上），
  三轮错法都记在 `DEBUG_LOG.md` 同名条目里 —— **算墙钟前先读那段**。

### 续签
- 免费账号 3-app 上限是**设备级、跨不同 Apple ID/team 累计**；判据在
  `SigningCoordinator` 的设备级计数（`account.isFreeTeam`、排除付费账号应用、排除待装自身、`>=3`
  抛 `SEAL-APPID-DEVICELIMIT`）。
- 批量续签（`refreshAll`）调 `signAndInstall` 必须传 `bypassFreeAccountDeviceLimit: true`
  （覆盖已装应用不新增槽位）；单签 `runSigning` 默认 false，靠「继续绕过」按钮传 true。
- `refreshFailedItems` 只重试上一轮失败的 App，不是全量。
- 自替换成功与否**只能由安装后启动的新进程读真实落盘签名身份对账**（`SelfReplacementTransaction`），
  当前进程绝不自判成功；`requireRecovery` 保持 pending 是有意的（等下次启动再评估），
  但**任何永不满足的判据都不得留在 pending** —— 那会让 `create()` 永久抛 `alreadySubmitted`
  把自续签锁死（旧版 handoff 迁移就是这么修的：迁移即终态）。
- 批量结果持久化里 Seal 那一项目前被**预先**记成 `completed`（`AppsViewModel.persistPendingBatchResultForSealUpdate`），
  这是为消除 2026-09-17「同一批次给出互相矛盾结论」而做的取舍；要改成「待确认」必须连恢复链路一起改，
  不能只翻这一处。

## 4. 描述文件 / 证书 / 日志

### 设备端描述文件
- 描述文件存在**手机系统 profile 存储**（profiled），经 misagent 枚举/删除，不属于任何 App 文件夹。
- misagent 返回 **CMS 签名包裹的二进制**，解析不了会落盘成 `unknown_N.plist`。
  `DeviceProfileCleaner` **不能按扩展名过滤**，所有文件都交给 `ProvisioningProfileReader`（内置解 CMS）
  识别，并按 UUID 去重（LockDown 路径同一 profile 会落 raw + plist 两份）。
- 清理**只按同一 Bundle ID 的 UUID 精准删，严禁删全部**（会误删其他 app 的 profile 致连锁闪退）；
  `protectedBundleIDs` 必填、扩展靠父 App 保留集合兜底，通道不可信时整轮 fail closed。
- 自替换路径的清理已改为**结算确认后**按 `keepProfileUUID` 精准清理
  （见 `SelfAppRegistrar`），与「安装前清理」是两种形态 —— 改之前先读当前实现是哪一种。
- 列目录失败必须与「设备上确实没有」区分开（置 `stage` / `firstError`），否则清理静默不生效、
  profile 继续堆积而日志看不出来。

### 🔴 用设备查询结果决定「删不删」的路径（通用硬规则）

**凡「问设备 → 按答案删本地数据」的路径，必须共用同一套安全网。**
本仓已经因此**两次**静默删数据（不崩、不报错、**日志里一行都没有**，用户只看到数据凭空消失）：

| 路径 | 出事时间 | 现状 |
|---|---|---|
| 描述文件回收（`DeviceProfileCleaner` ＋ `ProfileReclaimPolicy`） | 2026-09-17 | ✓ 三件套齐全，守卫 **24 条** |
| 已安装列表对账（`AppsViewModel.reconcileInstalledAppsWithDevice`） | 2026-09-21 | 已补齐（`81a2552`，守卫 **R71**） |

⚠️ 两条路径调的是**同一个** `Minimuxer.isAppInstalled` ⇒ **加了保护的那条不会顺带保护另一条** ✗。
⚠️ 真机证据（守卫 `R44` 注释）：2026-09-19 日志里
「**阳性对照未通过（`com.mjorb.seal.CT8QZ7352B` 被答成未安装）**」——
**同一台设备确实会把「Seal 自己」答成没装**。描述文件路径靠这句话整轮不删 ✓；
已安装列表当时把**同一个答案**当成了「删」✗✗。

- 🔴 **动这类代码前先 `grep positiveControl`** —— 没有就照抄下面的五件套，**别自己设计**。
- **五件套**：① **阳性对照**（拿一个**确定存在**的对象去问，如 Seal 自己 —— 它正在运行就一定装着）；
  ② 失败**中止整轮**（不是 `continue` 只跳过当前这条）；③ **探测与删除分两轮**
  （半路中止时，已经问过的那几条也不删）；④ 决策抽成**纯函数 ＋ 单测**
  （错法不崩、不编译失败、**只在真机上删数据**）；⑤ 失败**必须留痕**（日志码）。
- 🔴 **绝不把「查询失败」与「否」折叠成同一个值的 API 交给这类调用方**：
  `Bool` / `String?` / `nil` 都不行 —— 调用方一句 `try?` 加默认值就把失败读成了「没装」。
  底层 `_rust_bridge_instproxy_lookup` **已经把 lookup 的 `Err` 与「没查到」返回成同一个空指针**
  ⇒ 必须交出**三态**（`ProfileReclaimPolicy.InstallProbe`），让调用方**没有机会**折成 `false`。
- ⚠️ **触发时机也一致**：失败集中在**刚启动**（构建 175 实测：冷启动后 22 秒 / 自替换重启后 60 秒），
  16 秒后再跑就正常 ⇒ 而这两条路径**都在启动时跑**
  ⇒ **没有阳性对照就等于「每次冷启动清空列表」** ✗。
- ⚠️ 守卫的源码断言只能证明函数存在，**证明不了行为**（判据被删空照样全绿）
  ⇒ 必须同时加单测：「对照没过一份都不删」「查询失败中止整轮」「中止是全局的」。

### 日志
- 导出统一 `SealLogTextFormatter`：北京时间（Asia/Shanghai `yyyy-MM-dd HH:mm:ss`）+ 中文栏目。
- 容量环形 1000 条，满后滚动丢最旧并计数；导出头部注明「保留最近 N 条」。
- `SealLogStore` 每次 `flush()` 都镜像 `Seal-log.txt` 到 Documents（只镜像 error 会导致顺利操作无日志可查）。
- **写入与读取都要脱敏**：`append` 过 `LogPrivacyRedactor`，`entries()` 再过一层；
  `exportText()`（= 镜像到 Documents 的那份）也必须过，否则升级前遗留的未脱敏 JSON 会被原样导出。
- 日志导出/上报**不携带** keychain 凭据、Apple ID 明文。
  ⚠️ 已知违反：`DEBUG_LOG.md` 与 `docs/qa/` 若干文件里写有真实 Apple ID 邮箱与 Team ID，
  需按 `maskedEmail` 改写（公开仓库即泄露开发者账号）。
- `NSLog`（`AnisetteDataProvider.debugLog`、`MinimuxerInstallChannel` 设备标识失败）绕过脱敏与环形缓冲，
  只准打服务器地址/字节数这类无凭据内容；新增 `NSLog` 前先想清楚它会不会带出敏感值。
- 🔴 **埋点要覆盖「中间态」，不能只有「开始 / 结束」**：链路**卡住**时若日志与「正常但安静」同形，
  用户和你都分不出「还在跑」与「已经死了」✗。判据：问一句
  **「这条链路卡住时，日志里长什么样？」** —— 说不出「卡在哪一步」就必须补逐步留痕
  （2026-09-21：`MinimuxerInstallChannel.diagnose()` 约 160 行零埋点，真机上
  「验证中」卡住时**成功行与失败行都不出现**）。做法：留痕**包一层**（自动覆盖全部出口，
  别在每个 `return` 前补一句 —— 迟早漏掉的那个就是下次要查的那个）＋ 长循环进/出各一条；
  出口日志带**耗时 ＋ 逐步状态 ＋ 失败码**。
  ⚠️ **别给「日志设施自己也不可用」的分支补日志**（`logStore` 同为 nil 的 `startupFailure` 路径）。

## 5. 验证纪律

- **真机优先**：涉及安装/installd 的改动必须走回归样本真机验证（见 `docs/qa/device-regression-checklist.md`）；
  单测/编译通过 ≠ 可用。
- **自证**：不声称「已修复/已完成」直到有验证证据。
- **纯函数化才能测**：判据落在 actor / 网络 / `#if !targetEnvironment(simulator)` 里就测不到。
  新增不变量时把判定抽成可单测的纯函数（`errorDetail`/`isTerminalInstallError`/
  `InstallFailureActionPolicy` 都是这么挪出 `#if` 的），并补一条守卫测试。

## 6. 版本与发布

- 凡「需发版让用户可检测到」的代码更新，必须 bump `MARKETING_VERSION`（`project.yml` 的 Seal 主 target）。
  ~~主 target 与 SealTunnel 扩展两处一致~~ → **内置 SealTunnel 扩展已移除**（`project.yml` 只剩一个
  `MARKETING_VERSION`，`Scripts/verify-ipa.sh` 发现 `PlugIns` 即判失败），VPN 依赖外部 LocalDevVPN。
- 内置更新比较 `CFBundleShortVersionString` 与 Release `tag_name`（支持 `1.0.13`/`v1.0.13` 前缀），
  Release tag 必须与 `MARKETING_VERSION` 对齐，否则检测不到。
  `CURRENT_PROJECT_VERSION` 由 CI `GITHUB_RUN_NUMBER` 覆盖。
- 发布正文来自 `RELEASE_NOTES.md`；两份工作流的 publish 步骤已加存在性判空，缺文件直接失败并给注解。
- 跨仓库发 Release（源 `sunuannian1/Trae-seal` → 目标 `sunuannian1/Seal-Releases`）**不传 `--target`**，
  否则用源仓库 SHA 会 422（`target_commitish invalid`）。
- ⚠️ 更新链路目前**只校验 `tag_name` 与 IPA 版本串相等**，不校验 `Seal_*.ipa.sha256` ——
  修它之前不要假设「下载到的包一定是自己发的」。

## 7. CI / 工程约束

- `ios.yml` 完整档：RustBridge 一致性 + UI 回归 + 签名测试，大改动走它。
  `ios-release.yml` 发布档：Release 编译 + 发布。`ios-fast.yml` 是 `main` 的快速出包档
  （注意它用 **Debug** 配置且不跑守卫与测试）。
- **触发方式**：`ios.yml` 除 PR 外，推到非 `main` 分支且改动命中相关路径也会自动编译；
  `publish-release` 始终只在 `workflow_dispatch` + `publish_release=true` 时触发，**push 路径绝不自动发布**；
  该不变量由 `Scripts/verify-release-safety.py` 静态守护（含变异自检）。
- **时间预算**：`ios.yml` 拆成 3 个并行 job —— `build-package` / `swift-regression` / `signer-tests`，
  墙钟取 max 而非 sum（实测 9m38s）。**不要加「按路径判定是否跑测试」的闸门**（曾实测无收益且承担漏跑风险）。
  ⚠️ 2026-09-19：`signer-tests` 由 `rork-sign-tests` **改名而来** —— 签名器换成上游
  `SideSign` + `CodeSignKit` 后 `Vendor/rork-sign` 已删除，该 job 改为测签名内核
  **`Vendor/CodeSignKit`**（守卫 R56 钉住它的存在与 `working-directory`）。
  ⚠️ 2026-09-20 **收窄**：**不再**测 `Vendor/SideSign` ✗ —— 它的测试**上游自己就编译不过**
  （缺 `import Foundation`），而剩下的用例只测 `Device` 模型与 `Archive` 往返，
  **Seal 完全不用 `SideSign.Archive`** ⇒ 零价值 ⇒ 按「不要打补丁」删掉那一步
  （连同 `Tests/` 与 `Package.swift` 的 `.testTarget` ✓）。
- `publish-release` 的 `needs` **必须包含 `swift-regression`**。
- **构建 App 的 job 必须跑 `ensure-rustbridge.sh`**，否则会链接到落后的 `RustBridge.xcframework`，
  报一堆 `_rust_bridge_*` undefined symbols。⚠️ 守卫目前只钉住 `ios.yml` 的两个 job，
  `ios-release.yml` 与 `ios-fast.yml` 无断言 —— 改这三档时人工确认。
- CI 失败原因必须能在不登录的情况下看到（`tee` 到 `build/TestLog.txt` + `::error::` 注解）。
- CI 缓存「Refresh local SPM binary artifacts」只清 `SourcePackages/checkouts`，
  **不许 rm 整个 SourcePackages**（会删掉 OpenSSL.xcframework → `openssl/err.h not found`）。
- CI 校验 `IPHONEOS_DEPLOYMENT_TARGET=16.0`（**三份** workflow：`ios.yml` / `ios-fast.yml` /
  `ios-release.yml` 各有一处 `test "$…_TARGET" = "16.0"`）＋ 守卫 **R68** 同时钉住
  `Config/Base.xcconfig`、`project.yml`(5 处) 与这三份 workflow ⇒ 改部署目标共 **9 处**，
  ⚠️ **只改 Xcode 声明会漏掉 CI 断言 ⇒ `build-package` 在 `Verify deployment targets` 步骤红**
  （2026-09-21 实际踩到：降 16.0 时漏了这三处，白烧一轮 CI）。
- 改工作流触发条件前先跑 `Scripts/verify-release-safety.py`。
  ⚠️ **裸 `python` / `python3` 在本机不可用**（WindowsApps 存根：零输出、退出码 49
  —— 静默「没输出」不等于通过 ✗）；**但守卫本机可跑** ✓ —— 用托管解释器的**绝对路径**：
  `C:/Users/DMJ/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe Scripts/verify-release-safety.py`
  （一轮 85–200 秒，**必须放后台跑**，否则会被 120 秒默认超时 SIGTERM 且没有任何输出 ✗）。
  ⇒ **CI 只当最后一道关，不要拿它当第一次验证。**
