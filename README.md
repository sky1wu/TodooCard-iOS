# TodooCard iOS

[![Build](https://github.com/sky1wu/TodooCard-iOS/actions/workflows/build.yml/badge.svg)](https://github.com/sky1wu/TodooCard-iOS/actions/workflows/build.yml)

TodooCard/T3 的原生 iOS 图片发送器。图片的解码、裁切、旋转、六色抖动、Payload
构建和 SHA-256 校验全部在手机本地完成，不依赖后端。

## 已实现

- 从照片、文件或剪贴板导入图片；
- App 内的实机外观统一按 62 × 97.5 × 3 mm（宽 × 高 × 厚）、R 角 5.5 mm 的比例展示；
  屏幕左右边框各 5 mm、顶部边框 5.5 mm，机身正反面均呈现细颗粒磨砂质感；
- 从 Bing 每日壁纸接口获取 1080 × 1920 竖屏日图，在 App 中预览后发送；
- 读取「健康」中今天的活动圆环、昨晚睡眠、步数、距离与静息心率，在本机排版成一张
  528 × 792 的健康摘要卡片后预览发送；
- 在 528 × 792 图片区域实时拖动定位、双指缩放，并以 90° 为单位旋转；在机身边框或
  设备外空白区域滑动时，机身会按 3 mm 实际厚度呈现跟手的 3D 倾斜、侧边与轻微光影，
  左右滑动可在正反面之间翻转；
- Floyd–Steinberg、Atkinson、Bayer 4×4 和最近色四种六色量化方式；
- 通过原生效果菜单切换四种量化风格，双指在 1×–4× 间缩放；
- 在六色量化前以 -100%–100% 亮度补偿调整中间调，改善实体屏偏灰偏暗的问题；
- 关闭卡片预览只是回到主页，图片与构图仍然保留，主页的“继续编辑”随时可以回到原处；
- 主页记录最近 12 次成功发送的画面（含分享扩展与快捷指令发出的），轻点回到编辑，
  长按可原样重发或删除单条记录；
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
- 通过“发送今日健康摘要”快捷指令在后台读取健康数据、排版并发送，同样可以配合定时
  自动化每天更新卡片。
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

## 今日健康摘要

在 App 首页点“生成今日健康摘要”，或在卡片预览页的换图菜单中选择“今日健康摘要”。
首次使用时 iOS 会弹出健康数据授权，勾选“活动摘要”“步数”“步行 + 跑步距离”
“爬楼层数”“静息心率”和“睡眠分析”后即可生成。卡片上会排出：

- 日期、星期与生成时间；
- 活动、锻炼、站立三圈圆环，以及各自的完成量、目标和百分比；
- 昨晚的主睡眠段：睡眠评分、总时长、入睡与起床时刻、阶段占比条与图例；
- 今日步数、距离与静息心率（读不到时自动换成爬楼层数）。

排版按 528 × 792 逐像素绘制，再以“纯色（最近色）”量化直接送屏，不做抖动——抖动会
把文字笔画打成彩色噪点。也正因为六色墨水没有灰阶，卡片只用纯黑文字和调色板里的
红、绿、蓝、黄作图：任何浅灰的线和字量化后都会直接变白消失。生成后仍会进入正常的
卡片预览，可以再调整效果或亮度补偿，也可以像其他图片一样重发。

睡眠评分是 TodooCard 在本机估算的：HealthKit 不提供「健康」App 里的那个睡眠评分，
这里按睡眠时长（对照 8 小时）、深度与 REM 占比、清醒时长和醒来次数加权得到 0–100 分，
卡片底部也照实标注。只有 iPhone 或第三方 App 记录睡眠时拿不到阶段，评分只按时长与
连续性计算，卡片会写明这一点。

睡眠数据的取法：向前找 36 小时内的睡眠记录，先只保留睡眠时长最多的那个来源（手表、
手机和第三方 App 会各写一份，叠加会算出二十几个小时），再按中间是否空开 3 小时以上
切成若干段，取其中睡得最久的一段当作昨晚，短于 30 分钟的段落按打盹忽略。

要每天自动更新，把“自动化”里的动作换成 TodooCard 的“发送今日健康摘要”即可，其余
步骤与 Bing 每日壁纸一节相同。后台运行时系统不会弹出健康授权窗口，所以首次必须先在
App 里生成一次并完成授权。

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

## 编辑草稿与最近发送

卡片预览左上角的返回按钮只是回到主页，本次导入的图片、旋转、缩放、定位和显示效果都还留在
App 里；主页顶部会出现“继续编辑”，轻点即可回到刚才的状态，右侧的垃圾桶或预览页换图菜单里的
“关闭当前图片”才会真正丢弃它。草稿保存在内存中，App 被系统回收或重新启动后不再保留。

每次发送成功后，App 会把原图副本（长边缩到 2048 的 JPEG）、当时的构图与效果、六色画面和
Payload 一起存进最近发送记录，主页“最近发送”里按时间倒序展示最新的 12 条，每条约 0.8 MB。
列表里的缩略图用未抖动的原图按当时的构图渲染——六色画面缩到几十点只剩彩色噪点，看不出发的
是哪一张。

轻点缩略图会把原图和当时的旋转、缩放、定位、显示效果、亮度补偿一起装回编辑器，确认或继续
调整后再发送；长按可以选择“重新发送”或“删除记录”，“重新发送”把当初的 Payload 原样再发
一次，不重新解码和抖动，卡片上的画面与那次完全一致。快捷指令里 0%–150% 的抖动强度是编辑器
没有的参数，这类记录回到编辑器时按 100% 呈现。

记录和画面快照一样放在 App Group 容器里，因此分享扩展和快捷指令发出的图片也会出现在这里；
免费 Apple Account 重签名后拿不到 App Group 时，主 App 与分享扩展会各自记录在自己的沙盒里。

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
封装、传输命令、健康摘要的圆环与睡眠评分算法，以及固定方向测试图。固定测试图的结果必须为：

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

## 自动分发（SideStore）

`main` 的每次成功构建都会覆盖固定的 `nightly` release，其中包含两个资产：

- `TodooCard.ipa`：本次构建的未签名安装包
- `source.json`：SideStore 源，`versions[0]` 始终指向这个 IPA

在 SideStore 里添加下面这个源，之后每次推送 `main` 都能直接在 SideStore 中更新：

```text
https://github.com/sky1wu/TodooCard-iOS/releases/download/nightly/source.json
```

版本号规则：SideStore 判断有没有更新只比较 `CFBundleShortVersionString`，`buildVersion`
变化它不认，所以 CI 会把工程里的 `MARKETING_VERSION`（如 `1.3.0`）的补丁位换成
`run_number` 发布，例如 `1.3.24`；`CFBundleVersion` 同样是 `run_number`。主 App 与分享
扩展写入同一组版本号，工作流里有断言校验，注入失效会直接让构建失败。

因此 `build.yml` 的文件名不要重命名——`run_number` 会归零，版本号倒退后 SideStore
就不再提示更新。把工程的 `MARKETING_VERSION` 升到 `1.4.0` 之后，nightly 会继续以
`1.4.<run_number>` 递增，不影响顺序。

源文件由 `distribution/source.template.json` 加 `distribution/make_source.py` 生成，
描述文案、图标、权限说明改模板即可；版本、时间、体积一律由 CI 从实际产物读取。

### 免费 Apple Account 的限制

SideStore 安装时会弹出「App Contains Extensions」，要选 **Keep App Extensions
(Register App ID for Each Extension)**，让分享扩展拿到属于自己的 App ID。主 App 与扩展
各占一个，免费账号每周最多创建 10 个 App ID，注册过的可以复用，后续更新不再消耗额度。
选另外两项都不行：`Remove` 会把扩展剥掉；`Use Main Profile` 用主 App 的描述文件给扩展
签名，App ID 与 bundle ID 对不上，iOS 不会启动它。

即便选对了，**免费账号下分享扩展依然不可用**。扩展申请了 App Group 权限，而免费账号
创建不了 App Group，描述文件里没有这项权限、二进制却申请了它，iOS 会直接拒绝启动——
表现为分享面板里点了毫无反应，且不产生崩溃日志。退一步说，就算它能启动，也读不到存在
App Group 里的「上次使用的设备」，照样发不出去。用付费开发者账号签名则一切正常。

免费账号下要从系统分享发图，用快捷指令代替扩展：

1. 快捷指令 App 新建一个快捷指令，在详情里打开「在共享表单中显示」，接受类型只勾选图像
2. 添加「自动更新 TodooCard」动作，把「图片」参数设为「快捷指令输入」

它跑在主 App 进程里，能读到当前设备，首页画面也会跟着更新，内存上限比扩展宽得多。

同样因为拿不到 App Group，主 App 与分享扩展不共享「当前设备」记忆和首页画面快照，
代码会各自回退到自己的 `UserDefaults` 与沙盒，不会报错。

健康摘要需要 `com.apple.developer.healthkit` 权限。SideStore 用免费账号重签名时若没能
带上这项权限，读取会直接失败并弹出错误，其余功能不受影响；用付费开发者账号签名，或在
Xcode 里为 TodooCard target 打开 HealthKit capability 后自行安装即可正常使用。

## 目录

```text
TodooCard.xcodeproj/       可直接打开的 iOS 工程
TodooCardApp/              SwiftUI、图片渲染和 CoreBluetooth 传输
Sources/TodooCore/         无 UI 依赖的协议、量化与 Payload 核心
Sources/TodooCoreChecks/   固定向量和协议校验程序
distribution/              SideStore 源模板与生成脚本
Package.swift              核心库的 Swift Package 入口
```

## 真机联调提示

- 已知广播为 `pairing=open` 时，App 会拒绝写入；先完成系统绑定再重试。
- 只有收到控制特征的最终 `05 08` ACK 才显示“卡片屏幕刷新成功”。
- 如果失败，展开“诊断信息”复制日志；日志与图片都只留在当前设备。
- 当前仓库已验证核心算法和工程文件格式；BLE 时序仍应以实体 TodooCard/T3 做最终验收。
