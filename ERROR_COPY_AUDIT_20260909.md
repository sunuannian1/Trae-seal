# Seal 报错文案审计清单

- 审计日期：2026-09-09
- 范围：`Seal/` 全部 Swift 源码中面向用户的报错文案（`ImportFailure(title:reason:recovery:code:)` 及带 `SEAL-` 码的 alert / throw）
- 口径：`精准` = reason 说明确对象（ID / Bundle ID / 文件名 / 证书序列号 / UDID / 账号 / 具体原因），且 recovery 是可执行动作；`模糊` = reason 泛化、或 recovery 仅「重试 / 稍后重试 / 重新打开 / 知道了」、或文案为空、或 code 不完整/复用错乱。

---

## 1. 结论速览

- 报错码 **约 200+ 个**（含大量小写字母后缀变体），分布在 **30 个文件、约 27 个模块**。
- 模块分布：`AUTH、INSTALL、SIGN、CERT、PAIR、PROFILE、IPA、BUNDLE、APPID、RENEW、NET、ANI、VPN、TUNNEL、STORAGE、NOTIFY、HISTORY、JIT、CUSTOM、ENTITLEMENT、EXT、DEVICE、VERIFY、SET、OP、APP、INVENTORY` 等。
- 总体结论：**约一半精准，一半存在模糊或一致性隐患**。问题高度集中，主要不是「没写文案」，而是「文案不具体 / recovery 只让重试 / code 复用错乱 / 有参数却没拼进去」。

---

## 2. 十大系统性问题

1. **recovery 空泛**（最多见）：大量错误 recovery 只剩「重试 / 稍后重试 / 重新打开 / 知道了」，无实质指引。
2. **reason 泛化**：不写具体对象——缺哪个字段、哪个扩展、哪个路径、哪个应用、实际 vs 上限数值。
3. **有参数却没拼进文案**（一键可修）：`SEAL-PAIR-206a`（有 UDID）、`SEAL-INSTALL-707a`（有 Bundle ID）、`SEAL-CERT-210a`（有序列号）、`SEAL-APPID-302`（有被占用 Bundle ID）。
4. **同一 code 多语义 / 同一语义多 code**：`SEAL-AUTH-107` 三处异义、`SEAL-AUTH-102a~e`、`SEAL-AUTH-112a~d`、`SEAL-CERT-204 系`、`SEAL-INSTALL-702`、`SEAL-PROFILE-303`、`SEAL-SIGN-501` 等。
5. **code 命名不规范**：大量小写字母后缀（`105a~f`、`702b/l/s/t`、`107a~h`、`404a~d`…）；无序号（`SEAL-APPID-LIMIT`）；模块段多词（`SEAL-STORAGE-IMPORT-002`、`SEAL-IPA-RECOVERY-00x`）。
6. **title 错位**：`SigningCoordinator.failure()` 把 title 写死「无法完成签名」，导致 `PAIR / AUTH / APPID / BUNDLE` 等模块错误都显示「无法完成签名」。
7. **技术信息暴露**：`SEAL-INSTALL-500` 兜底把 `nsError.domain/code/localizedDescription` 直接拼进 reason（一处已改「已写入脱敏日志」，`signAndInstall` 版本仍暴露）。
8. **同话术多码**：WiFi/VPN 通用话术 5 码同文案（`INSTALL-701/703/705/706b/708`）；Anisette 4 码同文案（`ANI-110~113`）。
9. **recovery 不对症**：`SEAL-AUTH-109`（无 Team ID）recovery 是「重新验证」，解决不了无 Team 问题；`SEAL-ENTITLEMENT-401/402` 共用 title「描述文件校验失败」。
10. **结构性缺失**：`AnisetteError` 17 条纯英文、无 code、无 recoverySuggestion；`SignedArtifactValidator` 只产 reason+code，无 title/recovery。

---

## 3. 整改优先级

- **P0（先修，影响正确性/安全/排查）**：语义冲突与 code 复用错乱；暴露敏感技术信息；有参数却没拼进文案；同话术多码导致无法区分根因。
- **P1（再修，体感与可诊断性）**：reason 泛化 + recovery 仅「重试 / 知道了」；title 错位；recovery 不对症。
- **P2（最后，规范化）**：code 命名（字母后缀、多词模块、无序号）；结构性缺失（`AnisetteError`、`SignedArtifactValidator`）。

