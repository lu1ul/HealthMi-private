# HealthMi GitHub iOS 16.4 模拟器启动测试设计

日期：2026-11-23

## 目标

在 GitHub Actions 托管的 macOS runner 上用 iOS 16.4 iPhone 模拟器构建、安装并启动 HealthMi，以检查 iOS 16 系统上的启动稳定性和基本兼容性。用户设备运行 iOS 16.3，已接受使用最接近的 iOS 16.4 模拟 runtime。

## 范围与限制

- 修改现有手动触发的 `.github/workflows/diagnose-simulator-startup.yml`，保留只读仓库权限和 7 天诊断 artifact。
- 给手动工作流增加 runtime 选择项，默认选 iOS 16.4；保留当前 runner runtime 的选项以便继续做较新 iOS 的启动检查。
- iOS 16.4 模式固定使用 Xcode 16.4，并尝试通过 `xcodebuild -downloadPlatform iOS -buildVersion 16.4` 安装 iOS 16.4 Simulator runtime。
- 明确选择 iOS 16.4 的 iPhone 模拟器；runtime 或设备不可用时让工作流失败，不回退到较新的 iOS。
- 记录模拟器型号、系统 runtime、构建结果、启动结果、等待 20 秒后的进程状态、统一日志和崩溃报告。
- Simulator 不提供与真机相同的 HealthKit 数据与授权环境，也不模拟 TrollStore 签名/安装过程；本检查不能验证实际安装 IPA 的 entitlement 或 iOS 16.3 上的真机行为。

## 方案

1. **在现有手动 workflow 增加 iOS 16.4 模式（采用）**：保留 `macos-15`，选用 runner 上的 Xcode 16.4，按需下载运行时，再用 iPhone 模拟器启动；同时保留原有 runner runtime 模式。优点是不要求用户提供 iPhone 或自有 Mac，且不复制整套诊断步骤；风险是 Apple/Xcode 可能不再向当前 runner 提供旧 runtime，需在真实 workflow 中确认。
2. **新建独立 iOS 16 workflow**：可把 iOS 16 与现有诊断彻底分开，但会重复构建、启动和 artifact 收集流程，增加维护成本。
3. **自托管旧版 Mac/Xcode**：环境更可控，但需要用户维护 Mac runner；也不能保证存在精确的 iOS 16.3 runtime。

采用方案 1，因为它最符合“用 GitHub、不提供真机”的目标。若 runtime 无法下载，保留明确错误与日志，再根据证据决定是否需要自托管 runner。

## 验收

- 工作流实际启动的设备标记为 iPhone，runtime 版本明确为 iOS 16.4。
- iOS 16.4 runtime 不可用时工作流明确失败，不允许选择 iOS 18 或更高版本代替。
- 工程能针对该模拟器构建，应用安装并启动；启动后等待 20 秒，采集到进程状态、统一日志、截图及可用崩溃报告。
- 现有 iOS 18 启动诊断能力仍可在必要时单独运行；本次 iOS 16 工作流保持手动触发，避免每次提交都消耗 macOS runner 用量。

## 资料

- GitHub Actions runner images：macOS 15 镜像清单及预装模拟器 runtime：<https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md>
- GitHub Actions runner images：macOS 14 runner 退役公告：<https://github.com/actions/runner-images/issues/13518>
- GitHub Actions runner images：旧 simulator runtime 可由 `xcodebuild -downloadPlatform` 安装的公告：<https://github.com/actions/runner-images/issues/13570>
- Apple：Xcode 系统要求（Xcode 16.4 支持 iOS 15 及更新系统的 Simulator runtime）：<https://developer.apple.com/xcode/system-requirements/>
- Apple：Xcode 发布记录，Xcode 14.2 对应 iOS 16.2，Xcode 14.3 对应 iOS 16.4：<https://developer.apple.com/documentation/xcode-release-notes>
