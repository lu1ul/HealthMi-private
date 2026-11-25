# HealthMi 项目代码全面审查与 HealthKit 权限故障定位

> 审查日期：2026-11-23
> 源码审查基线：`82fef0f`（`fix: weak link SwiftData for iOS 16`；后续提交仅更新文档）。
> 结论类型：静态代码审查 + 本地 IPA 包结构检查 + 2026-11-24 GitHub Actions 构建/模拟器诊断复核；初始审查阶段没有修改业务源码或运行构建，后续只验证了工作流和产物。

## 当前结论（2026-11-24 真机验收后）

本报告早期章节保留了问题定位过程和当时的证据边界；以下内容是目前应采用的最终状态：

- **HealthKit 接入已在 iOS 16.3 真机确认成功。** 用户用 GitHub Actions run `45340198351` 生成的 TrollStore IPA 安装后，点击权限按钮可以触发 HealthKit 授权，HealthMi 可以出现在健康 App 的来源中。
- **数据同步已在 iOS 16.3 真机确认成功。** 小米账号登录成功，数据可以从小米云端同步并写入 Apple 健康。
- **Keychain `-34018` 已确认是旧 TrollStore entitlement 打包缺口，并已修复。** 新产物同时含 `com.apple.developer.healthkit = true` 与 `keychain-access-groups = [TROLLTROLL.*, com.apple.token]`，真机登录已通过。
- **iOS 16 最低版本适配的主流程已通过真机验收。** Core Data 存储、HealthKit 写入和 TrollStore 安装路径没有阻止 iOS 16.3 运行。
- **当前未解决的问题是快捷指令动作运行时返回“无法与帮助程序通信”，随后又出现“因为 App 意外退出”。** 最新 run `45522292408` 的 IPA 已静态确认包含 Intent metadata、HealthKit/TrollStore entitlements；路线二也已把 Intent 主体缩减为运行记录读写、轻量排队和可选 BGTask 提交，但用户仍反馈失败。由此不能再把“完整同步太慢”作为首要解释。项目没有 App Intents extension target，Intent 类型编译在主 App target；`openAppWhenRun = false` 本身不足以证明它运行在独立帮助进程。当前优先排查冷启动时的 BGTask handler 注册时机、排队后立即触发的后台同步、App Intents 宿主/旧动作缓存。没有设备 `.ips` 前，无法把进程退出归因到其中任何一个。详见第 9.18 节。

## 一、结论摘要

### 对“是 TrollStore 安装问题还是项目代码问题”的判断

**现有证据更指向本项目的 IPA 构建/签名配置，而不是 iOS 16.3 或 TrollStore 本身故障。**如果 iPhone 上装的确实是仓库工作流产出的 `HealthMi-unsigned.ipa`，HealthKit entitlement 很可能没有随应用可执行文件进入最终包；这是当前最直接、证据最强的原因。

项目源代码中确实声明了 `com.apple.developer.healthkit`，也确实调用了 HealthKit 授权 API；但设备 IPA 工作流明确使用 `CODE_SIGNING_ALLOWED=NO` 和 `CODE_SIGNING_REQUIRED=NO`，并且本地 IPA 包内没有 `_CodeSignature` 目录或 provisioning profile。Xcode 工程中的 entitlement 声明不会因为它存在于 `project.yml` 或 `.entitlements` 文件中，就自动成为未签名可执行文件的 HealthKit 权限。

HealthKit 调用失败时，仪表盘按钮通过 `try?` 丢弃错误，所以即使系统 API 返回 entitlement、配置或 HealthKit 错误，界面也没有任何提示。这是可以从当前代码直接确认的 UI 诊断缺陷。

**本地候选 IPA 存在且已检查；仍未取得的是手机实际安装的最终 IPA。**当前工作区有仓库生成的未签名候选包（见第三节），但没有你最后交给 TrollStore 安装的处理后 IPA，也没有手机导出的最终可执行文件或 entitlement 清单。因此可以分析仓库候选包，尚不能据此断定安装后的二进制是否由安装前处理补入了 entitlement。

因此当前定责为：

| 环节 | 判断 | 证据强度 |
|---|---|---|
| HealthKit 请求源码 | 调用了授权 API，权限类型和用途说明基本齐全 | 高 |
| iOS 16.3 API 可用性 | `requestAuthorization` 早于 iOS 16 已提供；没有发现最低版本导致该调用不可用 | 高 |
| 本仓库 IPA 工作流 | 关闭代码签名，工作流产物不承载工程声明的 HealthKit entitlement | 高 |
| HealthKit 按钮表现 | `try?` 隐藏失败，可能呈现为“点了没反应” | 高 |
| 重复请求不弹窗 | 所有目标类型此前已授权或拒绝时，系统可不再显示表单 | 高 |
| 授权来源列表 | 完成授权请求后，即使拒绝，应用也应出现在“健康”App 的“来源”页 | 高 |
| 用户最终安装包 | 尚未取得，无法验证是否被重签或补入 entitlement | 未知 |
| TrollStore/iOS 16.3 | TrollStore 官方支持 iOS 16.3；官方说明 entitlement 需由 `ldid` 预签后由 TrollStore 保留 | 高 |

**综合判断：**若用户安装的是本项目当前的未签名构建产物，首要问题在项目的构建/打包流程；TrollStore 能把应用安装并启动，只证明该安装流程能够运行该 App，不证明 HealthKit entitlement 已存在。当前也没有足够证据把故障归因于 TrollStore 的缺陷。

**本轮新增的数据正确性结论：**除权限问题外，Swift 端还有一个独立的高优先级问题：每日活动解析会用 `calories` key 的总卡路里覆盖 `steps` key 中的活动卡路里，之后把结果写入 HealthKit 的 `activeEnergyBurned`。仓库内 Python 实现和测试把这两者分开处理，Swift 测试却断言总卡路里就是活动卡路里。该问题会造成 HealthKit 活动能量数据失真，但不能解释权限弹窗缺失。

继续审查又确认：日活动样本按日期去重后不会更新当天后来增加的累计值；强制回填普通心率时还可能误删 workout 关联心率。它们同样是独立于 HealthKit entitlement 的数据一致性问题。

本轮又确认：HealthKit 批量写入前只过滤数据库中已有的 external UUID，没有在本次批次内部去重；分页游标直接插入 JSON 字符串，特殊字符可能破坏请求；CSV 导出接口的 `days` 参数目前未使用。这些属于同步完整性和接口契约问题，不解释授权表单缺失。

补充检查登录与工作流后还发现：网页登录 Cookie 域名采用子串匹配；更换凭据或退出登录不会中止正在执行的同步；同步中可修改区域和回填天数，导致同一轮任务的输入配置变化；模拟器诊断工作流的启动失败可能仍显示绿色，且 CI 没有执行 XCTest。

回填窗口另有一个按日期计数的边界问题：界面选 N 天时，当前起点计算会包含 N+1 个日历日期，现有窗口测试只验证相差天数而没有验证实际日期数。

解析层还把缺失的 `item.time` 默认为 Unix 时间戳 0；若心率、体重或日活动记录缺少时间字段，可能生成并写入 1970 年附近的 HealthKit 样本，而不是拒绝不完整记录。