---

## 4. 逐条整改清单（按模块）

> 未列入本节的 code 视为已精准，整改时勿动。现状/改法为精简描述，改代码时以原文为准。

### AUTH（账号 / 认证 / 团队）

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-AUTH-101 | 「验证码无效 / 重试」reason 无对象 | 写明 Apple 返回的具体拒绝原因（错误码） | P1 |
| SEAL-AUTH-102 / 102a | 「验证失败 / 密码无效 / 重试」无对象 | 区分凭据失效 vs 密码错误，补具体诊断 | P1 |
| SEAL-AUTH-102d / 102e | 两码文案完全相同（会话失效 vs 握手失败未区分） | 各自写明真实根因 | P0 |
| SEAL-AUTH-105 | SigningCoordinator「账号记录不存在」未指账号 | 拼入 accountID / 邮箱 | P1 |
| SEAL-AUTH-106 | 「本地数据未更新 / 重试」无对象 | 写明是哪个账号、哪类数据 | P1 |
| SEAL-AUTH-107 / 107a | 三处异义复用（verify 失败 / Anisette 被拒 / 会话过期） | 拆分独立 code | P0 |
| SEAL-AUTH-108 | 「账号不一致」未说明哪项不一致 | 写明期望 vs 实际（邮箱/teamID） | P1 |
| SEAL-AUTH-109 | 无 Team ID，recovery「重新验证」不能解决问题 | 改为「确认已同意开发者协议或更换 Apple ID」 | P1 |
| SEAL-AUTH-110b | 「账号保存失败 / 重试」无对象 | 写明保存哪个字段、底层原因 | P1 |
| SEAL-AUTH-112a~d | 四码同为「Team 不可用/不一致/不匹配」 | 归并或逐一区分根因 | P0 |
| SEAL-AUTH-DB-003 | 「稍后重试」无实质指引 | 写明为何读不到 Keychain、何时可重试 | P1 |
| SEAL-VERIFY-500 / 500a | 「无法分类的错误」直接宣告不可分类，无诊断 | 补底层 domain/code（脱敏） | P1 |

### CERT（证书）

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-CERT-101 | 「证书状态或 Keychain 二选一保存失败」不明确 | 区分具体哪一项失败 | P1 |
| SEAL-CERT-102 | 「证书选择未保存 / 重试」 | 补底层原因 | P1 |
| SEAL-CERT-204 / 204b / 215b / 215c | 文案雷同「无法创建签名证书 / 重试」 | 归并 + 写明是证书上限还是网络 | P0 |
| SEAL-CERT-205 | 「证书服务暂时不可用 / 重试」 | 写明超时/拒绝等服务状态 | P1 |
| SEAL-CERT-210 | 「无法创建证书 / 重试」 | 写明上限/网络/权限 | P1 |
| SEAL-CERT-210a | 拿到了 `serialNumber` 却没写进文案 | 拼入要撤销的证书序列号 | P0 |
| SEAL-CERT-211 / 208a | 两码文案完全相同 | 归并 | P0 |
| SEAL-CERT-212 | 「没有返回明确失败原因」空泛 | 至少写明「网络/权限/已处理」等可能维度 | P1 |
| SEAL-CERT-206a | recovery 仅「知道了」无补救 | 补「重新同步证书 / 重新验证 Apple ID」 | P1 |

### PAIR（配对）

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-PAIR-201 | 文件过大/格式错/缺字段多因坍缩一句 | 分立或拼入具体校验失败点 | P1 |
| SEAL-PAIR-203b | recovery「连接设备」无操作步骤 | 写明「使用配对助手 / 连接同一设备」 | P1 |
| SEAL-PAIR-206a | 拿到 `fileUDID`/`connectedUDID` 却没写 | 拼入两处 UDID 对比 | P0 |

