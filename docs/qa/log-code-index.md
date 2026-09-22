# 日志码索引（真机日志里实际出现过的）

> **用途**：用户发来一份日志时，先用它把 `[SEAL-XXX-NNN]` 翻译成人话，
> 不用每次去 grep 源码。**完整码表有 300+ 个**（见 `Seal/**/*.swift` 里的 `code:`），
> 这里只收**真机日志里实际出现过**的那些。
>
> ⚠️ **本文件由脚本从源码抽取**（`code:` 往前找最近的调用起点，取其中的 `message:`/`title:`/`reason:`）。
> 守卫断言「本文件里的每个码在源码里仍然存在」—— 防的是**码被删掉、文档却还留着**这种情况
> （2026-09-17 实测踩到：`SEAL-APPID-305` 是刻意去掉的本地硬拦、`SEAL-CERT-224` 已不存在，
> 而旧日志里还留着它们，容易误判成「现在还在报」）。

## 怎么用

1. **先定版**（回归清单第 0 步）：没有 `构建 1.1.16 (N)` 表头 ⇒ 日志太旧，别分析。
2. 在下面查码 → 得到「它在说什么」。
3. **级别比码更重要**：`错误` 才需要处理；`警告` 多半是「降级但仍继续」；`信息` 是正常留痕。
4. 若某个码不在表里 ⇒ 说明它**从没在你的日志里出现过**，可以照常 grep 源码。

## 账号 / 登录

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-ANI-115` | Apple 拒绝了本次认证用的设备环境数据（Anisette） | `AppleAccountClient.swift` |
| `SEAL-AUTH-102a` | Apple 拒绝了该账号的登录凭据 | `AppleAccountClient.swift` |
| `SEAL-AUTH-102c` | **账号需要重新验证**（Apple 返回「认证状态无效」）⇒ 去「我的」重新登录 | `ApplePortalSigningService.swift` |
| `SEAL-AUTH-105a` | 本机 Keychain 里缺少该 Apple ID 的登录凭据（**重装 Seal 会清空 Keychain**） | `SigningCoordinator.swift` |
| `SEAL-AUTH-107` | **登录过期了**（1100 会话过期）—— 该码在账户阶段与 App ID 阶段**文案不同**，见源码 | `AppleAccountClient.swift` 等多处 |
| `SEAL-AUTH-107a` | Apple ID 验证失败（带诊断信息） | `AppleAccountClient.swift` |
| `SEAL-VERIFY-500` | Apple 验证返回了**无法分类**的错误；账号状态未改变 | `SettingsViewModel.swift` |

## 证书

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-CERT-204b` | 无法生成有效证书请求，或 Apple 拒绝了请求（**不代表名额已满**） | `CertificateRequestFailurePolicy.swift` |
| `SEAL-SIGN-501` | Apple 暂时拒绝了请求（App ID 阶段撞限流；**先等几分钟重试**） | `ApplePortalSigningService.swift` |
| `SEAL-APPID-303` | App ID 创建失败（Apple 未创建；常见原因见同行的 `Apple 返回：`） | `ApplePortalSigningService.swift` |
| `SEAL-EXT-401` | **扩展**无法创建 App ID（多扩展 App 会走到这条） | `ApplePortalSigningService.swift` |

## 导入 / IPA 校验

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-IPA-107` | **IPA 未砸壳**（主二进制 `cryptid != 0`，App Store 加密版）：重签能装上，但解密密钥与原签名绑定 ⇒ 启动会立即闪退。需先用砸壳工具重新导出 | `IPAParserService.swift` |

## 安装 / 设备通道

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-INSTALL-701` | 本地隧道未就绪，无法连接设备（确认 Wi-Fi + LocalDevVPN 已连接） | `MinimuxerInstallChannel.swift` |
| `SEAL-INSTALL-702f` | IPA 残留 **DRM 元数据**（`SC_Info` 里登记的 sinf 路径越界，installd 捕获 sinf 失败）：该包需**重新砸壳导出**，重签同一份无效 | `MinimuxerInstallChannel.swift` |
| `SEAL-INSTALL-702l` | iOS 拒绝了安装：**免费账号已装 3 个自签应用**或签名校验失败 | `MinimuxerInstallChannel.swift` |
| `SEAL-INSTALL-702s` | 设备**空间不足**（解压复制阶段） | `MinimuxerInstallChannel.swift` |
| `SEAL-VPN-001` | 签名完成后仍无法连接设备完成安装 | `SigningCoordinator.swift` |

