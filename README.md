# TodooCard iOS

[![Build](https://github.com/sky1wu/TodooCard-iOS/actions/workflows/build.yml/badge.svg)](https://github.com/sky1wu/TodooCard-iOS/actions/workflows/build.yml)

TodooCard/T3 的原生 iOS 图片发送器。图片的解码、裁切、旋转、六色抖动、Payload
构建和 SHA-256 校验全部在手机本地完成，不依赖后端。

## 已实现

- 从照片、文件或剪贴板导入图片；
- App 内的实机外观统一按 62 × 97.5 mm（宽 × 高）比例展示；
- 从 Bing 每日壁纸接口获取 1080 × 1920 竖屏日图，在 App 中预览后发送；
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
- 发送完成后持续复用当前 GATT 会话；设备主动释放链路时自动恢复，直到用户主动断开或更改设备；
- 记住当前设备，后续发送会直接复用或恢复该设备，并支持按设备 UUID 保存本机别名；
- 应用内诊断日志、电量、Payload 字节数和 SHA-256。
- 通过 App Intents 暴露“自动更新 TodooCard”快捷指令：接收上一步输出的图片，自动生成
  Payload、查找上次成功使用的卡片并发送，全程无需再次点按。
- 通过“发送 Bing 每日壁纸”快捷指令直接完成日图下载、处理与发送，可配合系统的每日
  定时个人自动化自动刷新卡片。
- 提供系统分享扩展，可从照片、文件、浏览器等 App 分享一张图片，直接处理并发送到上次
  成功使用的 TodooCard，无需先把图片导入主 App。

## 从其他 App 直接分享发送

1. 更新安装后先打开 TodooCard，在主 App 中手动选择目标卡片并成功发送一次。
2. 在照片、文件或其他支持图片分享的 App 中选择一张图片，打开系统分享面板。
3. 选择“TodooCard”；分享扩展会自动生成六色内容、恢复默认设备并显示发送进度。
4. 收到卡片最终 ACK 后扩展显示“发送成功”并自动关闭。如果首次没有看到 TodooCard，
   可在分享面板的“更多”中将它加入常用项目。

分享扩展使用默认构图：不旋转、居中、100% 缩放、Floyd–Steinberg、100% 抖动强度和
0% 亮度补偿。需要调整构图或效果时，仍可在主 App 中导入图片后预览发送。主 App 与分享
扩展通过 `group.com.todoocard.sender` App Group 共享默认设备；若修改 Bundle Identifier，
也需要在两个 target 的 Signing & Capabilities 中配置一致的 App Group，并同步修改工程里的
`TODOO_APP_GROUP_IDENTIFIER`。

## Bing 每日壁纸

在 App 首页点“获取 Bing 每日壁纸”，或在卡片预览页的换图菜单中选择“Bing 每日壁纸”。
App 会向 Bing `zh-CN` 归档接口请求当天的 1080 × 1920 竖屏图，校验响应确实为竖屏图片后
载入预览；确认构图与显示效果后，使用底部的发送按钮即可发送到卡片。

若要每天自动刷新：

1. 先在 TodooCard App 中手动选择目标卡片并成功发送一次。
2. 打开系统“快捷指令”App，在“自动化”中创建“特定时间”个人自动化，频率选择“每天”。
3. 添加 TodooCard 的“发送 Bing 每日壁纸”动作；无需添加“获取 URL 内容”等前置动作。
4. 选择“立即运行”；在较旧系统上则关闭“运行前询问”。到点时需保证 iPhone 可联网，
   卡片已开机、蓝牙可用且在附近。

系统触发动作后，TodooCard 会在后台请求日图、生成 Payload、恢复上次成功使用的设备并
发送。只有收到卡片最终的 `05 08` ACK 才算刷新成功；如果卡片当时不在线，本次自动化会
报错，系统不会替 App 无限重试。

## 自定义图片的快捷指令自动更新

首次配置时，先在 App 中手动选择目标卡片并成功发送一次。TodooCard 会在本机记住这台
设备，之后快捷指令只会自动连接该设备；可在“诊断与设备”中确认“自动发送设备”。

1. 打开系统“快捷指令”App，新建快捷指令或个人自动化。
2. 添加一个能输出单张图片的操作，例如“获取文件”“获取 URL 内容”或“查找照片”。
3. 在后面添加 TodooCard 的“自动更新 TodooCard”，将上一步的图片传给“图片”参数。
4. 运行时保持卡片开机并靠近 iPhone。快捷指令会在后台完成图片解码、六色处理、
   安全连接和发送，不会打开或切换到 TodooCard；成功以卡片返回的最终 `05 08` ACK 为准。

动作中可展开配置旋转（0°/90°/180°/270°）、缩放（100%–400%）、水平和垂直焦点
（0–100）、显示效果、抖动强度（0%–150%）与亮度补偿（-100%–100%）。默认值与 App
初始设置一致：不旋转、100% 缩放、焦点居中、Floyd–Steinberg、100% 强度、0% 亮度补偿。

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