### INSTALL（安装）

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-INSTALL-500 | 暴露 `nsError` 原始堆栈给用户 | 统一改为「技术信息已写入脱敏日志」 | P0 |
| SEAL-INSTALL-701 / 703 / 705 / 706b / 708 | 五码 WiFi/VPN 通用话术、各有具体根因却无法区分 | 各自写真实原因（设备断开/未信任/超时/被拒） | P0 |
| SEAL-INSTALL-702 | 设备断开 vs 安装失败共码 | 拆分 | P0 |
| SEAL-INSTALL-702t | 「安装超时 / 重试」 | 写明实际耗时阈值、是否已自动重试 | P1 |
| SEAL-INSTALL-707a | 拿到 `bundleID` 却没写 | 拼入「未返回的 Bundle ID」 | P0 |
| SEAL-INSTALL-710 | 与 Minimuxer 的 710 语义不同却同码 | 拆分/重命名 | P0 |
| SEAL-INSTALL-720 | 动态 code/reason 来自验证器 | 固定 title/recovery 组装 | P1 |

### SIGN（签名，SigningWorkspace / PortalService / SigningCoordinator）

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-SIGN-401 | 「未找到主应用」无路径 | 拼入查找路径 | P1 |
| SEAL-SIGN-402 / 402a | 「解压超上限」无数字 | 写入实际 vs 上限 | P1 |
| SEAL-SIGN-403 | 「不安全路径」未写具体路径 | 拼入路径 | P1 |
| SEAL-SIGN-404 | 「应用记录不存在」未指应用 | 拼入应用名/ID | P1 |
| SEAL-SIGN-404a | 「应用结构无效」泛 | 写明缺哪个文件 | P1 |
| SEAL-SIGN-404b / 404c / 404d | 「标识无效/信息无效」泛且同文案多码 | 归并 + 具体化 | P0 |
| SEAL-SIGN-500 | 「未预期错误 / 重试」 | 至少给日志已脱敏提示 | P1 |
| SEAL-SIGN-501 | 两处异义复用（.signing vs invalidAnisette 重试） | 拆分 | P0 |
| SEAL-SIGN-502 | 「打包失败 / 重试」 | 写明打包阶段与底层原因 | P1 |
| SEAL-CUSTOM-004 / 004a / 004b / 004c | 图标「读取/处理/编码」同义分四码 | 归并 | P0 |

### PROFILE / ENTITLEMENT（描述文件 / 权限）

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-PROFILE-303 | 描述文件生成失败 vs 主应用描述文件缺失，同码不同义 | 拆分 | P0 |
| SEAL-PROFILE-304 | 「应用能力更新失败」空泛 | 写明具体能力项 | P1 |
| SEAL-ENTITLEMENT-401 / 402 | 共用 title「描述文件校验失败」语义不符 | 改为「权限缺失 / 权限不一致」 | P1 |

### APPID

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-APPID-302 | 已知被占用 Bundle ID 却没写 | 拼入 Bundle ID | P0 |
| SEAL-APPID-304 | recovery 仅「知道了」无操作 | 明确「7 天后过期或换账号」 | P1 |
| SEAL-APPID-LIMIT | code 无序号 | 改为数字序号 | P2 |

### IPA（导入 / 解析 / 存储）

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-IPA-101 / 101a / 102 / 102a / 102b / 102c / 103 / 104 / 105 / 106 | reason 泛化（缺字段/多应用/非法路径/超上限均无具体对象） | 逐一补：字段名 / 应用数 / 路径 / 实际 vs 上限 / 文件 | P1 |
| SEAL-IPA-200 / 205 | 「解析失败 / 保存失败 / 重试」 | 补底层原因或失败阶段 | P1 |
| SEAL-IPA-201 / 202 / 203 / 204 / 208 / 210 / 211a / 212 | 「目录不可用/复制失败/存储失败/临时无效/无法读取/无法取出」均丢弃底层错误 | 透传底层错误（脱敏） | P1 |
| SEAL-IPA-206 | 「文件选择失败 / 重试」 | 写明取消 or 系统错误 | P1 |
| SEAL-IPA-ROLLBACK-001 | recovery 依赖「重新打开」 | 写明已保留恢复记录、何时自动继续 | P1 |
| SEAL-IPA-RECOVERY-001 / 002 / 003 / 004 | recovery「重新打开后重试」+ 模块段多词 | 补即时动作；code 规范化 | P1/P2 |