## 已安装列表对账（防「设备查询失败 ⇒ 误删本地记录」）

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-RECONCILE-001` | 对账**跳过**：上一轮仍在进行（单飞闸门挡住了重复触发）—— **正常现象**，不是错误 | `AppsViewModel.swift` |
| `SEAL-RECONCILE-003` | 对账**中止**：**阳性对照未通过**（拿 Seal 自己问设备，答案不对）⇒ **本轮一条记录都不删**。**带「尝试 N 次 + 末次耗时」**：`0.x 秒` = 通道还没起来（下次就好，**info 级、不弹窗**），`15.0 秒` = 会话已死（**warning 级、会弹窗**，要查 LocalDevVPN） | `AppsViewModel.swift` |
| `SEAL-RECONCILE-005` | 对账**完成**：探测 N 条、删除 M 条（M 只应包含确实已从设备卸载的 App） | `AppsViewModel.swift` |
| `SEAL-RECONCILE-006` | 对账：**阳性对照是重试才通过的**（前几次通道未就绪）—— 说明「有界重试」把一次假警报救回来了 | `AppsViewModel.swift` |

> 🔴 **`-003` 是「防护生效」的信号，不是故障**：设备通道不稳时（iOS 16 + LocalDevVPN 常见），
> 查询会答不上来（实测文案：`阳性对照未通过（com.mjorb.seal.CT8QZ7352B：查询失败）`）；
> 此时**宁可不删** ✓。**看到它反而说明没在删数据。**
> ⚠️ 同一组的 `-002`（取不到自身 Bundle ID）与 `-004`（单条查询失败）**尚未在真机日志里出现过**
> ⇒ 按本文件规矩**暂不收录**（不是已移除）。
>
> ℹ️ 2026-09-22 起 `-003` 的成因被拆成两种，**看耗时（与级别）就能分**：
> `0.x 秒`（**info 级**）是**通道还没起来**（真机实测 3 秒后就正常）——
> `InstalledAppProbeRetryPolicy` 会先自动重试；重试仍失败就**静默跳过**
> （连弹窗都不弹，因为这一轮**什么都没改**，属于第③类「条件不满足 ⇒ 跳过」）；
> `15.0 秒`（**warning 级**）才是**会话已经死了**（隧道断 / VPN 关），
> 只有这一种才会给用户弹窗（且弹窗**不跳转**，文案明说「本轮未改动任何记录」）。
> ⇒ **判据：刷新时会不会被弹窗，只看这条 `-003` 的耗时**（判据是纯函数
> `InstalledAppProbeFailurePolicy`，与日志级别共用同一份）。
> 看到 `-006` = 重试救回来一次，属于**好消息**。

## 描述文件清理 / 维护

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-PROFILE-320` | 维护期清理摘要（`扫描/匹配/删除` + 旧 Team 变体计数）—— **唯一**覆盖全部管理 App | `AppMaintenanceJob.swift` |
| `SEAL-PROFILE-321` | 已清理 N 份设备端旧描述文件（有删才写） | `AppsViewModel.swift` |
| `SEAL-PROFILE-322` | 自替换结算清理摘要 —— **唯一**能回收 Seal 自己那份 | `SelfAppRegistrar.swift` |
| `SEAL-STORAGE-006` | 维护作业在「某阶段」被打断（用户操作开始），未执行的步骤已跳过 | `AppsViewModel.swift` |
| `SEAL-STORAGE-009` | 维护作业本轮**跳过**：有前台操作正在进行 | `AppsViewModel.swift` |

## 到期提醒 / 通知

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-NOTIFY-002a` | **后台重排**到期提醒失败，**带底层 `domain code` 与描述** | `AppsViewModel.swift` |

> ℹ️ 2026-09-22 起这条码的形态变了，看日志时注意两点：
> 1. **它现在带原因**（如 `通知调度失败｜UNErrorDomain 1｜…`）。旧日志里那 100 条
>    **只有一句「通知调度失败」**，事后完全无法归因 —— 那正是被修掉的问题本身。
> 2. **「系统没给通知权限」不再记成错误**：那是**已知条件**（设置页在显示授权状态），
>    属于「条件不满足 ⇒ 跳过」。⇒ 现在还在报 `-002a`，说明是**别的原因**，
>    而消息里会直接写明是哪一种。
>
> ⚠️ 同一组的 `SEAL-NOTIFY-001`（用户开了提醒但系统没授权）与 `SEAL-NOTIFY-002b`
> （改提醒时间时重排失败）**尚未在真机日志里出现过** ⇒ 按本文件规矩**暂不收录**（不是已移除）。

## 批量续签

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-RENEW-007` | 上次续签被中断，**N 个应用的结果未知**，需要重新核验（只有真没结论时才该出现） | `AppsViewModel.swift` |
| `SEAL-RENEW-011` | 用户取消批量续签（已处理 N/M） | `AppsViewModel.swift` |
| `SEAL-RENEW-020` | 逐项成功留痕（带描述文件 UUID + 创建/到期时间） | `RenewalCoordinator.swift` |
| `SEAL-RENEW-021` | 待恢复的批量续签结果**被跳过**（只该出现一次；反复出现说明判据退化） | `AppsViewModel.swift` |
| `SEAL-RENEW-023` | 批量续签结果已持久化（`.pushing`/`.installing` 会重复推送 ⇒ 可能写多次，正常） | `AppsViewModel.swift` |
| `SEAL-RENEW-024` | 批量续签结果已从持久化载荷恢复 | `AppsViewModel.swift` |
| `SEAL-RENEW-025` | 批量续签结果抽屉已关闭（带最终计数） | `AppsViewModel.swift` |
| `SEAL-RENEW-026` | 上次续签被中断，但 N 个应用的结果**已从载荷结算**（不再标为未知）—— 正常路径留痕 | `AppsViewModel.swift` |

## 账号清单同步

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-INVENTORY-100a` | 本机没有该 Apple ID 的登录凭据（同步前需要先验证） | `SettingsViewModel.swift` |
| `SEAL-INVENTORY-900a` | 证书状态同步失败（带 domain/code） | `SettingsViewModel.swift` |

## 已从源码移除（旧日志里还会看到，**别当成现在还在报**）

| 码 | 情况 |
|---|---|
| `SEAL-APPID-305` | 「`existing.count >= 10` 就硬拦」的本地预检，**已刻意去掉** —— Apple 的真实上限是「7 天内最多注册 10 个」（滑动窗口），本地一刀切会误拦 |
| `SEAL-CERT-224` | 源码里已不存在（历史码） |
