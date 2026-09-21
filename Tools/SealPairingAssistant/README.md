# Seal 配对助手

Windows 配对助手固定使用上游 `jkcoxson/idevice_pair` 的真实设备协议实现，Seal 只增加品牌、素材、视觉和 App 集成层。

## v10 前端定稿

- 使用 Seal 图标作为窗口 / 任务栏 / EXE 图标。
- 使用内置 iPhone 模型图作为主视觉素材。
- 主界面按极简毛玻璃前端重排：标题、设备、状态、一个主按钮、UDID。
- 删除界面上的日志、语言切换、配对准备分组、生成分组、写入已安装应用等入口。
- 正常状态隐藏无线调试、开发者模式、开发者磁盘映像、配对类型等细节；异常时只显示需要处理的项目。
- **配对类型不让用户选，按设备系统版本自动决定**（`seal_mode_for_ios`）：
  **iOS 17.4 及以上** ⇒ 远程配对（RPPairing）；**iOS 17.3.1 及以下（含 iOS 16）** ⇒ 本机配对（Lockdown）；
  版本未读到时禁用生成按钮，直到读取完成，绝不误用上游默认的远程配对。
  判据：**iOS 17.4 才引入 `CoreDeviceProxy`**，更早的系统在 USB 上引导不了远程配对。
  ⚠️ **分界是 17.4，不是 17.0** —— 17.0–17.3.1 与 iOS 16 走**同一条** Lockdown 路（2026-09-21 更正）。
  助手**不拒绝任何版本**：判定只有 `major > 17 || (major == 17 && minor >= 4)`，
  **实际下限由 Seal 自己的部署目标决定（`Config/Base.xcconfig` = iOS 16.0）** ——
  iOS 15.x 及以下助手照样能生成文件，但 Seal 装不上（支持矩阵见 `docs/qa/2026-09-20-pairing-os-support-matrix.md`）。
- 主按钮合并为“生成并写入 Seal”。

## 保留的上游真实链路

- USB 自动发现 iPhone/iPad
- Lockdown pairing
- RPPairing / CoreDeviceProxy / RSD
- 无线调试
- Developer Mode 检测
- Developer Disk Image 自动挂载
- Pairing 文件生成、加载、保存、验证
- Seal 直接写入

Seal 使用 `SealPairing.mobiledevicepairing` 作为 Documents 收件文件。Seal 会自动导入；手动导入继续作为恢复入口。

## Windows 前置条件

按上游要求使用 Apple 官网 Windows iTunes / Apple Mobile Device 组件提供 usbmuxd 通道。
不再要求用户手工复制 `idevice_id.exe`、`idevicepair.exe`、`ideviceinfo.exe`。

## 上游固定版本

- repository: `jkcoxson/idevice_pair`
- commit: `e3abb341b73a4fbeb96cdfc5e6652687e4bee130`
- version: `0.1.14`
- license: MIT