### RENEW（续签）

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-RENEW-404 | 「未找到该应用记录」未指应用 | 拼入应用名/ID | P1 |
| SEAL-RENEW-500a | 「队列执行失败 / 重试」 | 写明哪个阶段、哪个应用失败 | P1 |

### NET / ANI / VERIFY（网络 / Anisette）

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-NET-101 | 「无法连接 Apple 服务 / 网络恢复后重试」无具体网络原因 | 写明 DNS/超时/不可达 | P1 |
| SEAL-ANI-110 / 111 / 112 / 113 | 四码同文案「Anisette 服务暂时不可用 / 重试」 | 各自写真实根因 | P0 |
| SEAL-ANI-114 | 直接透传底层 `localizedDescription` 无结构化说明 | 包裹为可读说明 + 脱敏 | P1 |

### STORAGE / LOG

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-STORAGE-001a / 002 | 「文件仍在使用 / 稍后重试」不说明占用方 | 写明占用方或等待动作 | P1 |
| SEAL-STORAGE-SELF-001 | recovery 依赖「重新打开」 | 补即时动作 | P1 |
| SEAL-STORAGE-IMPORT-002 | 模块段多词（文案随调用点具体，本身精准） | 仅 code 规范化 | P2 |
| SEAL-LOG-001 | 「日志文件仍在使用 / 重试」 | 写明何进程占用 | P1 |

### NOTIFY / HISTORY（通知 / 历史）

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-NOTIFY-002a / 002b | 「调度失败 / 配置失败 / 重试」 | 写明权限 or 系统限制 | P1 |
| SEAL-HISTORY-001 / 003 / 004 / 004a / 005 / 006 | 告警类 reason 未指明失败点/账号 | 补具体失败点 | P1 |

### UI / 应用层（AppsViewModel / Settings / AppContainer）

| code | 现状问题 | 建议改法 | 优先级 |
|---|---|---|---|
| SEAL-APP-001 | 存储初始化失败，recovery 仅「知道了」死胡同 | 补「重启 / 备份恢复」指引 | P1 |
| SEAL-APP-002 / 003 | 「读取失败/删除失败 / 重试」无对象 | 写明应用名与原因 | P1 |
| SEAL-BUNDLE-003 | 「草稿保存失败 / 重试」 | 写明失败点 | P1 |
| SEAL-CUSTOM-002 / 003 | 「名称/图标保存失败 / 重试」 | 写明失败点 | P1 |
| SEAL-SET-001 | 「本地配置不可用 / 重试」 | 写明哪项配置 | P1 |
| SEAL-INSTALL-707 | 「未能读取真实已安装状态 / 知道了」 | 补补救指引（重新配对/重连） | P1 |
| SEAL-INVENTORY-900 / 900a | 「同步失败 / 重新同步」 | 补底层原因 | P1 |

---

## 5. 已精准项（勿动，供核对）

判定原则：`reason 含具体对象 + recovery 可执行`。**凡未列入第 4 节清单的 code 均视为已精准，整改时勿动。**

公认精准的代表（无争议，供对照）：

- `SEAL-BUNDLE-004`：Bundle ID「X」被手机上的「Y」占用。
- `SEAL-APPID-DEVICELIMIT`：免费账号 3 应用上限 + 「先在手机卸载一个自签应用」。
- `SEAL-NET-102`：点名 `developerservices2.apple.com` + 代理/换热点指引。
- `SEAL-OP-001`：指名当前冲突操作 + 原因。
- `SEAL-INSTALL-720 ~ 730`（SignedArtifactValidator）：0 字节 / 缺 Payload / 缺 Info.plist / 缺可执行文件 / 数量，均具体。
- `SEAL-IPA-207 / 209`：递文件名 / 说明「含多 IPA 无法判断」。
- `SEAL-JIT-001/002/003/OK`、`SEAL-TUNNEL-001/002`、`SEAL-APP-ROLLBACK-001`、`SEAL-AUTH-DB-001/002`、`SEAL-CERT-216`。
- 多数 PAIR 状态类：`SEAL-PAIR-203~211`（除 203b、206a 已在第 4 节）。

> 说明：第 4 节的「问题清单」为审计时判定有模糊/复用/规范风险的项；其余未列 code 默认精准，无需改动。

---

## 6. 进度跟踪

