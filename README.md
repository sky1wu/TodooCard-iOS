# TodooCard iOS

[![Build](https://github.com/sky1wu/TodooCard-iOS/actions/workflows/build.yml/badge.svg)](https://github.com/sky1wu/TodooCard-iOS/actions/workflows/build.yml)

TodooCard/T3 的原生 iOS 图片发送器。图片的解码、裁切、旋转、六色抖动、Payload
构建和 SHA-256 校验全部在手机本地完成，不依赖后端。

## 已实现

- 从照片、文件或剪贴板导入图片；
- 在 528 × 792 预览上实时拖动定位、双指缩放，并以 90° 为单位旋转；
- Floyd–Steinberg、Atkinson、Bayer 4×4 和最近色四种六色量化方式；
- 通过原生效果菜单切换四种量化风格，双指在 1×–4× 间缩放；
- 在六色量化前以 -100%–100% 亮度补偿调整中间调，改善实体屏偏灰偏暗的问题；
- 与网页版本一致的颜色 nibble、面板方向变换和 QuickLZ stored Payload；
- 按 `0x5053` 厂商标识与 `0x134C` 屏幕类型过滤设备；
- 读取加密 Battery Level 验证系统绑定，并支持 `FEF0/FEF1/FEF2` 与
  `FDF0/FDF1/FDF2` 两组 GATT 服务；
- 严格遵循原始 TodooCard skill 的安全 GATT 顺序：先单独读取加密 Battery Level，等待
  1.8 秒完成 Service Changed / 缓存刷新，再重新发现 FEF1/FEF2；
- 控制命令优先采用 `withResponse`，设备通知 600 ms 未到时按原始发送器流程用
  `withoutResponse` 备用重发；
- 5 块发送窗口、4 ms 块间隔、60 ms 窗口间隔、32 块最大未确认量；
- 累计 ACK、检查点超时有限重传，以及最终 `05 08` 刷新确认；
- 发送完成后复用当前 GATT 会话；设备主动释放链路时自动尝试恢复连接；
- 应用内诊断日志、电量、Payload 字节数和 SHA-256。
- 通过 App Intents 暴露“自动更新 TodooCard”快捷指令：接收上一步输出的图片，自动生成
  Payload、查找上次成功使用的卡片并发送，全程无需再次点按。

## 快捷指令自动更新

首次配置时，先在 App 中手动选择目标卡片并成功发送一次。TodooCard 会在本机记住这台
设备，之后快捷指令只会自动连接该设备；可在“诊断与设备”中确认“快捷指令设备”。

1. 打开系统“快捷指令”App，新建快捷指令或个人自动化。
2. 添加一个能输出单张图片的操作，例如“获取文件”“获取 URL 内容”或“查找照片”。
3. 在后面添加 TodooCard 的“自动更新 TodooCard”，将上一步的图片传给“图片”参数。
4. 运行时保持卡片开机并靠近 iPhone。快捷指令会在后台完成图片解码、默认六色处理、
   安全连接和发送，不会打开或切换到 TodooCard；成功以卡片返回的最终 `05 08` ACK 为准。

原图直接在本次 App Intent 执行期间处理，不写入暂存文件。后台连接会优先恢复上次成功
使用的 CoreBluetooth 设备，系统缓存不可用时才回退扫描。首次安装后仍需打开 App，授予
蓝牙权限并手动成功发送一次。快捷指令自身是否显示运行通知由系统“运行时通知”设置控制。

## 打开与运行

1. 用 Xcode 打开 `TodooCard.xcodeproj`。
2. 在 TodooCard target 的 Signing & Capabilities 中选择自己的 Team；如有需要，修改
   `com.todoocard.sender` Bundle Identifier。
3. 选择 iOS 16 或更高版本的真机运行。
4. 打开卡片并确保 iPhone 蓝牙可用，然后选择图片并点“连接并发送”。

CoreBluetooth 的扫描和真实 GATT 写入不能在 iOS Simulator 中验证，发送测试请使用真机。
首次读取 Battery Level 时，iOS 可能显示系统配对提示。

## 核心校验

纯 Swift 核心库可以在不安装完整 Xcode 的环境运行：

```bash
swift run TodooCoreChecks
```

校验包括广播解析、透明背景合成、cover 裁切、颜色 nibble 变换、QuickLZ stored
封装、传输命令及固定方向测试图。固定测试图的结果必须为：

```text
Payload: 218893 bytes
SHA-256: 52c109f0d80d7205c62f4619f2e0621e7df0f3d517507f681f4f05d9e567834d
```

## 持续集成

`.github/workflows/build.yml` 会在推送到 `main`、向 `main` 提交 Pull Request，或手动
触发时运行。工作流使用 GitHub 托管的 macOS runner，先执行核心固定向量校验，再以
iPhoneOS 为目标执行无签名的 Release `xcodebuild`，并按标准
`Payload/TodooCard.app` 结构生成 IPA。成功后可在该次 Actions run 的 Artifacts 区域
直接下载 `TodooCard.ipa`；单文件 Artifact 不会再套一层下载 ZIP。

IPA 本身未签名，可交给 SideStore 使用 Apple Account 重新签名并安装。真机 BLE
交互仍需使用实体 TodooCard/T3 人工验收。

## 目录

```text
TodooCard.xcodeproj/       可直接打开的 iOS 工程
TodooCardApp/              SwiftUI、图片渲染和 CoreBluetooth 传输
Sources/TodooCore/         无 UI 依赖的协议、量化与 Payload 核心
Sources/TodooCoreChecks/   固定向量和协议校验程序
Package.swift              核心库的 Swift Package 入口
```

## 真机联调提示

- 已知广播为 `pairing=open` 时，App 会拒绝写入；先完成系统绑定再重试。
- 只有收到控制特征的最终 `05 08` ACK 才显示“卡片屏幕刷新成功”。
- 如果失败，展开“诊断信息”复制日志；日志与图片都只留在当前设备。
- 当前仓库已验证核心算法和工程文件格式；BLE 时序仍应以实体 TodooCard/T3 做最终验收。
