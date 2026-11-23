# iPhone 闪退与 iOS 模拟器诊断记录

调查日期：2026-11-23

## 目标

排查自行签名并安装到 iPhone 后启动闪退的问题，并尽量先在不连接真机的情况下判断应用源码是否存在启动崩溃。

## 可行的无真机诊断

本机是 Windows，未安装 Xcode，无法在本机启动 Apple iOS Simulator。已为个人私有仓库添加手动触发的 GitHub Actions 工作流：

- 工作流：`.github/workflows/diagnose-simulator-startup.yml`
- 运行环境：GitHub 托管的 `macos-15` runner 和当前可用的 iPhone Simulator。
- 流程：用 XcodeGen 生成工程，用 `xcodebuild` 构建 iOS Simulator 版，再用 `simctl` 启动应用；等待 20 秒后采集进程快照、统一日志、屏幕截图和可找到的 HealthMi 崩溃报告。
- 结果：诊断文件作为 `HealthMi-simulator-diagnostics` Actions artifact 保存 7 天。工作流仅由 `workflow_dispatch` 手动触发，不会因普通提交自动消耗 macOS runner 用量。

该流程在 macOS runner 的模拟器中重建当前源码，不会运行用户签名的那份 IPA。若模拟器也闪退，崩溃日志可帮助定位应用初始化、Core Data、旧 SwiftData 导入或系统 API 调用的问题。若模拟器运行正常，只能说明该模拟器环境下的当前源码通过了启动检查，不能证明用户 IPA 的签名、entitlements、provisioning profile、Bundle ID 与真机 iOS 版本都正确。

## 重点观察的启动路径

`HealthMi/App/HealthMiApp.swift` 在主界面展示前异步准备 Core Data；iOS 17 及以上还会尝试读取并导入旧 SwiftData 数据；准备成功后请求通知授权并安排后台刷新。模拟器新安装会走这段初始化逻辑，因此应优先查看启动时的统一日志和崩溃报告。

HealthKit 在模拟器中的可用性和真实设备不同；模拟器启动检查不能替代真实 HealthKit 授权、写入验证，也不验证后台刷新是否由 iOS 在真机上调度。

## 触发及查看方式

在 GitHub 仓库 `lu1ul/HealthMi-private` 的 **Actions → Diagnose simulator startup → Run workflow** 手动运行。完成后下载 `HealthMi-simulator-diagnostics` artifact：

- `metadata.txt`：模拟器、Bundle ID、启动命令退出码和等待后进程状态。
- `launch.txt`：安装后启动命令的输出。
- `unified-log.txt`：HealthMi 与 SpringBoard 相关日志。
- `processes.txt`：等待后的模拟器进程列表。
- `simulator-screen.png`：等待后的模拟器屏幕截图。
- `crash-reports/`：runner 能找到的 HealthMi 崩溃报告。

## 尚需的信息

当前尚未获得 iPhone 型号、iOS 版本、用户最终签名方式、实际安装 IPA 的 Bundle ID，也没有 iPhone 的崩溃报告。因此现阶段无法判断是源码启动崩溃还是签名/系统环境差异；先运行模拟器诊断，若模拟器不复现，再根据结果只索取进一步区分问题所需的信息。不要发送证书私钥或密码。

## 官方资料

- [Apple：Xcode 命令行工具参考](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference)：`xcodebuild` 用于构建工程，`simctl` 用于管理模拟器。
- [Apple：与模拟器交互](https://developer.apple.com/library/archive/documentation/IDEs/Conceptual/iOS_Simulator_Guide/InteractingwiththeiOSSimulator/InteractingwiththeiOSSimulator.html)：介绍启动模拟器及通过 `xcrun simctl` 操作模拟器。
- [Apple：查看日志消息](https://developer.apple.com/documentation/os/viewing-log-messages)：可用 `log` 命令读取统一日志。
- [Apple：使用崩溃报告和设备日志诊断问题](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs)：解释崩溃报告与设备控制台日志的用途及获取方法。
- [GitHub：管理工作流运行](https://docs.github.com/en/actions/how-tos/manage-workflow-runs)：`workflow_dispatch` 工作流可从 Actions 页面、GitHub CLI 或 API 手动启动。

## 实施记录

- 已新增手动模拟器诊断工作流和本记录文档；尚待本地 YAML/差异检查、提交、推送到个人私有仓库并运行 workflow_dispatch。