> 整改时逐条勾选，状态可选：`待改` / `已改` / `已验证(真机)`。

### P0（已改，待 Xcode 编译 + 真机回归）

| 项 | code | 状态 | 备注 |
|---|---|---|---|
| 脱敏 INSTALL-500 残留暴露点 | SEAL-INSTALL-500 | 已改 | signAndInstall 版本统一「技术信息已写入脱敏日志」，不再拼 nsError |
| 区分 INSTALL 五码同话术 | 701 / 703 / 705 / 706b / 708 | 已改 | 各写真实根因（VPN 未就绪 / 未响应 / 未信任 / 超时 / 被拒） |
| 区分 ANI 四码同话术 | ANI-110 / 111 / 112 / 113 | 已改 | 按 invalidIdentifier/invalidServerResponse/provisioningFailed 等分码 |
| 拼 UDID | PAIR-206a | 已改 | 拼入 fileUDID / connectedUDID 对比 |
| 拼 Bundle ID | INSTALL-707a | 已改 | 拼入未返回的 Bundle ID |
| 拼证书序列号 | CERT-210a | 已改 | 拼入要撤销的 serialNumber |
| 拼被占用 Bundle ID | APPID-302 | 已改 | 拼入 Apple 返回 diagnostic |
| AUTH-102d/e 同文案 | AUTH-102d / 102e | 已改 | 102d=凭据被拒绝、102e=登录握手未通过 |
| AUTH-107 系列复用 | 107 / 107a / 107h / 107t | 已改 | 107=会话过期(保留)、107a=验证失败(原 575 由 107 归一)、Anisette 被拒改 ANI-115、握手 107h、超时 107t |
| 无可用开发团队 | AUTH-107 → AUTH-114 | 已改 | 原复用 107，改为独立 code |
| AUTH-112a~d 文案趋同 | 112a / 112b / 112c / 112d | 已改 | reason 统一说明「已保存的 Team ID 不在 Apple 返回列表中」 |
| CERT-204 系文案雷同 | 204 / 204a / 204b | 已改 | 统一点明「证书数量已达上限或请求无效」+ 撤销旧证书指引 |
| CERT-215b/c 文案误导 | 215b / 215c | 已改 | 改为「证书已创建但处理失败，自动撤销也失败，可能残留占名额证书」 |
| CERT-211 / 208a 同文案 | 211 / 208a | 已改 | 211=创建失败、208a=已创建但本机保存失败已回滚 |
| SIGN-404b/c/d 泛化 | 404b / 404c / 404d | 已改 | 分别指向缺 CFBundleIdentifier / 改 ID 结构无效 / 写签名信息结构无效 |
| SIGN-501 两义复用 | 501 / 503 | 已改 | 501=签名工具阶段；重设 Anisette 后仍失败改 503 |
| CUSTOM-004a/b 同文案 | 004a / 004b | 已改 | 004a=无法读取位图、004b=裁剪失败 |
| PROFILE-303 两义复用 | 303 / 305 | 已改 | 303=描述文件生成失败；主应用描述文件缺失改 305（拼 Bundle ID） |
| INSTALL-702 共码 | 702 / 702d | 已改 | 设备断开改 702d，裸安装失败保留 702 |
| INSTALL-710 语义冲突 | 710 / 719 | 已改 | Minimuxer 隧道 710 保留；本机签名包记录不完整改 719 |

### P1（已改，待 Xcode 编译 + 真机回归）

