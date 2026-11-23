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

用户已补充设备为 iOS 16.3、已越狱并使用 TrollStore 安装。仍缺少具体签名流程、实际安装 IPA 和设备崩溃报告，因此暂时无法区分应用崩溃与 IPA entitlement/设备环境问题。无需交出手机，可在 iPhone 打开“设置 → 隐私与安全性 → 分析与改进 → 分析数据”，找到以 `HealthMi_` 开头的崩溃记录，打开后通过分享按钮存到“文件”并把 `.ips` 发来；如果怀疑是内存压力导致系统终止，也可找同一时间附近的 `JetsamEvent_` 记录。Apple 说明 iOS 15 及以上的 `.ips` 是 JSON 格式崩溃报告。也可提供最终签名后的 IPA，以便检查 Bundle ID、签名、entitlements 和 profile；不要发送证书私钥或密码。

## 官方资料

- [Apple：Xcode 命令行工具参考](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference)：`xcodebuild` 用于构建工程，`simctl` 用于管理模拟器。
- [Apple：与模拟器交互](https://developer.apple.com/library/archive/documentation/IDEs/Conceptual/iOS_Simulator_Guide/InteractingwiththeiOSSimulator/InteractingwiththeiOSSimulator.html)：介绍启动模拟器及通过 `xcrun simctl` 操作模拟器。
- [Apple：查看日志消息](https://developer.apple.com/documentation/os/viewing-log-messages)：可用 `log` 命令读取统一日志。
- [Apple：使用崩溃报告和设备日志诊断问题](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs)：解释崩溃报告与设备控制台日志的用途及获取方法。
- [Apple：获取崩溃报告和诊断日志](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs)：设备上从“分析数据”找到以应用二进制名称开头的崩溃报告并分享。
- [Apple：`.ips` 崩溃报告格式](https://developer.apple.com/documentation/xcode/interpreting-the-json-format-of-a-crash-report)：iOS 15 及以上的 `.ips` 文件包含 JSON 格式的崩溃报告。
- [TrollStore 官方 README](https://github.com/opa334/TrollStore/blob/main/README.md)：支持版本范围及自定义 entitlements 的准备和保留方式。
- [Apple：HealthKit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.healthkit)：`com.apple.developer.healthkit` 是 HealthKit 访问能力的 entitlement。
- [Apple：请求 HealthKit 数据权限](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)：entitlement 与用户针对各类健康数据授予的读写权限是不同环节。
- [GitHub：管理工作流运行](https://docs.github.com/en/actions/how-tos/manage-workflow-runs)：`workflow_dispatch` 工作流可从 Actions 页面、GitHub CLI 或 API 手动启动。

## 首次诊断结果（2026-11-23）

- GitHub Actions 运行：[45135100916](https://github.com/lu1ul/HealthMi-private/actions/runs/45135100916)，使用 Xcode 16.4、iPhone 16 Pro 模拟器、iOS 18.5 runtime。
- 模拟器构建和安装成功；`simctl launch` 返回进程 PID `5114`。等待 20 秒后仍能在模拟器进程列表中找到 `HealthMi`，因此这次没有复现启动闪退。
- 截图显示首次启动的系统通知授权弹窗。应用已运行并推进到通知授权请求；弹窗出现时会暂时遮住应用界面，完成选择后才继续观察 onboarding 页面。
- 没有找到 HealthMi 崩溃报告。统一日志中的 `Missing com.apple.developer.healthkit entitlement` 与本诊断使用的未签名模拟器构建相符；该构建关闭了代码签名，不能据此推断用户自行签名的 IPA 缺少 entitlement。日志里另有系统 `libxpc` assertion，但进程持续运行且没有对应崩溃报告，现有证据不足以将其视为闪退原因。
- 当前结论：源码在 iOS 18.5 模拟器上的首次启动正常；本次没有验证 iOS 16 runtime、用户手工签名后的 IPA、真机 HealthKit 或后台刷新。模拟器通过不能排除真机签名、entitlements、provisioning profile、安装包或 iOS 版本差异。
- artifact 已下载到本地忽略目录 `build/simulator-diagnostics-download/`，包含构建日志、进程快照、系统日志、截图和 metadata；未将这些临时诊断文件加入 Git。

## 后续定位方向

由于模拟器没有复现，且设备为 iOS 16.3/TrollStore，下一步需要对照实际安装的 IPA 和设备崩溃记录。请提供签名时使用的工具，以及闪退时间附近的 `.ips` 报告；报告路径为“设置 → 隐私与安全性 → 分析与改进 → 分析数据”，找到 `HealthMi_` 开头的条目，打开后通过分享按钮存到“文件”。如果没有 HealthMi 报告，可找同一时间附近的 `JetsamEvent_` 记录。也可提供最终签名后的 IPA，以便检查 Bundle ID 和实际 entitlements；不要分享证书私钥、密码或开发者账号凭据。

## iOS 16.3 与 TrollStore 的 entitlement 核查（2026-11-23）

- 用户确认设备为 iOS 16.3，已越狱并通过 TrollStore 安装 IPA。TrollStore 官方 README 的支持范围包含 iOS 16.3。
- TrollStore 官方说明可在安装时保留自定义 entitlements，但要求先把所需 entitlement 写入 IPA 中的二进制。仅在 `project.yml` 声明 `com.apple.developer.healthkit` 不代表它已进入 IPA；Apple 将此 entitlement 定义为应用请求 HealthKit 授权的能力。
- HealthKit 有两层独立授权：应用签名里的 `com.apple.developer.healthkit` entitlement，以及用户在系统 HealthKit 授权页对读/写数据类型的选择。TrollStore 安装成功不等于自动具备前一项，也不等于用户已授予后一项。
- 已检查本仓库此前生成的 `build/HealthMi-unsigned-ipa/HealthMi-unsigned.ipa`：ZIP 内没有 `_CodeSignature` 条目、`embedded.mobileprovision` 或单独的 `.entitlements` 文件，构建工作流也明确关闭了 Xcode 代码签名。因此，项目中的 entitlement 声明没有通过该构建流程写进应用签名。若用户安装的是这份 IPA，HealthKit entitlement 很可能缺失；仍需检查用户实际安装的最终 IPA 才能定论。TrollStore 安装成功本身不能证明 HealthKit 权限存在。
- 缺少 HealthKit entitlement 可解释 HealthKit API 报错或无法请求健康数据权限；本次 iOS 18.5 模拟器也记录到缺少 entitlement 时应用仍保持运行，因此现有证据不能将它直接认定为 iOS 16.3 上启动即闪退的原因。需要检查用户实际安装的 IPA 或 `.ips` 崩溃报告。
- TrollStore 官方 README 还说明，图标缓存重载后，TrollStore 安装的应用可能退回 User 状态并无法启动，需通过 Persistence Helper 重新注册。如果其他 TrollStore 应用也同时无法启动，这一项值得优先核查；如果只有 HealthMi 闪退，则更需要检查该 IPA 和崩溃报告。
- 后续若为 TrollStore 制作 IPA，应在打包前向主程序及需要的嵌入式可执行文件写入所需 entitlements，并检查最终包内签名结果；不能只依赖 `project.yml` 中的 entitlement 声明。
- 本机 Windows 环境的签名检查工具要求 macOS，无法对用户最终签名的 IPA 直接运行 `codesign` 核验；当前拿到的仅为本仓库未签名 IPA。

## 实施记录

- 新增手动工作流与本记录，提交 `b37c4a0`（`ci: add manual simulator startup diagnostics`），推送到个人私有仓库 `lu1ul/HealthMi-private`；没有推送到上游 `origin`。
- 已手动运行 workflow_dispatch 并下载、检查 artifact；模拟器进程存活检查通过，见上方首次诊断结果。
- 补充 Apple 官方 `.ips` 采集说明，供无需提供真机的后续诊断使用。
- 根据用户提供的 iOS 16.3/TrollStore 环境核查 HealthKit entitlement，并检查此前生成的无签名 IPA。

## GitHub iOS 16 模拟器可行性（2026-11-23）

- 用户希望通过 GitHub Actions 使用 iOS 16 iPhone 模拟器测试，并接受 iOS 16.4 作为接近 iOS 16.3 的测试版本。
- 上一次 GitHub simulator 启动检查实际使用 Xcode 16.4、iOS 18.5 runtime；`macos-15` 镜像的预装 runtime 清单没有 iOS 16。需要显式下载并选择 iOS 16.4，不能只设置 iOS 16 deployment target。
- GitHub 托管 `macos-14` runner 已于 2026-11-02 退役，无法再用该 runner 标签固定回旧版 Xcode。
- GitHub Actions `macos-15` 镜像没有预装 iOS 16 runtime。runner-images 公告说明缺少的受支持 runtime 可在 job 中通过 `xcodebuild -downloadPlatform iOS -buildVersion <版本>` 安装；这证明了安装方式，但尚未证明当前 Xcode 能下载 iOS 16.4，需在 workflow 里实测。Xcode 16.4 的系统要求支持 iOS 15 及更新系统的 Simulator runtime，因此计划尝试 iOS 16.4。
- Apple 的公开 Xcode 发布映射从 Xcode 14.2 的 iOS 16.2 跳到 Xcode 14.3 的 iOS 16.4；当前没有确认可用的 iOS 16.3 Simulator runtime。因此本计划以 iOS 16.4 为目标，不声称精确复现 iOS 16.3。
- 模拟器适合检查应用能否在 iOS 16 系统启动以及采集启动崩溃日志；HealthKit 权限、真实健康数据、TrollStore 安装行为仍需真机或最终 IPA/设备日志验证。
- 当前诊断 workflow 仍自动选择任意可用 iPhone runtime；变更设计见 `docs/superpowers/specs/2026-11-23-healthmi-ios16-simulator-test-design.md`，尚待用户审核后实施。

### 资料来源

- [GitHub Actions macOS 15 runner image 清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
- [GitHub Actions macOS 14 runner 退役公告](https://github.com/actions/runner-images/issues/13518)
- [GitHub Actions 旧 Simulator runtime 安装说明](https://github.com/actions/runner-images/issues/13570)
- [Apple Xcode 系统要求](https://developer.apple.com/xcode/system-requirements/)
- [Apple Xcode 发布说明](https://developer.apple.com/documentation/xcode-release-notes)

## iOS 16.4 启动闪退结果（2026-11-23）

- GitHub Actions 运行：`45146100153`；Xcode 16.4；设备为 iPhone 14；runtime 为 `com.apple.CoreSimulator.SimRuntime.iOS-16-4`。构建、安装和 `simctl launch` 命令均返回成功，但等待 20 秒后 HealthMi 进程已退出。
- 崩溃报告 `HealthMi-2026-11-23-092343.ips` 的终止命名空间为 `DYLD`，错误为 `Library missing`：系统找不到 `/System/Library/Frameworks/SwiftData.framework/SwiftData`。引用该库的是应用的 `HealthMi.debug.dylib`。这次没有读取或检查健康数据。
- 根因：旧库迁移类型虽标记为 iOS 17+，其 SwiftData `import` 仍让应用产物在启动时强依赖 SwiftData。可用性检查能阻止 iOS 16 执行迁移代码，但不能避免 dyld 加载强链接框架。
- 修复实现：已在 XcodeGen 配置和当前工程的 Debug/Release 项目设置中对 SwiftData 禁用 Swift 自动链接，并通过 `-weak_framework SwiftData` 弱链接；旧库导入实现及 iOS 17 可用性限制保留。Apple 的 Xcode Build Settings Reference 说明 `SWIFT_SKIP_AUTOLINKING_FRAMEWORKS` 可指定跳过自动链接的 framework；Apple 的 Frameworks and Weak Linking 文档说明 `-weak_framework` 用于弱链接整个 framework。
- 后续验证：修复尚待 GitHub Actions 构建并在 iOS 16.4 重跑启动 workflow；随后在较新的 runtime 启动一次，确认框架可用时应用仍可启动。验证后更新本节。模拟器结果不能取代用户最终 IPA 的真机验证。

### 新增官方资料

- [Apple Xcode Build Settings Reference：`SWIFT_SKIP_AUTOLINKING_FRAMEWORKS`](https://developer.apple.com/documentation/xcode/build-settings-reference)
- [Apple Frameworks and Weak Linking](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPFrameworks/Concepts/WeakLinking.html)

## 弱链接修复后的启动复测（2026-11-23）

- 修复提交：`82fef0f fix: weak link SwiftData for iOS 16`；仅推送到个人私有仓库 `lu1ul/HealthMi-private`，没有推送到上游 `origin`。
- iOS 16.4 复测：[GitHub Actions 运行 `45148900597`](https://github.com/lu1ul/HealthMi-private/actions/runs/45148900597) 成功。Xcode 16.4、iPhone 14、`com.apple.CoreSimulator.SimRuntime.iOS-16-4`；构建、安装和 launch 均通过，20 秒后应用进程仍在，未生成 HealthMi 崩溃报告。构建日志确认包含 `-weak_framework SwiftData`。
- 新系统复测：[GitHub Actions 运行 `45149953346`](https://github.com/lu1ul/HealthMi-private/actions/runs/45149953346) 成功。runner 默认使用 iPhone 16 Pro、iOS 18.5 runtime；构建、安装和 launch 均通过，20 秒后应用进程仍在，未生成 HealthMi 崩溃报告。
- 结论：弱链接配置解决了 iOS 16.4 上 dyld 因缺少 SwiftData.framework 而退出的问题，并保留了较新系统上的正常启动。此次没有用含真实 SwiftData 旧库的数据验证迁移，也没有测试用户签名后的 IPA 或 iOS 16.3 真机。
- 两次 artifact 下载到忽略目录 `build/ios16.4-diagnostics-fixed/` 和 `build/runner-default-diagnostics/`；不纳入 Git。