但“没有弹窗”本身不能证明 entitlement 缺失：Apple 说明，如果这组数据类型之前都已被用户处理过，后续 `requestAuthorization` 可以直接返回而不再显示表单。另一方面，Apple 也说明完成授权请求后，应用会出现在“健康”App 的“来源”页，即使用户拒绝所有权限。因而还要确认手机上检查的是“健康”App 的来源列表、当前安装包的 Bundle ID，以及实际安装二进制的签名 entitlement；仅凭 TrollStore 能安装和启动，无法证明这些权限配置正确。[Apple：`requestAuthorization`](https://developer.apple.com/documentation/healthkit/hkhealthstore/requestauthorization%28toshare%3Aread%3Acompletion%3A%29)

## 二、HealthKit 权限按钮的实际调用链

1. [DashboardView.swift](HealthMi/App/DashboardView.swift) 的“请求健康权限”按钮创建 `Task`，调用 `model.requestHealthKit()`。
2. [AppModel.swift](HealthMi/App/AppModel.swift) 检查 `HKHealthStore.isHealthDataAvailable()`，然后调用 HealthKitManager。
3. [HealthKitManager.swift](HealthMi/Health/HealthKitManager.swift) 用 `requestAuthorization(toShare:read:)` 请求步数、距离、卡路里、心率、睡眠、血氧、呼吸率、HRV、体重、运动等读写类型。
4. `DashboardView` 用 `try?` 丢弃所有抛出的错误，用户看不到失败原因。浏览器登录回调在 [OnboardingView.swift](HealthMi/App/OnboardingView.swift) 也使用 `try?`；手动输入 token 的路径则会捕获并显示错误。
5. `AppModel.healthKitAuthorized` 只检查“步数写入权限”的 `authorizationStatus`，它不能代表所有读写类型，也不能读取用户是否允许某项**读取**权限。HealthKit 对读取授权有隐私保护，应用不能用这个状态字段准确复原每个读取开关。

### 源码中已有的正确配置

- [HealthMi.entitlements](HealthMi/Support/HealthMi.entitlements) 声明了 `com.apple.developer.healthkit = true`。
- [project.yml](project.yml) 的 HealthMi target 配置了同一个 entitlement，最低系统版本为 iOS 16.0。
- [Info.plist](HealthMi/Support/Info.plist) 同时包含 `NSHealthShareUsageDescription` 与 `NSHealthUpdateUsageDescription`。
- `HealthKitManager` 的调用使用 HealthKit 提供的授权请求 API；没有发现遗漏“点击后才请求”的明显源码错误。

这些配置说明源码作者意图正确，但不能证明某个 IPA 的签名 entitlement 已正确生成。`HealthKitManager.requestAuthorization()` 的注释写着“系统会展示授权弹窗”，这个说法不适用于已对所请求类型做过决定的重复请求；此时系统可以不展示表单。代码没有调用 `getRequestStatusForAuthorization` 来观察系统是否预期显示表单，也没有把按钮调用结果呈现给用户。[Apple：`requestAuthorization`](https://developer.apple.com/documentation/healthkit/hkhealthstore/requestauthorization%28toshare%3Aread%3Acompletion%3A%29)

## 三、IPA 与构建工作流证据

### 工作流行为

[build-unsigned-ipa.yml](.github/workflows/build-unsigned-ipa.yml) 中：

- 以 Release 配置构建 iOS 真机应用。
- 显式设置 `CODE_SIGNING_ALLOWED=NO`、`CODE_SIGNING_REQUIRED=NO`、空签名身份。
- 打包步骤还断言 `HealthMi.app/_CodeSignature` 不存在，再将 `.app` 直接装入 IPA。

这正是一个未签名 IPA 工作流。工程的 `.entitlements` 声明只有在签名过程中才会被合并进可执行文件的签名 entitlement；未签名打包流程不会把 Xcode 工程文件自动转换成 TrollStore 可识别的自定义 entitlement。

### 本机候选 IPA

当前工作区检查到两个仓库工作流产物，均是未签名 IPA：

| 路径 | SHA-256 |
|---|---|
| `build/HealthMi-unsigned-ipa-after-ios16-fix/HealthMi-unsigned-ipa/HealthMi-unsigned.ipa` | `88198DBF1A140E88553CC9A6B2B7584127456888EF23264F5DA80E6027083716` |
| `build/HealthMi-unsigned-ipa/HealthMi-unsigned.ipa` | `E64C6982D0E7CE13F4E0EA6CDE619F6C246CEAEE2A5CB82245803612CC6D1021` |

ZIP 清单能看到 `Payload/HealthMi.app/HealthMi` 与 `Info.plist`，没有 `_CodeSignature`、`embedded.mobileprovision` 或独立 `.entitlements` 文件；同时，工作流源码确认关闭了代码签名。第一份正是先前记录、用于 iOS 16 修复后生成的候选 IPA。

2026-11-24 对用户指定的本地文件 `D:/aiproject/HealthMi/build/HealthMi-unsigned-ipa-after-ios16-fix/HealthMi-unsigned-ipa/HealthMi-unsigned.ipa` 复核：SHA-256 为 `88198DBF1A140E88553CC9A6B2B7584127456888EF23264F5DA80E6027083716`；Bundle ID 为 `com.healthmi.HealthMi`，Share/Update 用途说明均存在；Mach-O 主程序没有 `LC_CODE_SIGNATURE`。所以该 IPA 本身可供分析，且是未签名候选包；不能把“没有手机最终安装包”说成“没有 IPA 文件”。

**重要边界：**TrollStore 支持安装带任意 entitlement 的应用，因此“可以安装并启动”不等于“安装后一定有 HealthKit entitlement”，也不能单独证明安装器有问题。需要核对实际安装的 IPA/应用主程序中是否存在 `com.apple.developer.healthkit = true`。当前没有用户安装用的最终 IPA，也没有设备侧 entitlement 清单；所以根因判断是“更可能是构建包问题”，不是对设备/TrollStore 的最终定责。[TrollStore 官方项目说明](https://github.com/opa334/TrollStore/blob/main/README.md)

TrollStore 官方说明的 entitlement 使用流程要求先通过 `ldid` 将自定义 entitlement 伪签进应用主程序，再由 TrollStore 安装并保留。仓库的 IPA 工作流没有运行 `ldid`，也没有执行 Xcode 代码签名；因此如果安装包未经其它处理直接交给 TrollStore，这条构建链路没有为 HealthKit 准备 entitlement。[TrollStore 官方 README](https://github.com/opa334/TrollStore/blob/main/README.md)

### 2026-11-24 GitHub Actions 重建与产物复核

本次按“先修复工作流，再分别验证 iOS 16.4 模拟器和设备目标 IPA”的顺序执行，目标仓库为私有仓库 `lu1ul/HealthMi-private`，运行代码版本为本地提交 `68b5cce`（`ci: fail simulator workflow on launch errors`）。本次只推送到该私有仓库，没有推送到原始仓库 `ShawnDiego/HealthMi`。

- **iOS 16.4 模拟器诊断：**工作流运行 `45303564969` 成功，Xcode 版本为 `16.4 (16F6)`，runtime 为 `com.apple.CoreSimulator.SimRuntime.iOS-16-4`，设备为 `iPhone 14`。安装退出码为 `0`，启动退出码为 `0`，启动等待 20 秒后进程仍存在；没有上传崩溃报告。截图显示应用已进入前台并展示 iOS 通知权限请求。
- **模拟器测试边界：**该工作流生成并验证的是 `HealthMi.app`，不是可装到真机的 IPA。模拟器运行没有执行 HealthKit 真机授权流程，也不能证明 iOS 16.3 设备上的 HealthKit entitlement 或“健康”App 来源登记正常；通知权限提示也没有被自动点击。
- **设备目标 IPA：**工作流运行 `45303591637` 成功，构建、打包和 artifact 上传均成功。下载到本地的产物为 `D:/aiproject/HealthMi/build/github-run-45303591637/HealthMi-unsigned.ipa`，SHA-256 为 `48A595AACF66D26829D8CE41109EC59FC81115098C933E6D9A16B81C16D004A2`。
- **IPA 包结构：**ZIP 包包含 `Payload/HealthMi.app/HealthMi`、`Info.plist` 和 App Intents 元数据；Bundle ID 为 `com.healthmi.HealthMi`，`CFBundleExecutable` 为 `HealthMi`，`NSHealthShareUsageDescription` 与 `NSHealthUpdateUsageDescription` 均存在。
- **签名与 entitlement 复核：**该 IPA 没有 `_CodeSignature`、`embedded.mobileprovision` 或独立 `.entitlements` 文件；主程序是 64 位 arm64 Mach-O，未发现 `LC_CODE_SIGNATURE`。因此这次构建证明“设备目标 IPA 可以成功生成”，但没有解决“HealthKit entitlement 是否进入最终可执行文件”的关键问题。若该文件直接交给 TrollStore，仍需先确认安装前的 entitlement 处理方式；最可靠的最终证据仍是安装后主程序的 entitlement 清单。
- **与之前本地 IPA 的比较：**本次 GitHub 产物与之前的 iOS 16 修复版 IPA 在主程序大小、Bundle ID、Info.plist 和主要资源上基本一致；GitHub 构建的 App Intents 生成元数据存在正常的构建差异。这没有改变未签名主程序的结论。

因此，本轮的实际结论是：**GitHub iOS 16.4 模拟器验证通过；设备 IPA 构建通过并已完成包级分析；IPA 仍是未签名候选包，HealthKit 权限故障不能仅凭“构建成功”视为已修复。**

## 四、最能解释当前症状的因果链

```text
工作流关闭 Xcode 签名
        ↓
工程中的 HealthKit entitlement 没有签进 IPA 主程序
        ↓
点击按钮确实调用 HealthKit requestAuthorization
        ↓
HealthKit 请求因 entitlement/签名配置而失败，或无法完成正常登记
        ↓
DashboardView 的 try? 吞掉错误
        ↓
用户看到无弹窗、无错误；系统健康数据访问页也没有 HealthMi
```

这条链与用户描述的“点击没有反应、系统设置没有 HealthMi”相符；其中**最需要实际安装包验证的节点**是安装完成后的主程序有没有 `com.apple.developer.healthkit = true`。

## 五、项目代码审查发现

以下按修复影响统一排序：P1 优先处理会阻断核心功能或造成数据丢失、错写的缺陷；P2 处理数据准确性、账号隔离、同步可靠性与诊断问题；P3 处理较低频边界、日志和文档问题。原有 H/S/CI/DOC 标识保留，Python 项目新增 PY1–PY7 标识。以下问题均为静态审查发现，尚未通过本轮运行测试确认；本节不代表它们都造成当前 HealthKit 弹窗故障。

### P1｜阻断核心功能或可能造成数据丢失、错写

#### H1｜P1：设备 IPA 工作流没有交付 HealthKit entitlement

**位置：** `.github/workflows/build-unsigned-ipa.yml:47-70`、`project.yml:42-46`、`HealthMi/Support/HealthMi.entitlements:4-6`

这是当前权限故障最可能的根因。XcodeGen 配置有 entitlement，但唯一设备 IPA 工作流明确关闭签名。工作流产物不能被视为已把 HealthKit entitlement 写入主程序签名的可安装包；工程中的 `.entitlements` 只是构建输入，不能单凭文件存在推断最终可执行文件的签名包含它。Apple 将 `com.apple.developer.healthkit` 定义为应用可请求健康数据访问的 entitlement。[Apple：HealthKit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.healthkit)

**建议：**分清两种目标包并各自验证：

- Apple 开发者签名包：使用启用了 HealthKit capability 的 App ID 与匹配的 profile/code signing，检查最终签名 entitlement。
- TrollStore 包：按官方说明先用 `ldid` 将所需 entitlement 伪签进主程序，再由 TrollStore 安装；安装后再次核对最终 entitlement。不要只检查 XcodeGen 的 `.entitlements` 源文件。

#### H2｜P1：仪表盘静默吞掉授权请求错误

**位置：** `HealthMi/App/DashboardView.swift:53-56`；网页登录回调见 `HealthMi/App/OnboardingView.swift:119-122`

用户点按钮后确实启动异步请求，但 `try?` 将 API 错误直接丢弃。这会把“按钮未工作”“entitlement 缺失”“HealthKit 错误”等不同状态都表现成无响应。

**建议：**由 `AppModel` 保存明确的权限请求状态/错误，界面展示可读原因和重试入口；保留系统是否展示授权 UI 作为实际验证点。同步里的错误捕获不能替代这个按钮自身的错误反馈。

**重复请求行为：**Apple 文档说明，若用户此前已对请求中的全部类型作出决定，系统可以不再显示授权表单；完成过授权请求后，应用仍会列在“健康”App 的“来源”页，即使用户拒绝所有权限。因此必须区分“此前已处理、系统正常不再弹窗”和“当前请求没有成功到达 HealthKit”。当前代码没有调用 `getRequestStatusForAuthorization`，而 `try?` 又隐藏调用错误。排查时应在“健康”App 的“来源”页确认当前应用，并核对实际 Bundle ID 与正在检查的构建一致。[Apple：授权请求行为](https://developer.apple.com/documentation/healthkit/hkhealthstore/requestauthorization%28toshare%3Aread%3Acompletion%3A%29)；[Apple：请求状态 API](https://developer.apple.com/documentation/healthkit/hkhealthstore/getrequeststatusforauthorization%28toshare%3Acompletion%3A%29)

#### S1｜P1：缺少或不完整的 API 分页字段会被当作成功并推进游标

**位置：** `HealthMi/MiFitness/MiAPIClient.swift:181-189, 210-217, 239-247`、`HealthMi/Sync/SyncEngine.swift:105-120, 253`

响应顶层 `code` 解析通过后，如果 `result` 丢失或类型不符，客户端返回空字典；分页解析又会把缺失/类型错误的 `data_list` 或 `sport_records` 当作空页，把缺失/错误的 `has_more` 默认成 `false`，并在 `has_more=true` 但 `next_key` 缺失时直接结束。同步引擎随后会把这次不完整响应当成功并写入新的 `highWater = Date()`。若服务端协议变化、短暂返回错误结构或响应被截断，可能只导入部分数据却推进游标，后续增量不再覆盖全部缺失区间。

**建议：**严格校验 `result` 及必需的列表/分页字段；不合法响应抛 `invalidResponse`，不得更新游标。

#### S2｜P1：数字字符串解析失败可能被误判为成功码，极端值还可能触发运行时错误

**位置：** `HealthMi/MiFitness/MiModels.swift:147-150`；调用点 `MiAPIClient.swift:185-187`

字符串转数字失败时使用 `Int(Double(s) ?? 0)`，会把无效字符串变成 `0`。在 API `code` 字段中，`"not-a-number"` 这类异常响应可能因此被解释为成功码 0，再走到“空 result”路径。该转换还会先把整数文本转成 `Double`，再向零截断为 `Int`，例如小数字符串会被静默取整；如果解析出的浮点值超出 `Int` 可表示范围，转换可能触发运行时错误。此 helper 也用于解析来自网络的时间戳、步数、心率和睡眠编码，因此不只是 API code 的协议校验风险。Apple 的 Swift 文档说明，浮点转整数会截去小数，输入超出目标整数范围时运行时可能报错。

**建议：**整数文本直接用可失败的 `Int(s)` 解析；若协议确实允许小数，先检查数值为 finite 且位于目标整数范围，再按明确规则转换。无效数值应返回 `nil` 并让协议校验失败，不要静默变成 0。

#### S11｜P1：强制回填先删除旧 HealthKit 样本，后写入失败会造成数据缺口

**位置：** `HealthMi/Sync/SyncEngine.swift:90-107, 233-249`

`forceBackfill` 对普通健康样本先按 external UUID 删除 HealthKit 中范围内的旧记录，再调用 `writer.save` 写入新记录。删除成功但新样本保存失败时，旧记录已丢失，本次同步会报错且游标不会前进。运动回填同样先删除旧 workout 和关联心率，再调用 `saveWorkout`。删除和保存不是本项目可包成单个事务的操作，因此当前顺序存在可见的数据丢失窗口。

**建议：**为回填设计可恢复的两阶段替换：先确认完整的新数据和可写入状态，再替换旧样本；若 HealthKit 接口要求先删后写，需保留足以恢复旧样本的内容或记录补偿任务。重点覆盖“删除成功、保存失败”和 workout 已保存但关联心率写入失败。

#### S15｜P1：总卡路里被写成 HealthKit 活动能量

**位置：** `HealthMi/MiFitness/MiParser.swift:18, 26, 36, 40-54`；写入映射见 `HealthMi/Health/TypeMapper.swift:34-39`；对照 `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/adapters/mi_fitness_cloud.py:463-496` 和 `tools/mi-fitness-mcp-cn/tests/test_mi_fitness_cloud.py:40-76`。

Swift 端先把 `steps` key 的 `calories` 累加到 `kcalFromSteps`，再把 `calories` key 返回的总量覆盖到同一字段，最终赋给 `MiDailyActivity.activeKcal`。`TypeMapper.dailyActivitySamples` 将其作为 `HKQuantityType(.activeEnergyBurned)` 写入健康数据。Python 实现则把 `steps` 中的 calories 保存为 `active_kcal`，把独立 `calories` key 认作包含基础代谢的 `total_kcal`，并由测试验证两者分别为 3 和 12。Swift 的现有测试使用 100+50 与 210，并断言 `activeKcal == 210`，与 Python 端的已测试语义相反。

**影响：**如果这两个 API key 的字段语义与仓库 Python 实现及测试一致，App 会把每日总消耗而非活动消耗写入 Apple 健康的活动能量，通常会显著高估活动热量。现有 Swift 测试会让该错误持续通过。

**建议：**活动能量只从 `steps` 数据的活动 calories 计算；若产品需要总消耗，应在模型中单独保留，不映射到 `activeEnergyBurned`。先用脱敏的真实 API 响应或稳定样例确认字段语义，再修正 Swift 与 Python 的共同夹具和测试期望。此问题是代码/数据映射问题，不是 TrollStore 权限弹窗问题。

#### S19｜P1：增量同步会永久跳过已写入日期的更新值

**位置：** `HealthMi/Health/TypeMapper.swift:12-39`；`HealthMi/Sync/SyncEngine.swift:64-75, 85-118`；`HealthMi/Health/HealthWriter.swift:15-37`。

步数、距离和活动能量的样本覆盖整日，external UUID 只由日期组成（例如 `mi_fitness_steps_2026-11-23`）。增量同步会重叠查询前一天以获取迟到数据，但正常分支只按 external UUID 过滤“已经存在”的样本，不比较数值，也不替换原样本。因此同一天第一次同步写入部分累计值后，后续同步即使重新取到更大的步数/距离/热量，也会因 UUID 相同而跳过。按时间戳生成 UUID 的其它指标同样不会自动更新同一 ID 的修正值。

**影响：**在当天中途触发同步后，HealthKit 中当天的总步数、距离和活动能量会停留在首次写入时的部分值；上游迟到或修正的相同记录也可能一直旧到用户手动强制回填。一天重叠窗口只能重新取数，不能修复去重策略。

**建议：**对会变化的聚合/修正数据实施按 external UUID 的内容比较和安全替换，或明确延迟写入当天未完成的聚合数据并仍处理迟到修正。添加同一天连续两次返回不同计数的回归场景，确认最终 HealthKit 样本更新为新值。

#### PY1｜P1：按用户隔离不完整，切换账号可能覆盖记录和共享游标

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/storage/__init__.py:224-229, 294-307, 422-435, 462-474, 507-518`；适配器 ID 生成见 `adapters/mi_fitness_cloud.py:498-504, 700-709`

`sync_state` 的唯一键只有 `data_type`，没有 `user_id`；多类记录以日期/秒级时间生成全局 `id`，部分 upsert 在 `ON CONFLICT(id)` 时更新指标但不更新 `user_id`。若一个 SQLite 库先后服务不同小米账号，游标会共享，碰撞记录也可能由一个账号的值覆盖而仍保留另一个账号的 user_id。

**建议：**为同步游标加入用户作用域，并让记录主键/唯一约束及 upsert 策略一致地按用户隔离。

### P2｜影响数据准确性、隔离性、同步可靠性或诊断

#### H4｜P2：HealthKit 读取错误被折叠成空数据

**位置：** `HealthMi/Health/HealthKitReader.swift:25-55, 82-115`

摘要与趋势查询多处用 `try?`，发生授权、entitlement 或查询错误时就返回 `nil` / 空数组。界面显示“—”或“暂无趋势数据”，难以区分确实无数据与查询失败。

**建议：**保留查询错误并在界面区分“无样本”“未授权/不可用”“查询失败”。这对 HealthKit 排查很重要，但应排在补上 entitlement 和按钮错误反馈之后。

#### H3｜P2：授权状态指示器只检查步数写入权限

**位置：** `HealthMi/App/AppModel.swift:130-139`

`healthKitAuthorized` 通过 `HKQuantityType(.stepCount)` 的 `authorizationStatus` 得出一个全局“已授权/未授权”。这个状态只能说明该类型的写入状态，不能说明其它写入类型或读取权限状态；尤其不能用它判断用户是否允许读取既有健康数据。

**影响：**界面可能显示“未授权”，即使用户已允许部分类型；也可能给“读取权限”造成误导。它不是导致系统弹窗缺失的直接原因，但会干扰定位。

**建议：**UI 将“请求是否成功调用”“写入样本是否成功”与“读取是否返回数据”分开表达；不要声称能从 HealthKit 查询到用户的读取授权开关。

#### S24｜P2：网页登录用子串匹配信任 Cookie 域名

**位置：** `HealthMi/MiFitness/MiWebLogin.swift:20-31`；WebView 导航见 `HealthMi/App/MiWebLoginView.swift:124-125, 173-181, 209-216`；相关测试 `HealthMiTests/MiWebLoginTests.swift:45-70`。

Cookie 提取条件是 `$0.domain.contains("account.xiaomi.com")`，而不是检查规范化后的域名是否为 `account.xiaomi.com` 或其合法子域。WebView 控制器把 `target=_blank` 也加载到同一个 WebView，未限制目标主机；如果浏览到 `account.xiaomi.com.attacker.example` 一类域名，该域也满足子串检查。该页面可设置同名 Cookie；`getAllCookies()` 会把多域名 Cookie 一并交给提取器，而代码会按返回顺序选取同名项。当前测试仅排除了完全不相关的 `example.com`，没有覆盖域名后缀伪装和同名 Cookie 冲突。

**影响：**登录流程可能捕获并提交非小米账号域的伪造 `userId` / `passToken`，造成登录失败或凭据来源混淆。此问题需要用户被引导到或主动打开伪装域名才会触发；本轮没有验证实际 WebView 导航路径。

**建议：**规范化 Cookie domain（去掉前导点、转小写），按域名标签边界做精确匹配；若仅需要登录主机，就只接受 `account.xiaomi.com`。同时限制 WebView 的外部导航，并增加 `account.xiaomi.com.attacker.example`、`notaccount.xiaomi.com` 及重复同名 Cookie 的测试。

#### S3｜P2：切换小米账号不会清理 HealthKit 中旧账号记录，external UUID 又不含账号

**位置：** `HealthMi/Health/TypeMapper.swift:19-35, 43-54, 190`、`HealthMi/MiFitness/MiModels.swift:33, 75, 81, 119`、`HealthMi/App/AppModel.swift:107-117`

应用退出账号时会清除本地游标/压力/日志，但不会删除 HealthKit 中旧样本。若之后换账号，步数 UUID 按日期生成，心率/血氧/体重 UUID 按整秒时间生成，运动 UUID 按 workoutId 生成，均没有账号命名空间。新账号若同一时间有记录，会被旧 UUID 去重；不同账号的值也可能继续并存在 HealthKit。

**建议：**决定账号切换语义；至少让应用生成的 external UUID 稳定包含账号作用域，或提供清楚的数据保留/清理行为。注意不能自动删除用户自己或其它来源写入的 HealthKit 数据。

#### S29｜P2：缺失的记录时间被转换成 1970 年样本

**位置：** `HealthMi/MiFitness/MiParser.swift:31-42, 130-145, 231-239, 293-301`。

`recordDate(of:)` 和 `calendarDay(of:)` 都用 `item.time ?? 0` 填补缺失时间；静息心率解析也使用 `payload.date_time ?? item.time ?? 0`。因此 API 返回记录缺少时间字段时，心率、体重或日活动的其它有效数值不会被跳过，而可能被解析成 Unix epoch 附近的时间。`TypeMapper` 对心率/体重样本没有时间合理性校验，日活动则会按区域把 1970-01-01 映射为整日样本。若错误时间来自 `MiJSON.int` 对非法数字文本的兜底 0，也会出现相同结果（另见 S2）。

**影响：**不完整 API 响应可能污染 Apple 健康的历史时间线；HealthKit 写入成功后，正常 external UUID 去重还会让错误时间样本长期保留。

**建议：**让时间解析返回可失败结果；缺少必要时间字段的记录应跳过并计入解析告警，或使该页失败且不推进同步游标。增加缺少 `item.time`、非法时间文本、合法 Unix epoch 附近数据的边界测试。

#### S4｜P2：区域时区固定 UTC 偏移，日期计算不统一

**位置：** `HealthMi/MiFitness/MiRegion.swift:18-29`、`HealthMi/Sync/SyncEngine.swift:64-75, 148-165`、`HealthMi/Health/TypeMapper.swift:246-258`、`HealthMi/Health/HealthKitReader.swift:51-53`；Python 对照 `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/adapters/mi_fitness_cloud.py:271-283` 和 `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/config.py:19-25`

欧洲固定 UTC+1、美国固定 UTC−8，无法涵盖夏令时与多时区；API 窗口、按区域映射日样本、HealthKit 读回趋势又混用设备当前 Calendar。跨时区或 DST 日期附近可能错日、窗口重叠或趋势错位。`TypeMapper.calendar` 还是静态缓存，启动后切换地区时不会重建。另一个跨实现差异是 Python adapter 只对 `cn` 使用 UTC+8，所有非 `cn` 区域都用 UTC；Swift 则对 `ru/de/us` 使用 UTC+3/+1/−8。相同非中国区日期字符串会生成不同的 API epoch 查询窗口。Python 的 `config.timezone` 目前只由 `get_profile` 回传，没有参与窗口换算。仅凭仓库代码无法确定哪套边界符合小米服务端的地区约定，但两套实现的输出不等价。

**建议：**使用带 DST 规则的 IANA 时区，明确统一日界线的业务时区；让 Swift 与 Python 按相同规则计算请求窗口；区域变化时重建相关 Calendar。先用包含 `zone_offset`、`zone_name` 和日边界附近样本的脱敏记录确认服务端约定。

#### S7｜P2：运动写入在关联心率失败时可能留下“已保存但不完整”的 workout

**位置：** `HealthMi/Health/HealthWriter.swift:47-90`、`HealthMi/Sync/SyncEngine.swift:228-253`

代码先 `finishWorkout()` 保存 workout，之后才通过 `store.add` 加入平均/最大心率。若后续加入失败，方法抛错；重试时 `existingExternalIDs` 已能找到该 workout，正常增量会跳过，不会自动补写缺失关联心率。

**建议：**把运动和关联样本的恢复语义设计为可重试/可修复，或者将不完整状态记录下来供重试；用模拟 `store.add` 失败的测试覆盖。

#### S12｜P2：强制回填不会清理上游已消失的数据

**位置：** `HealthMi/Sync/SyncEngine.swift:88-118, 228-253`

普通类型只在 `fetchAndMap` 返回的 `groups` 上执行回填删除。如果指定类型本次返回空集合，循环体不执行，HealthKit 中不再出现在小米响应里的旧记录仍会保留。运动回填也只对新响应里仍存在的 `draft` 删除和重写旧 workout，不会清理范围内已从云端消失的 workout。因此“全量重拉并重写”在空响应或已删除记录场景下实际只会重写当前仍返回的记录。

**建议：**先确认 API 响应完整、分页结束且解析成功，再根据新旧 external UUID 集合差异做范围清理；协议错误或分页不完整时保留旧样本。

#### S20｜P2：强制回填心率会删除 workout 关联心率样本

**位置：** `HealthMi/Sync/SyncEngine.swift:89-105, 233-249`；`HealthMi/Health/HealthWriter.swift:61-91`；`HealthMi/Health/TypeMapper.swift:178-195`。

仅当强制回填 `.heartRate` 本次确实从 API 取到并映射出非空心率样本组时，代码才会执行这一删除。此时 `existingExternalIDs` 会查询该 HealthKit 心率类型下范围内所有带 external UUID 的样本，并删除范围内的所有 ID。普通同步心率使用 `mi_fitness_hr_*` / `mi_fitness_resting_hr_*`，但 `saveWorkout` 也会把平均/最大心率作为同一 HealthKit `.heartRate` 类型样本写入，ID 为 `mi_fitness_workout_*_avg_hr` / `_max_hr`。因此回填这组普通心率时也会删除 workout 关联心率，只重写普通心率记录。只有之后 workout 类型也被启用且成功重新取到该运动记录时，关联数据才会恢复；用户关闭运动同步、该类型同步失败或上游不再返回 workout 时，关联数据会丢失。若心率映射结果为空，则这段代码不会进入删除循环。

**建议：**强制回填只删除本次数据类型实际拥有的 ID 命名空间，或在统一的回填事务/协调流程中保护 workout 关联样本。覆盖“回填心率但关闭运动同步”和“心率成功、运动回填失败”两种场景。

#### S21｜P2：HealthKit 写入批次内部没有按 external UUID 去重

**位置：** `HealthMi/MiFitness/MiAPIClient.swift:210-214, 239-243`；`HealthMi/Sync/SyncEngine.swift:89-118`；`HealthMi/Health/HealthWriter.swift:41-44`；external UUID 生成见 `HealthMi/Health/TypeMapper.swift:43-71, 90-108`。

客户端把各分页结果直接追加到数组；同步时查询的是写入前 HealthKit 中已有的 ID，然后用这个固定集合过滤 `group.objects`。过滤过程中不会把本批已通过的 ID 加入集合，因此同一批次出现的相同 ID 都会被送入 `writer.save`。另外，普通心率、血氧和体重类 ID 将时间戳截到整数秒；两个同类型样本若落在同一秒，也会得到相同 ID。代码没有在保存前去除这些批内重复项。

**影响：**当服务端分页重叠、重复返回记录，或同一秒有多个同类型测量时，本次同步会把多个具有相同 external UUID 的对象交给 HealthKit 保存。HealthKit 对这类批次的实际接受结果未在本轮运行验证；即使写入成功，下一次查询也只能看到“该 ID 已存在”，无法凭现有逻辑识别并修复这次重复或冲突。

**建议：**保存前按 external UUID 对批次建索引并定义冲突策略（保留最新记录、合并或报协议错误）；对秒级 ID 增加稳定的事件标识或更高精度组成。为分页重复及同一秒冲突分别增加回归案例。

#### S17｜P2：睡眠总时长的区间边界与按日归属未定义

**位置：** `HealthMi/Health/HealthKitReader.swift:27-44, 50-84, 126-145, 168-182`。

`summary(days:)` 从当前时刻向前回退日历天数，并把查询返回的每个睡眠样本完整时长相加；当前 `predicateForSamples` 调用没有启用 `strictStartDate` / `strictEndDate`，因此与所选区间相交的样本也会返回，跨越起始边界的样本会把区间外时长一并计入总量。趋势查询则把每段睡眠的完整分钟数归到 `sample.startDate` 所在日，没有按午夜切分；例如跨午夜的一段睡眠会全部落在开始日。是否应按“入睡夜晚”归属需要产品定义，但当前数据不能解释为严格的日历日睡眠分钟数。查询还会直接相加所有来源的睡眠样本，没有检查来源或重叠区间；若不同来源记录了重叠睡眠，也会重复累计。

**影响：**最近 N 天摘要可能包含边界之外的睡眠；趋势图可能把整晚显示在入睡日；多来源重叠记录可能高估睡眠时长。实际误差取决于设备样本的时间范围和来源。

**建议：**明确采用日历日切分还是睡眠夜归属；对查询区间边界裁剪样本时长，并按选定策略处理跨午夜区间。多来源样本需要有明确的来源优先级或重叠去重规则。Apple 将 `strictStartDate` / `strictEndDate` 定义为要求样本起止时间落在目标区间内的选项；当前调用未传这些严格选项，因此应按可能跨界返回的样本处理。

#### S14｜P2：未识别的睡眠阶段被默认伪装成浅睡

**位置：** `HealthMi/MiFitness/MiParser.swift:113-123`

当前只明确映射 state `2` 至 `5`，其余值（包括缺失或未来新增编码）全部返回 `.light`，再由 `TypeMapper` 写成 HealthKit `asleepCore`。这会把未知或异常记录伪造成有效浅睡样本，影响睡眠分期与统计。

**建议：**让解析结果能表达未知或无效状态；未知分期应跳过或保留原始编码并记录诊断，避免默认映射为浅睡。用已确认的小米编码样例覆盖所有支持的状态值。

#### S16｜P2：Swift App 与 Python 工具的睡眠阶段编码不一致

**位置：** `HealthMi/MiFitness/MiParser.swift:113-123`；`tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/adapters/mi_fitness_cloud.py:418-429`；Swift 测试见 `HealthMiTests/MiParserTests.swift:38-64`。

Swift App 映射为 `2=deep, 3=light, 4=REM, 5=awake`；Python MCP 工具映射为 `1=deep, 2/3=light, 4=awake, 5=REM`。Swift 源码注释称其映射已按实际数据修正，Python 映射为旧版本，但仓库没有保留可复核的原始响应夹具或协议文档来独立判定哪套映射符合小米当前协议。Swift 测试只覆盖 `2/4/5`，没有覆盖 `3`、未知编码或与 Python 共享的样例；Python 测试也未覆盖该映射。

**影响：**两个工具面对相同睡眠记录会输出不同阶段；若旧 Python 映射仍被下游使用，REM、深睡和清醒时长会错分。该差异不影响 HealthKit 授权弹窗，也不能仅凭代码断言 Swift 当前映射错误。

**建议：**保存脱敏的真实云端睡眠记录作为黄金夹具，明确每个 state 的协议语义，并让 Swift 与 Python 共用同一组预期映射。未知值应保留为未知或跳过，不能默认伪装成浅睡（参见 S14）。

#### S13｜P2：全局同步被步数写入权限统一拦截

**位置：** `HealthMi/App/AppModel.swift:124-138, 184-194`

`healthKitAuthorized` 只表示 `stepCount` 的 HealthKit 写入状态。`syncAll` 在同步任何数据类型前都要求它为 `true`，否则直接返回。用户即使只启用其它可写类型，也会因步数被拒绝而被全局阻止；压力数据本身存 Core Data、不写 HealthKit，却同样无法同步。

**建议：**按启用的数据类型分别处理 HealthKit 写入失败；HealthKit 之外的数据（至少压力）不应依赖步数授权。界面状态应拆分为授权请求状态、步数写入状态和各类型的实际写入结果，避免一个状态代表所有权限。

#### S5｜P2：API 同步过程中 token 失效时连接状态可能仍显示正常

**位置：** `HealthMi/MiFitness/MiAPIClient.swift:41-45`、`HealthMi/App/AppModel.swift:296-313, 324-328`

API 客户端识别 `code=70016`，但 `AppModel.isAuthError` 只识别登录阶段的 `MiLoginError.loginRejected`。已经连接后在数据接口遇到 `MiAPIError.api(code:70016)`，会记一类数据同步失败，却不一定设置 `authNeedsRefresh` 或更新 `connected` 状态。

**建议：**同步错误统一映射登录/令牌失效状态，在界面明确要求刷新凭据；避免重复重试永久失效的 token。

#### S25｜P2：退出或更换小米账号不会取消正在运行的同步

**位置：** `HealthMi/App/AppModel.swift:95-119, 184-263`；`HealthMi/App/DashboardView.swift:63-67, 224-227`。

`syncAll` 只保存一个跨实例互斥标志，没有保留可供 `disconnect` 取消的同步任务句柄；`disconnect` 会清凭据、把 `engine` 设为 `nil` 并清除游标/压力/日志，但不会取消已进入网络请求或 HealthKit 写入的任务。仪表盘的“更新小米凭据”和“退出登录”按钮在同步期间仍可用。若同步在 `await engine?.sync(...)` 处暂停，切换凭据可以替换 `self.engine`；当前类型的旧引擎调用仍可完成，后续类型则可能改用新引擎，而两者写入同一 HealthKit 库和同一 Core Data 游标。

**影响：**单次同步可能混合旧账号与新账号的数据；退出后，仍在途的任务也可能继续写 HealthKit，并把刚清空的游标、压力或日志重新写回。该情况依赖用户在同步过程中执行退出/换号，但代码没有互斥或取消保护。

**建议：**同步期间禁用换号/退出操作，或在执行账号变更前取消并等待当前任务结束；每轮同步捕获不可变的 engine、账号标识和配置快照，在保存游标前验证账号代次未变化。覆盖“网络请求期间退出”和“两个数据类型之间切换账号”场景。

#### S26｜P2：同一轮同步可以使用不同的区域或回填天数

**位置：** `HealthMi/App/AppModel.swift:209-214`；`HealthMi/App/DashboardView.swift:47-50, 122-129`；`HealthMi/MiFitness/MiAPIClient.swift:24-27, 94-103`；`HealthMi/Sync/SyncEngine.swift:64-82`。

数据类型列表在 `syncAll` 开始时会快照，但 `backfillDays` 在每个类型开始时重新读取；设置页的回填范围和区域 Picker 在同步时没有禁用。与此同时，`MiAPIClient.baseURL` 每次请求都会读取当前 `MiRegion.current`。因此长时间同步中修改区域或回填范围后，同一轮任务的后续数据类型可以换到另一区域/时间范围；时区/日界线也可能与前面已完成的类型不同。

**建议：**在同步开始时一次性捕获区域、时区、回填天数、类型集合及账号会话，并将快照传入该轮所有请求；或者同步期间禁用相关设置控件。日志记录实际使用的配置，便于复现跨区域和部分回填问题。

#### S6｜P2：取消请求时重试与分页等待可能继续运行

**位置：** `HealthMi/MiFitness/MiAPIClient.swift:105-127, 222, 251`；`HealthMi/Sync/BackgroundSync.swift:23-37`；`HealthMi/App/SyncIntent.swift:26-31`

退避和分页间隔使用 `try? Task.sleep`，取消错误会被忽略；网络错误又被统一包装为可重试错误。快捷指令超时或系统后台任务过期时，任务可能继续进入下一轮请求，而不是及时结束。

**建议：**对 `CancellationError` 立即向上传播；分页循环前检查取消状态；后台任务确保完成回调仅由一个路径负责。

#### S18｜P2：快捷指令/后台任务取消与完成路径没有统一收敛

**位置：** `HealthMi/App/SyncIntent.swift:20-34`；`HealthMi/Sync/BackgroundSync.swift:25-37`；`HealthMi/App/AppModel.swift:209-212, 270-278`；重试等待见 `HealthMi/MiFitness/MiAPIClient.swift:105-127, 218-251`。

快捷指令创建了独立 `Task` 执行 `syncAll`，只由 55 秒 watchdog 主动取消；代码没有把 `perform()` 调用方的取消显式传递给该任务。`syncAll` 检查到取消后只 `break` 数据类型循环，随后仍更新状态、刷新 HealthKit 摘要并可能发送通知。API 重试和分页等待用 `try? Task.sleep`，取消产生的错误被吞掉：重试等待取消后仍可能尝试下一次请求，分页等待取消后会直接进入下一页。

后台刷新有两个完成入口：`expirationHandler` 异步安排取消并立即调用 `setTaskCompleted(false)`；同步任务正常返回后也调用 `setTaskCompleted(success:)`。两条路径没有共享的一次性完成门闩；若过期与同步结束并发，存在重复报告完成的竞态。取消分支在 `guard !Task.isCancelled else { return }` 处提前返回，也不会清空静态 `syncTask` 引用。

**影响：**系统已过期或快捷指令调用方已取消后，仍可能继续做重试等待和 HealthKit 读取；后台任务可能出现重复完成报告或保留过期任务引用。此问题不解释授权表单/来源列表缺失。

**建议：**让取消沿结构化任务传播；重试等待遇到取消立即抛出，循环每个请求边界都检查取消；`syncAll` 取消后尽早返回，不再运行摘要查询；后台任务用单一完成状态协调过期与正常完成，并通过 `defer` 清除任务引用。用“取消与同步完成同时发生”的测试验证完成回调只走一次。

#### S28｜P2：回填“最近 N 天”实际覆盖 N+1 个日历日期

**位置：** `HealthMi/Sync/SyncEngine.swift:64-82, 140-165`；界面选项见 `HealthMi/App/DashboardView.swift:122-129`；现有窗口测试 `HealthMiTests/SyncEngineTests.swift:26-33`。

首次同步和强制回填都先用 `Calendar.current.date(byAdding: .day, value: -backfillDays, to: now)` 计算起点，之后 API 查询再把起点向下取到区域日历的 00:00，并将今天的日终作为结束。以“7 天”为例，当前会从 7 天前那一天的 00:00 拉到今天，覆盖 7 天前至今天共 8 个日历日期；30 天和 90 天同理多一天。现有测试只检查起点距 `now` 约 N 天，不检查窗口实际包含的日期数量。

**影响：**UI 和同步历史的“7/30/90 天”范围比用户选择多一个日历日，额外下载并在强制回填时重写该日的数据。若产品定义本来就是“今天加上前 N 天”，则应把标签改成该含义；当前界面称“最近 N 天”，更自然的解释是总共 N 个日期。

**建议：**明确采用“最近 N 个日历日（含今天）”还是“今天加前 N 天”；前者通常从今天的日历起点向前减 `N-1` 天。测试应固定时区与日期，断言查询起止日期及覆盖日期数，而非仅断言时间差。

#### PY4｜P2：CLI/MCP 诊断会暴露凭据标识和原始健康记录

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/main.py:32, 70, 154-156`；`server.py:476-489`；探测脚本 `probe_mifitness.py:34-40, 243, 260-264`、`probe_apnea.py:7-9, 88-101, 143-160`

命令行支持 `--pass-token`，不同操作系统可能允许同用户进程或诊断工具读取进程命令行；setup/doctor/探测程序会打印完整 user ID。即使呼吸探测脚本从 Keychain 加载时先遮盖 ID，随后仍会打印完整值。MCP 的 `get_profile` 直接返回完整 `user_id`；两个探测脚本还会把原始运动/睡眠健康记录 JSON 输出到终端，复制诊断日志时可能一并泄露个人标识与健康信息。

**建议：**避免把 passToken 放在命令行参数中；默认脱敏 user ID；探测程序输出样例时删去账号、精确时间和健康数据，或明确提供脱敏模式。

#### PY2｜P2：指标序列只查每日活动，`weight_kg` 等身体指标会返回空

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/services/query_service.py:54-82`

`get_metric_series()` 始终从 `get_daily_summaries()` 取数据；每日摘要不含体重，因此调用指标 `weight_kg` 得不到身体测量记录。

**建议：**按指标路由到对应存储查询；为每日活动、身体测量、心率、血氧等分别定义指标类型。

#### PY3｜P2：周/月聚合的未知模式默认按 sum

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/services/query_service.py:104-115, 137-148`

`aggregation == "latest"` 未单独处理，会落入 `else: sum(values)`，导致请求最新值却得到总和；拼错聚合名称也不会报错。

**建议：**显式支持 `latest`，不支持的聚合值应校验报错。

#### CI1｜P2：模拟器诊断失败后工作流仍可能判为成功

**位置：** `.github/workflows/diagnose-simulator-startup.yml:131-133, 207-219`。

“Install, launch, and collect diagnostics” 步骤设置了 `continue-on-error: true`，目的是让失败后仍上传诊断 artifact。下一步在 `steps.diagnose.outcome == 'failure'` 时只输出 `echo "::error::..."`，shell 仍以退出码 0 结束；因此诊断步骤失败可能只留下红色注释，整个 job 仍为成功状态。GitHub 文档说明 `continue-on-error` 会让失败步骤不导致 job 失败；`::error::` 是注释/日志命令，不是失败退出码。

**建议：**保留 artifact 上传，再在最后的结果步骤显式 `exit 1`，或用 job-level `continue-on-error`/结果汇总结构确保“诊断失败但日志已上传”仍以失败结论结束。

#### CI2｜P2：现有 CI 工作流没有运行 XCTest

**位置：** `.github/workflows/build-unsigned-ipa.yml:28-88`；`.github/workflows/diagnose-simulator-startup.yml:116-220`。

IPA 工作流只对 generic iOS 目标执行 `xcodebuild build`；模拟器工作流也只 build、install、launch 并采集日志。仓库虽有 `HealthMiTests` 测试 target，但两条工作流都没有 `xcodebuild test`。目前因此没有自动回归门槛覆盖解析、映射、同步游标、Core Data 导入等现有单元测试。

**建议：**在可用的 iOS Simulator workflow 中运行 `xcodebuild test`，并保留启动诊断工作流；同时将 iOS 17 默认 SwiftData store 升级、HealthKit 写入/删除失败、分页错误、账号切换、取消和回填数据一致性纳入测试计划。当前静态审查不运行测试，因此这些建议没有在本轮执行。

**测试覆盖观察：**现有 `SyncEngineTests` 只验证窗口计算，且没有发现 S28 的 N+1 日问题；没有测试 API 分页字段校验、缺失记录时间、HealthKit 写入/回填或账号切换竞态。`TypeMapperTests` 的日活动期望值与 `MiParserTests` 一起断言 `activeKcal == 210`，会让 S15 的总卡路里映射问题通过；睡眠分期测试没有覆盖状态 3 和未知状态；`MiCryptoTests.testDataStringOrder` 只用普通游标 `abc`，没有覆盖 S22 的 JSON 转义边界。

#### DOC1｜P2：README 将后台刷新描述成每小时执行

**位置：** `README.md:12, 116`；调度代码 `HealthMi/Sync/BackgroundSync.swift:39-47`；Apple 的 [`BGTaskRequest.earliestBeginDate`](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate) 文档。

代码把 `earliestBeginDate` 设为一小时后，然后提交 `BGAppRefreshTaskRequest`。该值表示系统不应在此时间前启动任务，并不构成每小时准时运行的承诺；任务运行时间由 iOS 后台调度器决定。README 的“每小时周期刷新”容易被理解为固定周期，特别是首次安装或用户划掉 App 后更容易误判为同步失效。

**建议：**将文案改为“系统可能在一小时后或更晚安排后台刷新，时间不保证；需要确定性同步时使用 App 内手动同步或快捷指令”。

### P3｜较低频边界、记录与文档问题

#### S8｜P3：HealthKit 分页遇到同一开始时间超过页长时可能不前进

**位置：** `HealthMi/Health/HealthWriter.swift:17-39, 130-157`

分页锚点仅取最后一个样本的 `startDate`，下一页查询包含该边界（`>= anchor`）。若超过 1000 条样本共享相同开始时间，锚点可能不变，查询重复相同一页。

**建议：**使用可严格推进的分页游标/查询机制；至少为大量同时间戳样本增加终止保护与回归测试。

#### S22｜P3：服务端分页游标未进行 JSON 字符串转义

**位置：** `HealthMi/MiFitness/MiAPIClient.swift:93-103, 213-223, 242-252`。

`dataString` 手工插入 `key` 和 `nextKey` 到 JSON 字符串。`key` 来自代码中的固定名称，但 `nextKey` 来自服务端响应；如果游标含有引号、反斜杠或控制字符，下一页请求体会变成无效 JSON。仓库未包含小米分页游标格式的协议定义，因此该风险是否会由当前服务端真实触发仍需脱敏游标样例确认。

**建议：**用 `JSONSerialization` 或 `JSONEncoder` 编码请求对象，避免对服务端游标做字符串插值；保留当前已验证的字段和值语义并用含特殊字符的游标夹具验证。

#### PY7｜P3：本地健康数据 SQLite 未见数据库加密配置

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/storage/__init__.py:270-280`

工具把健康数据存入普通 SQLite 连接，源码中未见 SQLCipher 或额外的数据库加密层。若数据库落在多人可读设备或被备份同步的位置，应评估静态数据保护和文件权限。

#### S9｜P3：凭据先写入 Keychain、后验证登录

**位置：** `HealthMi/App/AppModel.swift:95-105`

`saveCredentials` 先保存 userId/passToken，再连接小米 API。若验证失败，凭据仍会留在 Keychain；下次启动 `bootstrap()` 只要读到凭据就会将 `isConfigured` 设为 true。

**建议：**先验证临时凭据，再保存成功的会话；或登录失败后回滚新写入值。

#### S10｜P3：用户关闭所有同步类型后重启会恢复全选

**位置：** `HealthMi/App/AppModel.swift:48-50, 71-92`

`loadEnabledTypes()` 只有在持久化集合非空时才覆盖默认值。用户有意清空全部类别时，空数组会被解释为“没有设置过”，重启后恢复全部类型。

**建议：**区分“键不存在”与“键存在但数组为空”。

#### S23｜P3：CSV 导出 `days` 参数没有参与筛选

**位置：** `HealthMi/App/DataExporter.swift:7-28`；当前调用 `HealthMi/App/DashboardView.swift` 的 CSV 导出按钮。

`exportCSV(days:trends:stressRecords:)` 接收 `days`，但函数体没有读取它；实际行数完全由 `trends` 决定。当前界面传入的趋势本身是最近 7 天，所以现有按钮路径看起来一致；若后续调用方传入 30 天或更长的 `trends`，参数名称会让调用者误以为函数会限制为所选天数。

**建议：**若筛选由调用方负责，删除未使用的 `days` 参数并在调用点明确传入已筛选数据；若函数负责范围，则用 `days` 对趋势和压力记录统一裁剪。

#### S27｜P3：单类同步部分写入失败时，错误日志固定记录零条

**位置：** `HealthMi/App/AppModel.swift:236-260`；分组保存见 `HealthMi/Sync/SyncEngine.swift:85-120, 228-253`。

一个同步类型可能包含多个 HealthKit sample group，或逐条保存多个 workout。前面组/运动已成功写入后，后续操作抛错会进入 `AppModel` 的统一 catch；该分支不读取已经完成的工作，固定以 `fetched: 0, added: 0` 写失败日志。压力路径也可能先完成 `replaceRange`，之后保存游标失败，再写一条零计数失败日志。

**影响：**HealthKit 或 Core Data 中可能已有部分新数据，但同步历史显示“拉取 0、新增 0”，使用户无法区分纯失败和部分成功；重试虽通常可由 external UUID 或范围替换收敛，但日志不能反映真实结果。

**建议：**让同步结果/错误携带已获取和已提交计数，并显式标记部分成功；或把每类数据的写入阶段和日志状态设计成可恢复的步骤。覆盖“前一组成功、后一组失败”和“数据已保存、游标保存失败”。

#### PY6｜P3：部分同步失败后仍打印“同步完成”

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/main.py:125-140`

逐数据类型失败会打印错误，但流程随后总会打印“同步完成！”，没有整体失败状态或非零退出码。

**建议：**汇总成功/失败数据类型；存在部分失败时明确标示部分完成，并返回可供自动化检测的失败状态。

#### PY5｜P3：MCP SQLite 连接缺少显式关闭接口

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/storage/__init__.py:31-42, 269-283`；`tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/server.py:649-662`

`Database` 延迟创建并将 SQLite connection 长期缓存在实例字段中，但没有 `close()` 方法；`with self._get_connection()` 仅管理事务，不关闭该缓存连接。MCP server 退出时 `finally` 关闭 adapter，却没有关闭数据库连接。通常单进程 CLI 退出后由进程回收资源，所以暂未发现会影响正常短命令的故障；若数据库对象在嵌入式/测试进程中反复创建或服务关闭后继续驻留，连接与文件锁会持续占用到对象/进程结束。

**建议：**为 `Database` 增加显式生命周期关闭接口，并在 server/CLI teardown 中调用；测试也应关闭数据库对象，避免测试进程残留连接。

#### DOC2｜P3：README 声称存在的 `MiRegionTests` 不在测试 target 中

**位置：** `README.md:123-125`；测试文件清单 `HealthMiTests/`。

README 的测试说明称 `MiRegionTests` 验证区域配置，但仓库当前没有 `MiRegionTests.swift` 或相应测试类。现有测试 target 中也没有区域时区、日界线或区域切换的测试。

**建议：**补上对应测试并将其纳入 CI，或移除 README 中对该测试的描述，避免读者误以为区域配置已被自动验证。

### 未定级的审查备注

以下内容用于记录历史问题状态和尚未完成的验证，不是本轮确认的独立代码缺陷，因此不纳入 P1–P3 排序。

#### D. 既有问题记录的时效性

仓库中未跟踪的 `项目分析-优先关注问题.md` 标记分析基线为 `5930b70`，早于当前源码审查基线 `82fef0f`。其中“压力部分回填会清空全部历史”“压力保存失败吞错”等条目在当前代码已处理：`SyncEngine.syncStress` 返回实际查询范围，`StressStore.replaceRange` 只替换该范围，Core Data 保存错误会向上抛出。旧文档适合作为历史记录，不能直接当作当前结论。

当前工作区有此未跟踪文件，本次没有修改、暂存或提交它。

#### E. iOS 17 SwiftData 到 Core Data 迁移核对

从历史提交 `565cd71^` 读取到的 iOS 17 版本使用 `Schema([SyncState.self, StressRecord.self, SyncLogEntry.self])` 与默认 `ModelConfiguration(schema:)` 打开 SwiftData；当前 `LegacySwiftDataImporter.importIfNeeded` 使用相同模型集合和同一默认配置。模型字段、SwiftData unique 属性也与当前迁移器读取的 v1 schema 对应。因此静态代码未发现“新旧版本使用了不同默认 SwiftData store 配置”的明显错误。

当前单元测试通过内存 SwiftData 容器调用 `importRecords` 验证记录字段、幂等标记和旧库保留，但没有用**历史版本实际落盘的默认 SwiftData store**执行启动升级测试。这个仍是验证缺口，不能仅凭内存导入测试断言真实升级路径已在 iOS 17 用户数据上成功。

## 六、修复与验证建议

### 跨类别修复顺序

1. **先解决当前 HealthKit 权限阻断：**核对手机实际安装包的 entitlement，并让授权请求错误可见（H1、H2）。
2. **再保护同步数据完整性：**严格校验 API 响应，禁止不完整分页推进游标；修正数值解析、回填失败数据缺口、活动能量映射和当天累计值更新（S1、S2、S11、S15、S19）。
3. **隔离独立 Python 工具的数据：**让同步游标和健康记录按用户隔离（PY1）。
4. **完成 P2 项：**依照上方 P2 顺序处理数据准确性、账号与请求生命周期、HealthKit 诊断、CI 和 README 问题。
5. **最后处理 P3 项：**依照上方 P3 顺序修复较低频边界、日志和文档问题。


### HealthKit 处理步骤 1：确认最终安装包的 entitlement

最省力的定责材料是**你实际交给 TrollStore 安装的那一个 IPA**，而不是 Xcode 工程文件或当前 unsigned IPA。也可以在有 macOS/Xcode 的环境对主程序执行：

```sh
unzip -q HealthMi-installed.ipa -d /tmp/healthmi-check
codesign -d --entitlements :- /tmp/healthmi-check/Payload/HealthMi.app/HealthMi
codesign -dv --verbose=4 /tmp/healthmi-check/Payload/HealthMi.app/HealthMi
plutil -p /tmp/healthmi-check/Payload/HealthMi.app/Info.plist
```

重点看：

- 主程序的签名 entitlement 中是否有 `com.apple.developer.healthkit` 且值为 `true`。
- 包内 `Info.plist` 是否仍含 `NSHealthShareUsageDescription` 和 `NSHealthUpdateUsageDescription`。
- 最终 Bundle ID 是否是 `com.healthmi.HealthMi`，并与实际安装的 App 一致。
- 查验的 IPA 是否就是手机当前安装的那一份，避免检查错构建版本。
- 在 iPhone 的“健康”App →“来源”中确认 HealthMi 是否出现；系统若以前已对全部类型作过选择，重复调用可能不弹窗，但完成过请求后应用仍应列在来源页。
- 记录授权请求状态 API 的结果及 `requestAuthorization` 的错误，不要只凭按钮无弹窗判断请求未执行。

若该 IPA entitlement 缺失，问题已锁定在构建/签名/安装包处理流程；若 entitlement 存在，再收集 iPhone 上的 HealthKit/HealthMi 统一日志和安装包来源，排查 bundle/签名状态或 TrollStore 对这份包的具体处理。

### HealthKit 处理步骤 2：修复打包方式

1. 选择本次分发目标：Apple 开发者签名包或 TrollStore 包。
2. Apple 开发者签名包需确保 App ID、profile 和签名中的 HealthKit capability 配套。
3. TrollStore 包需按其安装流程准备主可执行文件的 HealthKit entitlement，并在安装后再次检查实际 entitlement；不能假设它会从 XcodeGen 的 `.entitlements` 源文件推断权限。
4. 修改 workflow 的 artifact 命名，明确区分 `unsigned` 与 `trollstore/healthkit-enabled`，避免把“可以安装”误解成“具备 HealthKit entitlement”。

### HealthKit 处理步骤 3：给授权请求加可见错误

1. 移除权限按钮及网页登录回调中的静默 `try?`。
2. 将错误显示在 HealthKit 状态行附近，并写入诊断日志。
3. 请求 API 成功返回后，不把“请求成功”直接解释成“所有读取权限已授权”。用实际 HealthKit 写入/读取结果分别反馈。
4. 日志避免记录健康样本值、passToken 或完整小米用户标识。

### 验收矩阵

| 验收项 | 预期证据 |
|---|---|
| IPA 主程序 entitlement | `com.apple.developer.healthkit = true` |
| Info.plist 用途说明 | Share 与 Update 两个 key 都存在且非空 |
| iOS 16.3 真机点击授权 | 能观察到请求状态；发生错误时 App 显示具体错误 |
| “健康”App 的来源列表 | HealthMi 出现；即使用户拒绝所有类型，完成授权请求后也应列出 |
| 系统健康数据访问页 | 可查看相应写入类型；读取授权需用实际读取结果验证 |
| 实际写入 | 一次受控同步后，在健康 App 的来源/数据中出现对应类型样本 |
| GitHub 模拟器 | 可辅助验证启动/UI/API 调用链，但不能替代 TrollStore 签名验证或 iOS 16.3 真机 HealthKit 授权验证 |

## 七、本次审查范围与未验证事项

- 静态阅读了 iOS Swift 源码、XcodeGen 工程配置、两条 GitHub Actions 工作流以及仓库内 Python MCP/CLI 的关键同步、查询、存储和凭据路径。
- 检查了本地两个未签名 IPA 的 ZIP 目录和 SHA-256；没有本机 macOS `codesign` 环境，因此没有对最终签名二进制执行 Apple 签名验证。
- 2026-11-24 复核用户指定的 iOS 16 修复版 IPA：文件存在，ZIP 结构、SHA-256、Bundle ID、HealthKit 用途说明和 Mach-O 签名 load command 已检查；该候选包未签名。此检查不覆盖 TrollStore 处理后手机实际安装的文件。
- 2026-11-24 通过私有仓库 GitHub Actions 重跑 iOS 16.4 模拟器诊断和设备目标 IPA 构建：模拟器运行 `45303564969` 成功，设备 IPA 运行 `45303591637` 成功；已下载并复核新的 IPA，确认其 SHA-256、ZIP 清单、Bundle ID、HealthKit 用途说明和 `LC_CODE_SIGNATURE` 状态。
- 没有取得用户手机上最终安装的 IPA，也没有 iOS 16.3 设备日志/HealthKit 错误码。
- 初始静态审查阶段没有运行 XCTest、HealthKit 请求或外部小米 API 请求；本报告的非 entitlement 代码缺陷仍是静态风险，需要后续用针对性测试验证。2026-11-24 的后续验证只运行了 GitHub Actions 的 iOS 16.4 模拟器诊断和设备目标 IPA 构建，没有运行 XCTest 或真实设备 HealthKit 请求。
- 2026-11-23 补充审查开始时，`main` 相对 `personal/main` 领先 3 个本地提交；之后新增了工作流修复提交并推送到 `lu1ul/HealthMi-private`，原始仓库 `ShawnDiego/HealthMi` 未被推送。已存在的未跟踪文件 `项目分析-优先关注问题.md` 保持原样。
- 初始静态审查阶段没有修改业务源码或改变仓库公开性；后续只修改了模拟器工作流的失败状态传播，并将该工作流修复推送到私有仓库以触发验证。
- 2026-11-23 继续静态审查代码基线 `82fef0f`，补充核对 Swift/Python 卡路里与睡眠分期差异、HealthKit 睡眠区间统计、快捷指令取消和后台任务完成竞态；本轮另有独立只读复核确认，本地 unsigned IPA 主可执行文件没有 `LC_CODE_SIGNATURE`。这仍不能证明用户手机上的最终安装包经过后处理后缺少 entitlement。
- 后续静态检查继续覆盖增量日活动更新、强制回填与 workout 心率关联、API 分页字段校验、Swift 数值转换、跨区域请求时区、MCP 敏感输出及 SQLite 连接生命周期；这些均为代码阅读结论，尚未运行对应回归场景。
- 本轮补充核对批次内 external UUID 去重、分页游标 JSON 编码和 CSV 导出参数；确认其为静态可见的实现缺口，但相关服务端重复页/特殊游标及 HealthKit 对重复批次的行为没有真实样本或运行证据。
- 初始静态审查轮次审查了网页登录 Cookie 域校验、同步过程中的账号/配置变化、部分失败日志以及 GitHub Actions 诊断与测试步骤；当时的 CI 结论来自工作流 YAML 静态检查，未触发 GitHub Actions。后续 GitHub Actions 运行结果已在本节前文记录。
- 另复核首次/强制回填窗口与界面天数选项，确认 N 天参数向下取整后包含 N+1 个日历日期；此结论为静态计算，未运行 API 请求。
- 另复核解析器对缺失时间戳的默认路径，确认若记录数值字段有效但 `item.time` 缺失，会产生 1970 年附近的样本时间；没有使用真实服务端异常响应验证发生频率。
- 另核对 README 中的后台刷新承诺及测试清单，发现“每小时”措辞高估 iOS 调度保证、且引用了仓库中不存在的 `MiRegionTests`。
- 初始静态审查轮次没有运行构建、测试或 GitHub runner；后续验证已按上方记录完成 GitHub Actions 运行。没有修改业务源码，未改变仓库可见性；工作流修复只推送到私有仓库。`项目分析-优先关注问题.md` 未跟踪文件保持未暂存、未修改。

## 八、参考资料

- Apple：[HealthKit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.healthkit)——应用必须配置 HealthKit entitlement 才能使用相应 HealthKit 能力。
- Apple：[Authorizing access to health data](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)——应用通过 HealthKit 授权 API 请求读写类型权限；读取授权状态受隐私保护，不能据此读取用户是否允许读取数据。
- Apple：[HKHealthStore requestAuthorization API](https://developer.apple.com/documentation/healthkit/hkhealthstore/requestauthorization(toshare:read:completion:))——请求 HealthKit 访问授权的 API。
- Apple：[HKHealthStore getRequestStatusForAuthorization API](https://developer.apple.com/documentation/healthkit/hkhealthstore/getrequeststatusforauthorization(toshare:completion:))——检查针对指定数据类型的授权请求当前是否需要系统展示表单；授权调用成功本身不能证明用户已授予所有读写权限。
- Apple：[HKHealthStore authorizationStatus API](https://developer.apple.com/documentation/healthkit/hkhealthstore/authorizationstatus(for:))——查询指定对象类型的共享/写入授权状态。
- Apple：[HKQuery `predicateForSamples`](https://developer.apple.com/documentation/healthkit/hkquery/predicateforsamples(withstart:end:options:))——样本查询的时间范围可按样本与区间相交来匹配，计算边界区间总时长时需明确裁剪策略。
- Apple：[HKQueryOptions](https://developer.apple.com/documentation/healthkit/hkqueryoptions)——`strictStartDate` 与 `strictEndDate` 分别要求样本起始/结束时间落在目标区间内。
- Apple：[BGTask `expirationHandler`](https://developer.apple.com/documentation/backgroundtasks/bgtask/expirationhandler) 与 [`setTaskCompleted(success:)`](https://developer.apple.com/documentation/backgroundtasks/bgtask/settaskcompleted(success:))——后台任务到期处理和完成状态的官方接口。
- Apple：[BGTaskRequest `earliestBeginDate`](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)——任务最早启动时间由请求指定，不等同于系统保证的实际启动时间。
- GitHub：[Workflow syntax for GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)——`continue-on-error` 会影响失败步骤对 job 结果的传播。
- GitHub：[Workflow commands for GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands)——`::error::` 用于创建注释；需要非零退出状态或显式失败命令才能让步骤失败。
- Swift 标准库：[`Int.init(_ source: Double)`](https://developer.apple.com/documentation/swift/int/init(_:))——浮点转整数要求输入值可由目标整数类型表示；对外部文本解析应先验证范围与有限性。
- Python 标准库：[sqlite3 connection context manager](https://docs.python.org/3/library/sqlite3.html#how-to-use-the-connection-context-manager)——连接上下文管理器提交或回滚事务，但不会关闭连接。
- TrollStore：[官方 README](https://github.com/opa334/TrollStore/blob/main/README.md)——用于核对其支持范围和 entitlement 处理方式；TrollStore 可处理带任意 entitlement 的应用，但安装成功本身并不证明 HealthKit entitlement 存在。

---

## 九、公开仓库变更与原版仓库/IPA 深度对比（2026-11-24）

### 9.1 GitHub 仓库可见性已核验

已按用户授权将 lu1ul/HealthMi-private 从私有改为公开，并通过 GitHub API 回读确认：

| 仓库 | 可见性 | 是否 fork | main 当前提交 |
|---|---|---:|---|
| lu1ul/HealthMi-private | PUBLIC | 否 | 68b5cce75a37a9ffb1438ca42310c85721f3d73c |
| lu1ul/HealthMi | PUBLIC | 是，父仓库为 ShawnDiego/HealthMi | e5faf4e9b23f193a2362d7294cebc4c9fbe88574 |
| ShawnDiego/HealthMi | PUBLIC | 否 | 5930b706003ac0b3ef08894f09fa7b61615e96e0 |

本次可见性变更没有向 ShawnDiego/HealthMi 推送提交。公开后，lu1ul/HealthMi-private 的代码、提交历史和工作流均可被其他人查看；仓库历史中如果曾经出现过敏感内容，改为公开不会自动清除历史。

### 9.2 三个仓库的源码和工程配置差异

#### HealthKit 相关源码实际上没有变化

以下文件在当前 iOS 16 适配版与 lu1ul/HealthMi 原版 fork 中逐字一致：

- HealthMi/Health/HealthKitManager.swift
- HealthMi/Health/HealthKitReader.swift
- HealthMi/Health/HealthWriter.swift
- HealthMi/Support/Info.plist
- HealthMi/Support/HealthMi.entitlements

三方共同的关键值为：

    Bundle ID: com.healthmi.HealthMi
    com.apple.developer.healthkit: true（只存在于工程输入的 entitlement 文件）
    NSHealthShareUsageDescription: 存在
    NSHealthUpdateUsageDescription: 存在

授权调用链也一致：

    DashboardView
      -> Task { try? await model.requestHealthKit() }
      -> AppModel.requestHealthKit()
      -> HealthKitManager.requestAuthorization()
      -> HKHealthStore.requestAuthorization(toShare:read:)

因此，当前 iOS 16 适配版在 HealthKitManager、用途说明、Bundle ID 或请求类型集合上，没有发现一个能单独解释“原版能弹窗、适配版不弹窗”的源码差异。

#### 真正的代码差异集中在 SwiftData 到 Core Data

当前 iOS 16 适配版：

- AppModel 使用 ObservableObject、Published 和 Core Data 上下文；
- DashboardView 使用 FetchRequest；
- HealthMiApp 使用异步准备的 NSPersistentContainer；
- 新增 HealthMi/Sync/CoreDataModels.swift；
- 启动时在 iOS 17+ 迁移旧 SwiftData 数据。

原版 fork 和上游：

- AppModel 使用 Observation 的 Observable；
- 视图使用 SwiftData Query；
- HealthMiApp 直接创建 ModelContainer；
- 依赖 SwiftData 的迁移模型。

这组差异影响本地同步游标、压力记录和同步日志，不改变 HealthKit 请求类型或授权 API。当前 iOS 16.4 模拟器已能安装、启动并保持进程运行，说明 Core Data 改造没有造成一个“应用一启动就崩溃”的普遍问题；但它不能替代 iOS 16.3 真机的 HealthKit 授权验证。

#### project.yml 与原版提交的 Xcode 工程存在漂移

当前适配版 project.yml：

    deploymentTarget: iOS 16.0
    IPHONEOS_DEPLOYMENT_TARGET: 16.0
    MARKETING_VERSION: 1.1.0

原版 fork 的 project.yml：

    deploymentTarget: iOS 17.0
    IPHONEOS_DEPLOYMENT_TARGET: 17.0
    MARKETING_VERSION: 1.1.0

但是原版 fork 的 HealthMi.xcodeproj/project.pbxproj 仍然记录：

    IPHONEOS_DEPLOYMENT_TARGET = 17.0
    MARKETING_VERSION = 1.0.0
    CODE_SIGN_ENTITLEMENTS = HealthMi/Support/HealthMi.entitlements
    PRODUCT_BUNDLE_IDENTIFIER = com.healthmi.HealthMi

这说明原版工作流构建的是仓库内已提交的 HealthMi.xcodeproj，不一定采用最新的 project.yml。原版构建出的 IPA 的 CFBundleShortVersionString 实际为 1.0.0，正好印证了这个工程文件漂移。

### 9.3 两条 GitHub Actions 工作流的关键差异

#### 原版 fork：.github/workflows/build-ipa.yml

原版工作流直接执行：

    xcodebuild -project HealthMi.xcodeproj
      -scheme HealthMi
      -configuration Release
      -sdk iphoneos
      -destination 'generic/platform=iOS'
      CODE_SIGNING_ALLOWED=NO
      CODE_SIGNING_REQUIRED=NO
      CODE_SIGN_IDENTITY=""
      build

随后把 HealthMi.app 直接压入 HealthMi-unsigned.ipa。工作流没有：

- xcodegen generate
- Apple 证书或 provisioning profile
- codesign
- ldid
- 最终 entitlement 检查

#### 当前 iOS 16 适配版：.github/workflows/build-unsigned-ipa.yml

当前工作流先运行：

    brew install xcodegen
    xcodegen generate

再以 iOS 16 的 project.yml 生成工程并构建；但设备目标构建同样明确设置：

    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=''

当前工作流还检查 _CodeSignature 不存在，然后将应用打成未签名 IPA。也就是说，当前工作流比原版更能保证 project.yml 与生成工程同步，但两条工作流的共同点是：都没有交付一个已经带有效签名 entitlement 的 HealthKit IPA。

### 9.4 原版 fork IPA 的实际包级核验

已下载原版 fork 最近一次成功构建：

    仓库: lu1ul/HealthMi
    Workflow: build-ipa.yml
    Run: 45047542713
    Artifact: HealthMi-unsigned-IPA
    本地文件: build/repo-compare/original-artifact/HealthMi-unsigned.ipa
    SHA-256: 70500749969BD4F56F5F99901A5E518F898CD68048430DD1BF02E94572D1360C

原版 IPA 实际内容：

| 检查项 | 结果 |
|---|---|
| Payload/HealthMi.app/HealthMi | 存在 |
| CFBundleIdentifier | com.healthmi.HealthMi |
| CFBundleShortVersionString | 1.0.0 |
| 主程序架构 | 64 位 arm64 Mach-O |
| LC_CODE_SIGNATURE | 未发现 |
| Payload/HealthMi.app/_CodeSignature/ | 不存在 |
| embedded.mobileprovision | 不存在 |
| 独立 .entitlements 文件 | 不存在 |
| NSHealthShareUsageDescription | 存在 |
| NSHealthUpdateUsageDescription | 存在 |
| com.apple.developer.healthkit 的有效签名 entitlement | 未发现 |

当前 iOS 16 适配版 GitHub IPA 的对照结果：

    文件: build/github-run-45303591637/HealthMi-unsigned.ipa
    SHA-256: 48A595AACF66D26829D8CE41109EC59FC81115098C933E6D9A16B81C16D004A2
    Bundle ID: com.healthmi.HealthMi
    版本: 1.1.0
    主程序: 64 位 arm64 Mach-O
    LC_CODE_SIGNATURE: 未发现
    _CodeSignature: 不存在
    embedded.mobileprovision: 不存在
    有效签名 entitlement: 未发现

用户指定的本地 iOS 16 修复版 IPA 也保持同一结论：

    文件: build/HealthMi-unsigned-ipa-after-ios16-fix/HealthMi-unsigned-ipa/HealthMi-unsigned.ipa
    SHA-256: 88198DBF1A140E88553CC9A6B2B7584127456888EF23264F5DA80E6027083716

### 9.5 对“原版能用、当前版不能用”的证据解释

当前已排除的解释：

1. 不是 HealthKit 源文件差异。三份 HealthKit 相关源码和两个用途说明文件一致。
2. 不是 Bundle ID 差异。两份 IPA 都是 com.healthmi.HealthMi。
3. 不是工程 entitlement 文件是否存在的差异。两边工程都包含 HealthMi.entitlements 并声明 com.apple.developer.healthkit = true。
4. 不能把“原版工作流成功”当作“原版 IPA 带 entitlement”。实际下载并解析的原版 artifact 没有 LC_CODE_SIGNATURE，也没有可提取的有效 entitlement。
5. 不能仅以 iOS 16.3 与 iOS 27 的系统版本差异定责。目前没有同一份、已核验 entitlement 的 IPA 在两个系统版本上的对照实验；而用户所说的“iOS 27”也没有设备日志或安装包证据对应到本次下载的 artifact。

最合理的解释按优先级排序：

#### P0-A：用户实际安装的“原版 IPA”不是本次下载的 unsigned artifact

这是目前最需要确认的事实。原版 GitHub artifact 的包级证据显示它没有有效签名 entitlement；如果原版在用户设备上确实能出现在“健康”App 来源并弹出授权表单，则用户安装的原版很可能经过了另一个步骤，例如：

- 在安装前使用 ldid 或其他工具对主程序重新签名；
- 通过另一条没有提交到当前 fork 的工作流产生；
- 使用了本地 Xcode/开发者签名构建；
- 从不同的 GitHub run 或其他发布文件安装。

仅凭文件名 HealthMi-unsigned.ipa 不能确认它与用户手机当前安装的包是同一个二进制。

#### P0-B：当前 IPA 在交给 TrollStore 前没有把 HealthKit entitlement 写入主程序

TrollStore 官方说明要求把 entitlement 通过 ldid -S<entitlements.plist> 伪签进 IPA 内的主二进制，安装时才会保留这些 entitlement。当前两个 GitHub workflow 都没有执行 ldid，而本次检查的两个 artifact 也没有签名 load command。因此，如果当前 IPA 是直接下载后交给 TrollStore，HealthKit entitlement 缺失仍是最高概率原因。

#### P1：授权错误被界面静默吞掉

当前和原版都在权限按钮使用：

    Task { try? await model.requestHealthKit() }

如果系统返回 entitlement、授权状态或其他 HKError，用户都会看到“没有反应”。这解释了为什么当前界面无法帮助区分“请求根本没到 HealthKit”和“请求到达后失败”。该问题是共同代码缺陷，但当前适配版更需要先修复，因为它阻碍定位 Core Data/系统版本/签名差异。

#### P2：已有授权状态导致系统不再显示表单

Apple 的授权规则允许在用户已经对本次请求的全部数据类型作出允许或拒绝决定后，直接返回而不再次显示表单。完成授权请求后，应用应能在“健康”App 的来源列表中找到，即使用户拒绝了所有类型。因此“无弹窗”本身不是定责证据；“无弹窗且来源列表完全没有 HealthMi”更支持请求因签名/entitlement/安装包处理失败，或用户检查的不是当前 Bundle ID 对应的应用。

### 9.6 当前结论

截至 2026-11-24，证据链可以支持以下结论：

- lu1ul/HealthMi-private 已成功改为公开仓库。
- iOS 16 适配版的 Core Data 改造不是 HealthKit 类型、用途说明或 Bundle ID 方面的差异。
- 原版 fork 的源码仍是 iOS 17 + SwiftData；它的 GitHub IPA workflow 也明确生成 unsigned IPA。
- 原版 fork 最近成功 artifact 的实际二进制同样没有 LC_CODE_SIGNATURE 或 HealthKit entitlement。
- 因此，“原版在用户设备可用”与“本次下载的原版 unsigned artifact 的静态内容”存在事实缺口；必须取得用户实际安装的原版 IPA，或从手机导出已安装的 HealthMi 主程序后检查 entitlement，才能把差异落到具体环节。
- 当前 iOS 16.3 设备上“健康 App 没有 HealthMi”的首要排查点仍是：安装前/安装后主程序是否含 com.apple.developer.healthkit = true，以及按钮是否把真实 HKError 显示出来。
- 不能把“iOS 16.3 本身不支持 HealthKit”作为解释；当前源码使用的 HealthKit API 并非因为最低部署版本改成 16.0 就自动失效。真正未验证的是设备上最终安装二进制的签名和 TrollStore 后处理结果。

### 9.7 建议的下一步验证顺序

1. 核对用户实际安装的原版包。分别记录原版和当前版的 IPA SHA-256、Bundle ID、版本号；不要只看文件名。
2. 检查最终 entitlement。
   - macOS/Xcode：codesign -d --entitlements :- Payload/HealthMi.app/HealthMi
   - 已安装到越狱设备后，用 ldid -e /path/to/HealthMi 或同等工具导出 entitlement。
   - 重点确认 com.apple.developer.healthkit = true。
3. 将当前按钮错误显示出来。把 try? 改成 do/catch，在 UI 和日志中显示 error.localizedDescription 及 HKError code。
4. 在 workflow 中增加硬性包检验。
   - TrollStore 产物：运行 ldid 后再打包，并在 CI 中检查 LC_CODE_SIGNATURE 与 entitlement。
   - Apple 签名产物：使用证书/profile 构建，使用 codesign 验证最终签名。
   - unsigned 产物必须在 artifact 名称中明确标记为不能直接证明 HealthKit entitlement。
5. 最后再比较 iOS 16.3 与 iOS 27。必须使用同一个经过 entitlement 核验的 IPA，分别记录授权请求结果；否则系统版本差异和包差异无法分离。

### 9.8 本轮修复与本地提交记录（2026-11-24）

本轮已完成并在本地提交以下变更：

1. **权限按钮错误反馈**
   - 提交：`556f8a0 fix: show HealthKit authorization errors`
   - `AppModel` 增加 `healthKitError`，请求失败时保留 `HKError` 的 domain、code 和可读描述。
   - 仪表盘 Apple 健康区域显示错误信息；登录引导页也不再用 `try?` 静默吞掉请求失败。
   - 该变更只改善诊断和用户反馈，不会绕过系统权限或伪造授权状态。

2. **TrollStore HealthKit IPA 工作流**
   - 提交：`b71ad8f ci: build TrollStore HealthKit IPA`
   - `.github/workflows/build-unsigned-ipa.yml` 仍保留 `HealthMi-unsigned-ipa` 对照产物。
   - GitHub `macos-15` runner 安装 Homebrew `ldid`，对构建出的 `HealthMi` 主程序执行 `ldid -S<entitlements.plist>`，再生成 `HealthMi-trollstore-healthkit.ipa`。
   - 工作流在打包前和解包后都检查：
     - `LC_CODE_SIGNATURE` 存在；
     - `com.apple.developer.healthkit = true`；
     - `NSHealthShareUsageDescription` 和 `NSHealthUpdateUsageDescription` 存在；
     - 主程序包含 `arm64` 架构；
     - Bundle ID 与默认值或手动输入值一致。
   - `build/entitlement-report.txt` 会随 `HealthMi-trollstore-healthkit-ipa` artifact 一起上传，报告 IPA 和主程序 SHA-256。

3. **产物边界**
   - `HealthMi-unsigned.ipa` 只用于对照，不能据此证明 HealthKit entitlement 已写入。
   - `HealthMi-trollstore-healthkit.ipa` 是给 TrollStore 安装的伪签名/签名块产物，不是 App Store、TestFlight 或普通未越狱设备使用的 Apple Developer distribution 包。
   - 手机端不需要手工执行 `ldid`；只需安装工作流生成的 TrollStore IPA。为避免旧安装包和授权状态干扰，验证时应先删除旧版 HealthMi，再安装新包。

4. **验证状态与限制**
   - 本地 Windows 环境已完成 workflow 差异检查和 `git diff --check`；没有 macOS 的 `xcodebuild`、`ldid`、`otool` 工具链，因此尚未在本机模拟 GitHub runner 的最终打包。
   - 当前尚未把这些提交推送到 `lu1ul/HealthMi-private`，所以 GitHub Actions 尚未产生本轮新的 artifact。推送后必须以 Actions 日志中的 entitlement 检查和 `entitlement-report.txt` 为准。
   - CI 静态检查通过后，仍需在用户的 iOS 16.3 + TrollStore 设备上验证：安装来源是否出现 HealthMi、请求按钮是否显示系统授权表单，以及拒绝/允许后的 `HKAuthorizationStatus` 和同步行为。

### 9.9 GitHub CLI 与最终 IPA 产物核验（2026-11-24）

#### GitHub CLI PATH 状态

- 本机已安装 GitHub CLI，实际可执行文件为：`C:\Program Files\GitHub CLI\gh.exe`。
- 初始状态下该目录不在 Machine PATH 或 User PATH，因此直接输入 `gh` 会提示找不到命令；这属于 PATH 配置问题，不是 GitHub CLI 未安装。
- 尝试写入系统级 PATH 时被当前 Windows 进程拒绝，原因是当前会话没有管理员权限；没有修改系统级 PATH。
- 随后将该目录加入当前用户的持久化 User PATH。新 PowerShell 进程验证通过：

  ```text
  gh version 2.105.0 (2026-11-17)
  github.com
    Logged in to github.com account lu1ul
    Active account: true
    Git operations protocol: https
    Token scopes: gist, read:org, repo
  ```

- 以后新开的 PowerShell、Windows Terminal 或其他终端应可以直接执行 `gh`；已经打开的旧终端需要重新打开，或临时刷新 PATH。

#### GitHub Actions 构建结果

- 仓库：`lu1ul/HealthMi-private`
- 工作流 run：`45314992203`
- 构建提交：`311403d1b9f8c7291d75d109913b4584b1c27e72`
- runner：GitHub macOS 15 ARM64，Xcode 16.4
- 结论：`success`
- 本轮使用 GitHub CLI 下载，不依赖浏览器：

  ```powershell
  gh run download 45314992203 --repo lu1ul/HealthMi-private --name HealthMi-trollstore-healthkit-ipa
  gh run download 45314992203 --repo lu1ul/HealthMi-private --name HealthMi-unsigned-ipa
  ```

#### 本地下载文件

- TrollStore artifact：
  `build/github-run-45314992203/trollstore-artifact/HealthMi-trollstore-healthkit.ipa`
- TrollStore entitlement 报告：
  `build/github-run-45314992203/trollstore-artifact/entitlement-report.txt`
- unsigned 对照 artifact：
  `build/github-run-45314992203/unsigned-artifact/HealthMi-unsigned.ipa`

#### IPA 与 Mach-O 实际核验

对下载后的 IPA 解包，并直接解析 `Payload/HealthMi.app/HealthMi` 的 Mach-O 结构，结果如下：

| 项目 | TrollStore IPA | unsigned IPA |
| --- | --- | --- |
| IPA SHA-256 | `6d5701a19276fbc76523319ccacc8867df046cf85e1bdde90f254f929730ac91` | `0162e40eee5b03f598122e6956b6c244a02aa0eba007d7029060517976745b49` |
| 主程序 SHA-256 | `4444b8350fd0b2fa44d77235b75dcf44956fb9ce0175ceb7e81d81d051fbd1c4` | `0f8e1c16e89bc9cbdcb6dfccab3cc531a134f84632cc7be56a98f0c9d2350f96` |
| 主程序架构 | arm64 | arm64 |
| `LC_CODE_SIGNATURE` | 存在 | 不存在 |
| `com.apple.developer.healthkit` | `true` | 无可提取 entitlement |
| Bundle ID | `com.healthmi.HealthMi` | `com.healthmi.HealthMi` |
| 版本 | `1.1.0` | `1.1.0` |
| HealthKit 用途说明 | 两项均存在 | 两项均存在 |
| `embedded.mobileprovision` | 不存在，符合 TrollStore 伪签名包预期 | 不存在 |

TrollStore IPA 的代码签名 SuperBlob 中包含 5 个签名条目，解析出的 entitlement plist 至少包含：

```text
com.apple.developer.healthkit = true
```

GitHub Actions 日志同时报告：

```text
Verified Bundle ID: com.healthmi.HealthMi
Verified com.apple.developer.healthkit = true
Verified arm64 architecture: arm64
Verified HealthKit usage descriptions
Packaged IPA entitlement and usage descriptions verified.
ldid: ldid 2.1.5_2
LC_CODE_SIGNATURE: present
```

#### 结论与安装要求

1. 本轮工作流不是只生成文本报告：最终下载的 TrollStore IPA 主程序确实包含 `LC_CODE_SIGNATURE` 和 `com.apple.developer.healthkit=true`。
2. 给 iOS 16.3 + TrollStore 设备安装时，应选择 `HealthMi-trollstore-healthkit.ipa`，不要选择 `HealthMi-unsigned.ipa`。
3. 安装验证前建议先删除旧版 HealthMi，再安装新包，以避免旧包、旧授权状态或同 Bundle ID 的安装残留干扰。
4. 该静态核验能证明包内 entitlement 已写入，但不能替代用户设备上的最终运行验证；仍需观察“健康”App 来源列表、授权弹窗和按钮错误反馈。
5. 本轮下载和核验产生的 `build/` 文件位于 Git 忽略目录，不会进入源码提交；本地报告会保留证据和 SHA-256，便于后续对照手机实际安装包。

### 9.10 TrollStore 版登录失败：Keychain 错误 `-34018` 根因（2026-11-24）

用户重新安装本轮 TrollStore IPA 后，登录小米账号时出现：

```text
保存并验证登录凭证失败：Keychain 错误（-34018）
```

#### 代码侧排查

- `HealthMi/App/CredentialStore.swift` 在本轮没有改动，仍使用 `SecItemUpdate`；找不到记录时使用 `SecItemAdd`。
- Keychain 查询使用 `kSecClassGenericPassword`、service 和 account，没有显式设置 `kSecAttrAccessGroup`；因此访问组由最终安装二进制的签名 entitlement 决定。
- 本轮近期提交 `565cd71`、`556f8a0`、`b71ad8f` 均没有修改 Keychain 查询逻辑。
- 因此错误发生在 Keychain 安全上下文，而不是小米网页登录 Cookie 提取、网络连接、Core Data 或 iOS 16 存储迁移。

#### 打包侧证据

本轮下载并解析的 TrollStore IPA 主程序 entitlement 只有 HealthKit 相关声明，至少确认了：

```text
com.apple.developer.healthkit = true
```

它没有包含 TrollStore 在“无 entitlement 主程序”情况下使用的默认 Keychain 相关声明。

通过 GitHub CLI 读取 TrollStore 官方 `RootHelper/main.m` 的源码可见，TrollStore 只有在主程序没有任何 entitlement 时才创建 fallback entitlement：

```text
application-identifier = TROLLTROLL.*
com.apple.developer.team-identifier = TROLLTROLL
get-task-allow = true
keychain-access-groups = [TROLLTROLL.*, com.apple.token]
```

当前工作流先执行了：

```text
ldid -SHealthMi.entitlements HealthMi
```

这使主程序不再是“无 entitlement”。安装时 TrollStore 会保留已有的 HealthKit entitlement，也就不会再走上述 fallback 分支；应用的默认 Keychain 访问组因此缺失，保存凭据时返回 `-34018`（`errSecMissingEntitlement`）。

#### 为什么原版可以登录

- 原版 `HealthMi-unsigned.ipa` 的主程序没有 `LC_CODE_SIGNATURE`，也没有可提取的 entitlement。
- 将这类 unsigned 主程序交给 TrollStore 时，会满足“无 entitlement”条件，TrollStore 自动加入 `TROLLTROLL.*` Keychain 访问组。
- 本轮 TrollStore IPA 虽然正确加入了 HealthKit entitlement，却没有同时合并 TrollStore 默认 Keychain entitlement，因此出现“健康权限修好了，但登录 Keychain 失败”的回归。

#### 结论

这是本轮 **TrollStore entitlement 打包方案的回归**，不是 `CredentialStore` Swift 代码回归，也不是用户手机上的 Keychain 数据本身损坏。当前产物在 HealthKit 能力和 Keychain fallback 之间缺少合并：

```text
当前：HealthKit entitlement ✅，TrollStore Keychain fallback ❌
需要：HealthKit entitlement ✅，TrollStore Keychain entitlement ✅
```

#### 修复方向（待确认后实施）

推荐只在 TrollStore 工作流生成的临时 entitlement 文件中合并以下声明，不修改 Apple 开发者签名用的 `HealthMi.entitlements` 源文件：

```text
application-identifier = TROLLTROLL.*
com.apple.developer.team-identifier = TROLLTROLL
get-task-allow = true
keychain-access-groups = [TROLLTROLL.*, com.apple.token]
com.apple.developer.healthkit = true
```

随后 CI 必须从最终 IPA 解包主程序中同时检查 HealthKit 和 Keychain entitlement。Apple 正式签名路线仍使用原始 `HealthMi.entitlements`，避免把 TrollStore 专用的 `TROLLTROLL` 声明带入普通开发者签名包。

### 9.11 TrollStore Keychain entitlement 修复实施（2026-11-24）

针对 `SecItemAdd` / `SecItemUpdate` 返回 Keychain 错误 `-34018` 的回归，已按上述方案修改 `.github/workflows/build-unsigned-ipa.yml`，本地提交为：

```text
3e74366 fix: preserve TrollStore Keychain entitlements
```

#### 实施内容

- 保留源文件 `HealthMi/Support/HealthMi.entitlements` 不变；该文件继续只描述 Apple 开发者签名路线需要的 HealthKit 能力。
- 在 TrollStore 构建步骤中读取源 entitlement，并生成仅用于该产物的 `build/trollstore-entitlements.plist`。
- 临时 entitlement 在保留 `com.apple.developer.healthkit = true` 的基础上增加：

  ```text
  application-identifier = TROLLTROLL.*
  com.apple.developer.team-identifier = TROLLTROLL
  get-task-allow = true
  keychain-access-groups = [TROLLTROLL.*, com.apple.token]
  ```

- 使用 `ldid` 将合并后的 entitlement 写入 TrollStore IPA 主程序。
- 在打包前和 IPA 解包后分别检查：
  - `LC_CODE_SIGNATURE` 存在；
  - `com.apple.developer.healthkit = true`；
  - `application-identifier`、团队标识、`get-task-allow` 和两个 Keychain 访问组均符合预期；
  - Bundle ID、arm64 架构和 HealthKit 用途说明存在。
- `entitlement-report.txt` 增加上述 Keychain 字段，便于下载产物后复核。

#### 安全边界

`TROLLTROLL` entitlement 只在 GitHub Actions 的 TrollStore IPA 临时文件中生成，不写回源 `.entitlements` 文件，也不影响 Apple Developer 正式签名工作流。未签名对照 IPA 仍然保留，用于比较，不应直接作为带 HealthKit/Keychain 能力的安装包。

#### 待完成的远程验证

本地 Windows 环境没有 macOS 的 `xcodebuild`、`ldid` 和 `otool` 工具链，因此本地只能完成 workflow 文本检查和差异检查。下一步将只推送 `personal` 远程，使用 GitHub Actions 的 macOS 15 runner 构建，再通过 `gh` 下载 `HealthMi-trollstore-healthkit-ipa` artifact，记录 run ID、IPA SHA-256、主程序 SHA-256 和最终 entitlement 解析结果。远程构建成功后，仍需在 iOS 16.3 + TrollStore 真机上重新安装并验证 Keychain 登录与 HealthKit 来源列表。

### 9.12 修复后 TrollStore IPA 远程构建与独立核验（2026-11-24）

#### GitHub Actions 运行

- 仓库：`lu1ul/HealthMi-private`
- 推送目标：`personal/main`；没有推送到 `origin` 上游。
- 构建提交：`16a0797e61ba4ca2b12986222b32c8ec9fc541c6`
- Actions run：`45340198351`
- Runner：macOS 15 ARM64，Xcode 16.4，`ldid 2.1.5_2`
- 结果：成功；设备目标构建、未签名对照 IPA、TrollStore IPA 创建、打包前检查、解包后检查和 artifact 上传全部通过。

#### 产物下载

按约定使用 GitHub CLI 下载，没有使用浏览器：

```powershell
& "C:/Program Files/GitHub CLI/gh.exe" run download 45340198351 `
  --repo "lu1ul/HealthMi-private" `
  --name "HealthMi-trollstore-healthkit-ipa" `
  --dir "build/github-run-45340198351/trollstore-artifact"
```

本地文件：

```text
build/github-run-45340198351/trollstore-artifact/HealthMi-trollstore-healthkit.ipa
build/github-run-45340198351/trollstore-artifact/entitlement-report.txt
```

#### IPA 独立解析结果

除 CI 日志外，又在 Windows 本地对下载的 IPA 做了 ZIP、Info.plist 和 Mach-O 签名块解析：

| 检查项 | 结果 |
|---|---|
| IPA SHA-256 | `51343485675ca1d81c6b56afbfa9130945f53fcf253ba767802ccbc911de806c` |
| 主程序 SHA-256 | `dbdc48bd33311f9a3b59bec0694e6da56ca7c4e82f8a4104074af51734467c82` |
| Bundle ID | `com.healthmi.HealthMi` |
| 版本 | `1.1.0` |
| 主程序架构 | arm64 thin Mach-O |
| `LC_CODE_SIGNATURE` | 存在；签名块 offset `3270512`，size `43056` |
| `com.apple.developer.healthkit` | `true` |
| `application-identifier` | `TROLLTROLL.*` |
| `com.apple.developer.team-identifier` | `TROLLTROLL` |
| `get-task-allow` | `true` |
| `keychain-access-groups` | `TROLLTROLL.*`、`com.apple.token` |
| `NSHealthShareUsageDescription` | 存在 |
| `NSHealthUpdateUsageDescription` | 存在 |
| `embedded.mobileprovision` | 不存在，符合 TrollStore 产物预期 |

IPA 内共 15 个 ZIP 条目；签名 SuperBlob 包含 entitlement blob，独立解析出的 plist 与 CI 报告完全一致。

#### 结论

本次修复已经解决了构建产物层面的缺口：HealthKit entitlement 与 TrollStore 默认 Keychain entitlement 同时存在，`-34018` 的直接打包原因已消除。给 iOS 16.3 + TrollStore 安装时应使用上述 `HealthMi-trollstore-healthkit.ipa`，不要使用 `HealthMi-unsigned.ipa`，也不要继续使用 run `45314992203` 生成的旧包。

静态核验不能替代真机运行验证。安装新包后仍需删除旧版 HealthMi，再安装新包并实际验证：小米账号凭据是否能保存、HealthKit 授权按钮是否显示错误或系统表单，以及“健康”App 的来源列表是否出现 HealthMi。若仍出现 `-34018`，下一步需要从越狱设备导出已安装主程序并重新解析其最终 entitlement，以区分安装器后处理与应用包本身的差异。

### 9.13 iOS 16.3 + TrollStore 真机验收后的结论修订（2026-11-24）

用户已在 iPhone iOS 16.3、TrollStore 安装本次修复后的 `HealthMi-trollstore-healthkit.ipa`，完成以下实机验收：

1. IPA 可以通过 TrollStore 安装并启动。
2. 点击“请求健康权限”可以正常触发 HealthKit 授权流程，应用能够出现在健康 App 的访问来源中。
3. 登录小米账号后，数据可以从小米云端同步并写入 Apple 健康。

这些结果把此前报告中的若干“静态推断”提升为设备侧功能证据：

| 结论 | 当前状态 | 证据 |
|---|---|---|
| iOS 16.3 能运行当前 iOS 16 适配版 | 已在本机路径验证 | 用户实机安装并运行成功 |
| TrollStore IPA 的 HealthKit entitlement 可用 | 已验证 | 授权流程被系统正常触发，数据写入成功 |
| `-34018` 的 Keychain 打包回归已修复 | 已验证 | 新包可完成登录并继续同步；此前同路线旧包在保存凭据时失败 |
| GitHub Actions 生成的 TrollStore 包可作为安装包使用 | 已验证 | run `45340198351` 产物在 iOS 16.3 真机工作 |
| 原来的 unsigned IPA 是否适合直接安装 | 已否定 | unsigned 包没有 `LC_CODE_SIGNATURE`，应使用 TrollStore 专用产物 |

历史章节中“尚未取得手机最终安装包”“尚不能确认设备侧 entitlement”的内容保留为当时的审查记录；以上验收结果是对这些内容的后续修订，不再作为当前结论。

### 9.14 快捷指令“无法与帮助程序通信”分析（2026-11-24）

#### 用户现象

在快捷指令中可以找到 HealthMi 的“同步健康数据”动作，但执行时显示：

```text
无法与帮助程序通信
```

这说明动作已经被快捷指令索引并开始执行；它不是“找不到动作”或“App Shortcuts 没有注册”的问题。

#### 已排除的原因

1. **不是 App Intent 元数据缺失。** 本次 IPA 中存在 `Payload/HealthMi.app/Metadata.appintents`，其中的 `root.ssu.yaml` 明确包含 `SyncHealthDataIntent_0` 和标题“同步健康数据”。
2. **不是缺少独立 Intent Extension target。** `project.yml` 和生成的 `HealthMi.xcodeproj/project.pbxproj` 只有 `HealthMi` 应用 target 和 `HealthMiTests` 测试 target，没有单独的 Intent Extension。当前 App Intents 写法属于直接编译进主 App 的模式，不存在一个漏建的“帮助程序 target”。
3. **不是快捷指令短语解析失败。** 动作已经能在快捷指令中被找到并执行到错误提示阶段；`HealthMiShortcuts` 的三条短语也已被编译进 metadata。
4. **不是 HealthKit entitlement 的首要嫌疑。** 同一个修复后的 IPA 已在主 App 内成功触发授权并写入健康数据，HealthKit 能力本身已经通过真机验证。

#### 当前代码实际执行路径

快捷指令动作位于 `HealthMi/App/SyncIntent.swift`：

```swift
nonisolated static let openAppWhenRun = false

@MainActor
func perform() async throws -> some IntentResult {
    let model = AppModel()
    model.bootstrap()
    let container = try await AppDatabase.shared.prepare()
    let syncTask = Task { @MainActor in
        await model.syncAll(
            modelContext: container.viewContext,
            isBackground: true
        )
    }
    // 最多等待 55 秒
    await syncTask.value
    return .result(dialog: ...)
}
```

因此，快捷指令帮助进程必须在一次 App Intent 调用中完成：

- 读取 Keychain 中的小米凭据；
- 初始化 Core Data 容器和持久化 store；
- 检查 HealthKit 授权；
- 连接小米云端并登录会话；
- 拉取最多九类数据；
- 处理分页、重试和限流；
- 写入 HealthKit，写入压力数据和同步游标；
- 刷新 HealthKit 摘要；
- 最后返回 `IntentResult`。

这与旧版 `fa08a1c` 的执行模型有实质差异：旧版 `openAppWhenRun = true`，`perform()` 只设置一个触发标记并立即返回，由主 App 界面在打开后执行同步；当前版本把完整同步链路放进了 `openAppWhenRun = false` 的帮助进程。

#### 可能性排序

**P0：帮助进程在 `perform()` 返回前被系统终止或通信超时。**

这是目前最高概率原因。代码中的 55 秒只是应用自己创建的 watchdog，不是系统给 App Intent 的执行时限保证。单个 URL 请求本身允许 30 秒，网络失败还会按 1 秒、2 秒、4 秒退避重试；分页和九类数据的 HealthKit 去重查询还会继续增加耗时。帮助进程一旦在等待 `syncTask.value` 时被系统回收，快捷指令只能显示“无法与帮助程序通信”。

这个解释也符合版本历史：旧版动作只立即返回并打开主 App，而当前版本在后台直接执行完整同步；问题正好出现在执行模型切换之后。

**P1：帮助进程初始化 Core Data 或访问共享数据时失败。**

`perform()` 对 `AppDatabase.shared.prepare()` 没有 `do/catch`，持久化 store 打开失败、数据库被并发占用、迁移异常或沙盒访问失败都会直接抛出到 App Intents 宿主，快捷指令不会得到应用自己的错误文本，只会显示通用通信错误。当前 iOS 16.3 不会进入 iOS 17 的 SwiftData 导入分支，但 Core Data store 初始化仍然是帮助进程中的独立启动路径。

另外，`AppModel.syncActivity` 是进程内锁；主 App 和 App Intent 如果是不同进程，两个实例之间不共享这把锁。快捷指令和前台同步同时运行时，可能形成两个同步会话并发访问同一 Core Data store。这个问题不一定直接造成当前错误，但属于该执行模型的真实竞态。

**P1：帮助进程中的 Keychain/HealthKit 访问失败。**

新的 TrollStore entitlement 已经在主 App 真机路径验证成功，但还没有单独的帮助进程日志证明 App Intent 执行上下文拿到同样的安全能力。如果帮助进程在 `CredentialStore.load()`、HealthKit 状态检查或首次写入时被系统拒绝，当前代码没有把错误包装成可见的 Intent 错误，最终仍可能只呈现通信失败。这个可能性低于 P0，因为当前 IPA 已通过主 App 的登录、授权和同步验证，但仍需日志或最小化实验排除。

**P2：后台执行中附加了不必要的工作。**

`syncAll(isBackground: true)` 在所有类型完成后仍会调用 `refreshSummary()`，这会额外发起多组 HealthKit 查询；失败时还会查询通知权限并安排本地通知。快捷指令只需要知道同步结果，不需要立即刷新主界面的趋势摘要。该额外工作会扩大帮助进程的执行窗口和被终止概率。

**P2：错误处理不适合 App Intent 宿主。**

当前 `perform()` 没有捕获 `prepare()` 的异常，也没有为失败返回明确的 `IntentError` 或短消息；`syncAll()` 内部虽然捕获了多数单类同步错误，但帮助进程被取消、Core Data 初始化失败或其它未捕获错误仍会穿透到系统。用户看到的“无法与帮助程序通信”因此掩盖了真正的错误类型。

**P3：快捷指令缓存旧 metadata。**

动作已经能被找到，所以这不是首要原因。如果后续重新发布 Intent 定义，快捷指令仍可能保留旧动作缓存；删除旧动作后重新添加可以作为低成本排除项，但不能解释当前首次执行失败的主要证据。

#### 当前还缺少的决定性证据

目前没有 iPhone 上 Shortcuts/App Intents 的系统日志，也没有“执行后同步日志是否新增记录”的对照。因此暂时不能把故障 100% 定性为超时。应做以下最小化实验：

1. 在 App 内只开启一个轻量类别，将回填范围设为 7 天，关闭其它同步类别后执行快捷指令。
2. 分别测试 App 已打开和完全退出两种状态。
3. 观察快捷指令报错后，HealthMi 的同步历史和健康 App 中是否已经出现部分新增数据。
4. 再逐步打开心率、睡眠、运动和压力类别，记录从哪一类开始失败。

如果“单类别 + 7 天”成功，而全量失败，P0 的执行时间/资源解释基本得到验证；如果 App 打开时成功、退出后失败，应重点检查帮助进程的 Core Data/Keychain/HealthKit 上下文；如果同步日志完全没有新增记录，则失败发生在数据库准备、凭据读取或 HealthKit 初始检查阶段。

#### 推荐修复路线

有两个可行方向：

1. **可靠路线：恢复 `openAppWhenRun = true`。** App Intent 只负责请求打开主 App 并写入一次性触发标记，实际同步由已初始化的主 App 执行。优点是复用已经在真机验证成功的前台路径，避免把完整同步放进快捷指令帮助进程；代价是执行快捷指令时会打开 HealthMi。
2. **静默路线：保留 `openAppWhenRun = false`，把 Intent 改成轻量调度器。** `perform()` 只做凭据/配置检查、提交后台任务并快速返回；完整同步由 BGTask 或专用同步服务执行。优点是不打开 App；代价是快捷指令不能保证立即完成同步，系统也不保证后台任务马上运行。

当前证据支持优先采用路线 1 作为第一修复版本；如果必须保持完全静默，再单独设计路线 2，并为“已排队”“已完成”“失败”提供明确状态，而不是让 App Intent 直接承担九类数据的长链路同步。

### 9.15 路线二实施结果：快速排队与详细错误反馈（2026-11-25）

用户确认保留静默执行，采用快速排队路线。实现结果如下：

1. `SyncHealthDataIntent` 已从“直接执行九类完整同步”改为短事务：准备数据库、读取 Keychain、检查 HealthKit 可用性、检查已有活动运行、写入排队记录、提交 BGAppRefresh 请求，然后立即返回运行 ID。
2. 新增 `QueryLatestSyncStatusIntent`，可读取最近一次运行的状态、触发方式、排队/开始时间、成功类型、失败类型及每类错误的域、码和描述。
3. 新增 `SyncRunRecord` / `SyncRunStore`，保存最近 30 次运行；后台任务状态明确区分已排队、运行中、成功、部分失败、失败和取消，并把超过阈值仍未启动/完成的记录标记为 `HealthMi.SyncRun / code=408`。
4. `AppModel.syncAll` 通过运行 ID记录每一类成功或失败；HealthKit 未授权、凭据无效、网络、HTTP、小米 API、Keychain、数据库和取消等错误不再只依赖瞬时 `lastError`。
5. 后台完成后发送运行级本地通知。通知正文包括运行 ID、已完成类型和失败类型的完整错误文本；同步历史页面也显示最近一次运行摘要。
6. `BackgroundSync` 对系统过期和同步完成使用一次性完成门控，避免同一 `BGTask` 被重复 `setTaskCompleted`。
7. 网络退避和分页等待使用可抛出的任务 sleep，并识别 `URLError.cancelled`；取消不再触发后续重试，也不会被统计成普通网络失败。

#### 用户可见行为

- 快捷指令成功返回示例：`已排队（运行 ID：A1B2C3D4）`，并说明后台由系统稍后执行。
- 已有任务时返回已有运行 ID和当前状态，不重复排队。
- 排队前置检查失败时直接返回 `HealthMi.App / code=401`（无凭据）、`HealthMi.App / code=503`（HealthKit 不可用）或系统错误域/码，而不是通用“无法与帮助程序通信”。
- 后台任务尚未启动时，查询结果保持“已排队”；任务被系统取消时显示“已取消”，不会伪装成成功。

#### 仍需在 macOS/真机验证的项目

- iOS 16.4 目标构建和 App Intents metadata 重新生成；
- 真机快捷指令调用是否能够提交 `BGAppRefreshTaskRequest`；
- 系统实际启动后台任务后的完整同步、通知显示和查询动作；
- 网络/Keychain/HealthKit/小米 API 错误的域码是否与设备系统返回值一致。

本阶段本地提交：`0e524ed`、`75b07f6`。未执行远程 push。

#### 首次远程编译诊断

GitHub Actions run `45520859520` 使用 Xcode 16.4 编译 iOS 16 目标，发现两处 Swift 兼容问题：

1. `CredentialStore.loadThrowing()` 需要显式 `try`；
2. `AppShortcutsProvider` 的多动作声明使用结果构建器语法，不能手写 `[AppShortcut]` 数组字面量。

两处已修复。该 run 在编译阶段终止，因此没有生成本次新 IPA；下一次 workflow 的成功与否将决定能否进行安装包级验证。

#### iOS 16 远程构建与产物核验

修正后的 GitHub Actions run `45521059911` 成功完成 Xcode 16.4 / iOS 16.0 目标的 Release 编译和 IPA 打包。TrollStore artifact 已通过 `gh` 下载并核验：

- IPA SHA-256：`34BCB4FCD0CD0CA98140E05CE11EF44828A6D658C34C6224B5731BDB3DB44D9A`
- executable SHA-256：`F6D5157C0C63CF725432771C0979D8662FB06137CF08D966025A9C30FF4C82C5`
- `LC_CODE_SIGNATURE`、HealthKit entitlement、TrollStore Keychain entitlement 和用途说明均存在
- `Metadata.appintents/root.ssu.yaml` 已包含 `SyncHealthDataIntent_0` 与 `QueryLatestSyncStatusIntent_1`

这证明源码和 App Intents 元数据进入了可安装 IPA。仍需 iOS 16.3 真机验证系统是否接受快捷指令提交的 BGTask、后台任务何时实际运行、通知正文是否完整，以及查询动作能否读到最终状态。远程编译不能证明 iOS 后台调度时序。

#### 9.16 真机仍出现帮助进程退出及安全收敛

用户在 iOS 16.3 上运行 run `45521059911` 的 IPA 后，先后看到“无法与帮助程序通信”和“无法进行操作，因为 App 意外退出”。这证明编译与 entitlement 正常，故障发生在 App Intent 运行时。

Apple 文档要求 BGTask 必须在提交前注册，且所有 handler 要在应用启动结束前完成注册；同一进程第二次注册同一标识符会被系统终止。App Intent 帮助进程不保证走完与主 App UI 相同的启动路径，因此首版排队动作中的数据库准备和调度提交仍可能触发未注册任务或帮助进程资源问题。

安全收敛方案：

1. `SyncHealthDataIntent.perform()` 只读写 `UserDefaults` 队列，不打开 Core Data、不访问 Keychain、不初始化 HealthKit；
2. `BackgroundSync` 保存 `BGTaskScheduler.register` 的真实返回值；
3. 只有返回值为成功时才从快捷指令提交立即调度，否则返回“已排队”，等待已有的周期后台请求；
4. 凭据、数据库、HealthKit 和网络错误统一由后台同步写入详细运行结果。

该版本仍需重新编译和真机验证。若仍提示 App 意外退出，则下一层证据必须是设备上的 `HealthMi` / Shortcuts `.ips` 崩溃报告，不能再仅靠静态推断。

## 9.17 最新静默排队版本的远程构建与 IPA 核验（2026-11-25）

### 构建证据

本次继续使用个人私有仓库 `lu1ul/HealthMi-private`，没有向原仓库 `ShawnDiego/HealthMi` 推送。GitHub Actions run `45522292408` 对提交 `ab414c15773a7ba7a50c61d4dd2f3c4e3a4aad32` 执行了 Xcode 16.4 / iOS 16.0 设备目标构建，结果为成功。该 run 的构建步骤全部通过：XcodeGen 生成工程、Release 编译、unsigned IPA 打包、TrollStore entitlement 注入、解包后二次检查和 artifact 上传。

本次产物通过 `gh` 下载，没有使用浏览器：

- `build/HealthMi-trollstore-shortcut-queue-45522292408/HealthMi-trollstore-healthkit-ipa/HealthMi-trollstore-healthkit.ipa`
- `build/HealthMi-trollstore-shortcut-queue-45522292408/HealthMi-unsigned-ipa/HealthMi-unsigned.ipa`

### IPA 独立核验

TrollStore IPA SHA-256 为 `885ACBCA4A3E90EB4468D4A5321C4248F5FA23350475412E8B856857B034879B`；unsigned 对照 IPA SHA-256 为 `057242D2975FDDCF2FEF9466296E6523C3166F474EDF7AA6957E351146F867F4`。

对 TrollStore IPA 解包后的 `Payload/HealthMi.app/HealthMi`、`Info.plist` 和 `Metadata.appintents` 进行本地检查，结果如下：

| 检查项 | 结果 |
|---|---|
| 最低系统版本 | `16.0` |
| Bundle ID | `com.healthmi.HealthMi` |
| App 版本 | `1.1.0` |
| `LC_CODE_SIGNATURE` | 存在 |
| HealthKit entitlement | `com.apple.developer.healthkit = true` |
| TrollStore application identifier | `TROLLTROLL.*` |
| TrollStore team identifier | `TROLLTROLL` |
| Keychain access groups | `TROLLTROLL.*`, `com.apple.token` |
| App Intents metadata | 存在 |
| 同步动作 | `SyncHealthDataIntent_0` 存在 |
| 状态查询动作 | `QueryLatestSyncStatusIntent_1` 存在 |
| 后台任务白名单 | `com.healthmi.HealthMi.sync` 存在 |
| HealthKit 用途说明 | Share / Update 均存在 |
| `embedded.mobileprovision` | 不存在，符合 TrollStore 产物 |

这组证据排除了“最新 IPA 没有编译进 App Intents”以及“最新 TrollStore IPA 没有 HealthKit/Keychain entitlement”两类包级问题。它仍不能证明快捷指令后台任务已经在 iOS 16.3 真机上被系统启动，因为 BGTask 的实际调度受系统资源、用户行为和设备状态影响。

### 对当前快捷指令故障的更新判断

最新提交把 `SyncHealthDataIntent.perform()` 收敛为只操作共享 `UserDefaults` 运行队列：不初始化 Core Data、不读取 Keychain、不检查 HealthKit、不运行网络同步，也不等待 HealthKit 写入。只有当前进程确认 `BGTaskScheduler.register` 成功时，才尝试提交立即调度；否则保留排队记录，等待主 App 启动时已经安排的周期刷新。完整同步、详细错误和本地通知都由后台任务处理。

因此，若用户安装 run `45522292408` 的 TrollStore IPA 后仍出现帮助进程通信错误，优先怀疑范围已经缩小为：

1. iOS 16.3 / TrollStore 对 App Intents 帮助进程的运行时兼容性；
2. App Intent 进程在 `UserDefaults` 写队列或返回 `IntentDialog` 时被系统终止；
3. 快捷指令保存了旧版动作元数据或旧动作实例；
4. 设备侧存在未提供的 `Shortcuts` / `HealthMi` 崩溃报告；
5. 后台任务未启动导致“已排队”长期不变，但这本身不应再表现为帮助进程崩溃。

下一次真机验证要先删除旧版 HealthMi，并从新包重新添加两个快捷指令动作。如果仍崩溃，必须导出 `设置 → 隐私与安全性 → 分析与改进 → 分析数据` 中的 `HealthMi-*.ips` 和 `Shortcuts-*.ips`，否则无法区分 App Intent runtime、BGTask 注册和 TrollStore 伪签名环境造成的终止。

独立解析最终 IPA 的 Mach-O 签名 SuperBlob 后，确认 entitlement blob 中包含上述 HealthKit、TrollStore application/team identifier、`get-task-allow` 与 Keychain access groups。主程序 SHA-256：`7d7171b55d8ed693355d8b3eccc073718d73e4495fb584e01d358d088494d300`。

### 9.18 快捷指令仍崩溃：基于最新用户反馈的根因重排（2026-11-25）

#### 新证据及其含义

用户反馈：快捷指令运行后仍显示“无法与帮助程序通信”，再次运行又显示“无法进行操作，因为 App 意外退出”。本分析按用户已测试最新 TrollStore IPA `45522292408` 处理；若手机上安装的不是该 run 产物，先核对安装包。

这条反馈使上一节“完整同步链路太长，导致 Intent 被系统回收”的解释明显降级：最新 `SyncHealthDataIntent.perform()` 不再启动 Core Data、Keychain、HealthKit、网络或完整同步，却仍出现问题。包级证据也已确认最新 IPA 有 `Metadata.appintents`、两个 Intent 名称和 entitlement；因此“未生成动作 metadata”与“HealthKit entitlement 缺失”不能解释这次快捷指令运行时现象。

两个系统提示不一定代表两个独立故障。“无法通信”表示 Shortcuts 没有得到预期的 Intent 响应；“App 意外退出”说明某个承载该动作的 App 进程已退出，但系统提示本身没有给出退出进程名、异常类型或调用栈。它们可能是同一进程故障在两次调用中的不同表现。

#### 纠正关于“帮助进程”的旧推断

`project.yml` 只有 `HealthMi` application target，没有 App Intents extension target；`SyncHealthDataIntent` 和 `QueryLatestSyncStatusIntent` 都编译在主 App target。Apple 文档说明，系统可在 App 前台或后台运行 Intent；只有将 Intent 类型放到 App extension 时，才明确形成“与主 App 分离的 extension process”。所以仅凭 `openAppWhenRun = false`，不能断定本项目每次都在独立帮助进程执行，也不能据此断定它绕过了 `HealthMiApp` 的启动代码。[Apple：Creating your first app intent](https://developer.apple.com/documentation/appintents/creating-your-first-app-intent)；[Apple：`openAppWhenRun`](https://developer.apple.com/documentation/appintents/appintent/openappwhenrun-223b1)

#### 当前代码实际调用顺序

1. Intent 执行 `SyncRunStore.markStale()`，读取并可能改写 `UserDefaults` 中的 JSON 运行记录。
2. 执行 `SyncRunStore.active()`。若有 `.queued` 或 `.running` 记录，直接构造对话并返回，不会创建新记录，也不会调用 BGTask 提交。
3. 若没有活动记录，`SyncRunStore.create(trigger: .shortcut)` 先把 `.queued` 记录写入 `UserDefaults`。
4. 然后 `BackgroundSync.scheduleFromIntentIfRegistered(immediate: true)`：只有本进程的注册标记为 true 时才调用 `BGTaskScheduler.submit`，并把 `earliestBeginDate` 设为约 1 秒后；否则不提交，仍准备返回“已排队”。
5. Intent 生成 `IntentDialog` 并返回。同步任务在后台 handler 中另外执行。

代码的外层 `do/catch` 会把普通 Swift 错误转成一段对话，而不是抛出；因此若 Shortcuts 确实显示通用通信错误或 App 进程意外退出，故障更像未被 Swift `catch` 捕获的系统终止/致命错误，或发生在调用 `perform()` 之前/返回之后。正常的 JSON、编码或 `BGTaskScheduler.submit` 抛错按现有代码应走 catch 分支；它们本身不应直接显示成进程崩溃。

#### 根因候选排序

| 顺序 | 候选原因 | 为什么仍成立 | 如何证伪或确认 |
|---|---|---|---|
| 1 | 冷启动阶段 BGTask handler 注册触发系统启动断言 | `HealthMiApp.init()` 直接调用 `BackgroundSync.register()`；项目没有显式 `UIApplicationDelegateAdaptor` 的 `application(_:didFinishLaunchingWithOptions:)` 注册点。Apple 要求传统 BGTask launch handler 在 `applicationDidFinishLaunching(_:)` 结束前全部注册，并说明同一标识符重复注册会杀死 App。SwiftUI `App.init()` 是否在所有 iOS 16.3 冷启动路径都满足这个时限，必须用崩溃报告核实，不能仅从源码判定必然违规。[Apple：BGTaskScheduler.register](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register%28fortaskwithidentifier%3Ausing%3Alaunchhandler%3A%29) | `.ips` 的 `Termination Reason`、`Exception Type`、崩溃线程；搜索 `BGTaskScheduler`、`launch handler` 或重复注册相关信息。若确认，再把注册搬到明确的 UIKit launch callback 并重新构建。 |
| 2 | 已提交的立即 BGTask 随后启动完整后台同步并崩溃 | `earliestBeginDate = now + 1s` 只是最早开始时间；系统可能很快启动后台任务。这个任务会初始化 Core Data、恢复凭据、访问 HealthKit 并执行同步。主 App 前台同步成功不能证明这条后台启动链路成功。 | 查询状态是否从 `.queued` 变为 `.running`；检查通知/同步历史是否有运行结果；崩溃报告的进程与时间是否落在快捷指令返回之后。 |
| 3 | Intent 主体或 Shortcuts/App Intents runtime 与 iOS 16.3/TrollStore 组合不兼容 | 轻量 Intent 仍经过 `@MainActor` 调度、JSON 解码、`IntentDialog` 生成和系统结果序列化；构建与 metadata 检查不覆盖 iOS 16.3 的真机执行。 | 单独运行“查询最近同步状态”动作，并与同步动作对照；查看 `.ips` 的异常线程是否进入 `perform()`、Foundation/Swift runtime 或 AppIntents。 |
| 4 | 快捷指令保存了旧动作定义 | 多次发布过同名 Intent；已有快捷指令可能仍引用旧定义。它不能解释确定的 App 崩溃，但重新添加可低成本排除。 | 在快捷指令中删除旧动作，从 HealthMi 动作列表重新加入；仍失败则不再把缓存当主因。 |

#### 第二次运行为什么是关键线索

如果第一次运行已完成 `SyncRunStore.create()`，但在排队记录写入后、Intent 响应返回前崩溃，那么第二次运行应在 `active()` 发现旧 `.queued` 记录，并绕过 `scheduleFromIntentIfRegistered()`。因此：

- 若“查询最近同步状态”能正常显示“已排队”，说明至少一次 Intent 已成功写入运行记录，故障很可能在入队后调度/返回或随后 BGTask 路径；
- 若查询动作也出现“无法通信/App 意外退出”，故障更偏向 App 启动、App Intents runtime 或共享的 `SyncRunStore` 访问路径；
- 若状态显示 `.running`，表明 BGTask handler 已经领取记录，调查重点应转到后台同步执行和取消/终止日志；
- 若状态没有任何记录，故障很可能发生在首次写入完成之前，或者系统实际执行的仍是旧版动作/旧 IPA。

这是根据当前代码控制流得出的区分实验，不代表已经知道设备上哪一步崩溃。

#### 最小设备诊断顺序

1. 在手机确认安装的是 run `45522292408` 的 TrollStore IPA；下载文件 SHA-256 应为 `885ACBCA4A3E90EB4468D4A5321C4248F5FA23350475412E8B856857B034879B`。此包主程序最低系统版本为 iOS 16.0。
2. 删除快捷指令里的旧“同步健康数据”动作，从 HealthMi 动作列表重新添加。
3. 单独运行“查询最近同步状态”，记录它能否返回，以及状态是“暂无记录 / 已排队 / 同步中 / 失败”。随后再运行同步动作，观察状态是否变化。
4. 从 iPhone 打开“设置 → 隐私与安全性 → 分析与改进 → 分析数据”，找到故障时间附近最新的 `HealthMi-*.ips`、`Shortcuts-*.ips` 或 `AppIntents-*.ips`（若存在），通过“共享 → 存储到文件”导出。保留报告头部的 `Process`、`Exception Type`、`Termination Reason`、`Triggered by Thread` 和崩溃线程堆栈；分享前可遮掉设备名、用户名等个人信息。
5. 以 `.ips` 的实际 `Process` 和 `Termination Reason` 决定修复点。若没有 `.ips`，下一版先做只返回固定文本的最小 Intent 探针，逐步加回 UserDefaults 读写，再加 BGTask 提交；这比继续猜测或一次性重写完整同步更能定位崩点。

#### 本轮结论

目前最直接的代码风险是 SwiftUI `App.init()` 中的 `BGTaskScheduler.register()` 是否满足 iOS 16.3 冷启动注册时限；其次是快捷指令提交后马上启动的 BGTask 全量同步。可是现有证据不足以把“App 意外退出”定责给其中一项。我们尚未取得 iPhone `.ips`，也尚未确认状态查询动作的对照结果。本轮因此只更新诊断结论和最小复现步骤，不直接改动 Intent 行为；擅自改成打开 App 或删掉 BGTask 会改变用户已选定的静默路线，而且可能掩盖真正崩溃点。

官方资料：

- [Apple：Creating your first app intent](https://developer.apple.com/documentation/appintents/creating-your-first-app-intent)
- [Apple：`openAppWhenRun`](https://developer.apple.com/documentation/appintents/appintent/openappwhenrun-223b1)
- [Apple：`BGTaskScheduler.register`](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register%28fortaskwithidentifier%3Ausing%3Alaunchhandler%3A%29)
- [Apple：Background Tasks](https://developer.apple.com/documentation/backgroundtasks/)