| 批次 | 涉及 code | 状态 | 备注 |
|---|---|---|---|
| title 错位 | SigningCoordinator.failure() / ENTITLEMENT-401/402 | 已改 | SigningCoordinator 新增 `title(for:)` 按模块段映射；ENTITLEMENT 改「权限缺失/权限不一致」 |
| AUTH reason | 101/102/102a/105/106/108/109/110b/DB-003/VERIFY-500/500a | 已改 | reason 拼入账号/邮箱/ID/底层 domain+code；109 recovery 改「同意开发者协议或换 ID」 |
| CERT reason | 101/102/205/210/212/206a | 已改 | 206a recovery 补「换证书或重新验证」 |
| PAIR/INSTALL/SIGN | PAIR-201/203b、INSTALL-702t、SIGN-401/402/402a/403/500/502 | 已改 | reason 拼入路径/数值/阈值 |
| PROFILE/APPID | PROFILE-304、APPID-304 | 已改 | 写明能力项 / 7 天过期或换账号 |
| IPA | 101~106/200/205/201~212/206/ROLLBACK/RECOVERY | 已改 | reason 拼入字段名/路径/数值/底层错误（脱敏） |
| RENEW/NET/ANI | RENEW-404/500a、NET-101、ANI-114 | 已改 | 拼入 appID / 网络维度 / anisette 细节 |
| STORAGE/LOG/NOTIFY/HISTORY | STORAGE-001a/002/SELF-001、LOG-001、NOTIFY-002a/002b、HISTORY-001/003 | 已改 | reason 补 domain+code；recovery 补通知权限/配对指引；HISTORY-004/004a/005/006 reason 已具象、未动 |
| UI/应用层 | APP-001/002/003、BUNDLE-003、CUSTOM-002/003、SET-001、INSTALL-707、INVENTORY-900/900a | 已改 | reason 补 app 名/domain+code；APP-001 recovery 补重启指引；INSTALL-707 补配对指引 |

### P2（已改，待 Xcode 编译 + 真机回归）

| 项 | 状态 | 备注 |
|---|---|---|
| SIGN-404 撞号 | 已改 | 「签名临时空间不足」SEAL-SIGN-404 → SEAL-SIGN-405；「应用记录未找到」保留 SEAL-SIGN-404 |
| APPID-LIMIT 无序号 | 已改 | SEAL-APPID-LIMIT → SEAL-APPID-305 |
| STORAGE-IMPORT 模块段多词 | 已改 | SEAL-STORAGE-IMPORT-001/002 → SEAL-STORAGE-003/004 |
| IPA-RECOVERY 模块段多词 | 已改 | SEAL-IPA-RECOVERY-001/002/003/004 → SEAL-IPA-213/214/215/216（测试同步更新） |
| ROLLBACK/RECOVERY recovery 补「自动继续」 | 已改 | IPA-ROLLBACK-001 与 IPA-213~216 的 recovery 统一改为「下次启动 Seal 会自动继续…」，不再要求手动重试 |
| AnisetteError 结构评估 | 结论：不改 | 内部错误类型，仅本地 ODA 链路抛出，经 AnisetteV3Client 包裹为 ANI-114（中文主文案），英文 errorDescription 仅作补充细节透出；17 个 case 不必各自建 SEAL code |
| SignedArtifactValidator 结构评估 | 结论：不改 | 纯验证谓词（reason+code）；消费方 SigningCoordinator 已补 title「安装前验证失败」+ recovery「重新签名后再安装」，无用户可见缺口 |

### 自查对照（本次改动涉及的新 code 唯一性）

- 新增/改动 code：`AUTH-114`、`ANI-115`、`SIGN-503`、`SIGN-405`、`PROFILE-305`、`INSTALL-702d`、`INSTALL-719`、`APPID-305`、`STORAGE-003/004`、`IPA-213~216`、`AUTH-107a`（归一）。
- P2 code 重命名已 `rg` 复核：旧字面量 `SEAL-STORAGE-IMPORT-*`、`SEAL-IPA-RECOVERY-*`、`SEAL-APPID-LIMIT` 在 Seal/SealTests 源码中不再出现；`SEAL-SIGN-404` 仅剩「应用记录未找到」一处（SigningCoordinator），存储不足已改 `SEAL-SIGN-405`。
- 均已 `rg` 复核：`SEAL-INSTALL-710` 仅剩 Minimuxer 一处；`SEAL-AUTH-107` 仅剩会话过期语义（ApplePortalSigningService 44/270 + SettingsViewModel 865 消费）；无 code 撞号。

## 7. 说明

- 已完成的 P0/P1/P2 改动均为「文案字符串 + code 字面量」级修改，未改控制流，无新增 Swift/Rust 调用，无编译风险点（P2 的 code 重命名已同步更新测试 `AppFileStoreTests.swift`）。
- 仍须在 Xcode 编译 RustBridge + 真机回归样本（微信 / 黄豆短剧 / LCSign / lanmanga）验证报错路径显示正确。