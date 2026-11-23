# HealthMi 项目代码全面审查与 HealthKit 权限故障定位

> 审查日期：2026-11-23
> 源码审查基线：`82fef0f`（`fix: weak link SwiftData for iOS 16`；后续提交仅更新文档）。
> 结论类型：静态代码审查 + 本地 IPA 包结构检查；本轮没有修改业务源码，没有运行构建或测试，也没有在 GitHub runner 上运行模拟器。

## 一、结论摘要

### 对“是 TrollStore 安装问题还是项目代码问题”的判断

**现有证据更指向本项目的 IPA 构建/签名配置，而不是 iOS 16.3 或 TrollStore 本身故障。**如果 iPhone 上装的确实是仓库工作流产出的 `HealthMi-unsigned.ipa`，HealthKit entitlement 很可能没有随应用可执行文件进入最终包；这是当前最直接、证据最强的原因。

项目源代码中确实声明了 `com.apple.developer.healthkit`，也确实调用了 HealthKit 授权 API；但设备 IPA 工作流明确使用 `CODE_SIGNING_ALLOWED=NO` 和 `CODE_SIGNING_REQUIRED=NO`，并且本地 IPA 包内没有 `_CodeSignature` 目录或 provisioning profile。Xcode 工程中的 entitlement 声明不会因为它存在于 `project.yml` 或 `.entitlements` 文件中，就自动成为未签名可执行文件的 HealthKit 权限。

HealthKit 调用失败时，仪表盘按钮通过 `try?` 丢弃错误，所以即使系统 API 返回 entitlement、配置或 HealthKit 错误，界面也没有任何提示。这是可以从当前代码直接确认的 UI 诊断缺陷。

**尚不能最终断定 iPhone 上那份二进制实际缺少 entitlement。**当前工作区只有本项目未签名 IPA，没有用户最后用 TrollStore 或其它工具处理、安装的那一份 IPA，也没有手机导出的最终可执行文件或 entitlement 清单。如果安装工具在安装前确实给主程序补入了正确的自定义 entitlement，结论需要据此修正。

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

**重要边界：**TrollStore 支持安装带任意 entitlement 的应用，因此“可以安装并启动”不等于“安装后一定有 HealthKit entitlement”，也不能单独证明安装器有问题。需要核对实际安装的 IPA/应用主程序中是否存在 `com.apple.developer.healthkit = true`。当前没有用户安装用的最终 IPA，也没有设备侧 entitlement 清单；所以根因判断是“更可能是构建包问题”，不是对设备/TrollStore 的最终定责。[TrollStore 官方项目说明](https://github.com/opa334/TrollStore/blob/main/README.md)

TrollStore 官方说明的 entitlement 使用流程要求先通过 `ldid` 将自定义 entitlement 伪签进应用主程序，再由 TrollStore 安装并保留。仓库的 IPA 工作流没有运行 `ldid`，也没有执行 Xcode 代码签名；因此如果安装包未经其它处理直接交给 TrollStore，这条构建链路没有为 HealthKit 准备 entitlement。[TrollStore 官方 README](https://github.com/opa334/TrollStore/blob/main/README.md)

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

以下按影响分级。它们是静态审查结论，尚未通过本轮运行测试确认；本节不代表它们都造成了当前 HealthKit 弹窗故障。

### A. HealthKit 与界面诊断

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

#### H3｜P2：授权状态指示器只检查步数写入权限

**位置：** `HealthMi/App/AppModel.swift:130-139`

`healthKitAuthorized` 通过 `HKQuantityType(.stepCount)` 的 `authorizationStatus` 得出一个全局“已授权/未授权”。这个状态只能说明该类型的写入状态，不能说明其它写入类型或读取权限状态；尤其不能用它判断用户是否允许读取既有健康数据。

**影响：**界面可能显示“未授权”，即使用户已允许部分类型；也可能给“读取权限”造成误导。它不是导致系统弹窗缺失的直接原因，但会干扰定位。

**建议：**UI 将“请求是否成功调用”“写入样本是否成功”与“读取是否返回数据”分开表达；不要声称能从 HealthKit 查询到用户的读取授权开关。

#### H4｜P2：HealthKit 读取错误被折叠成空数据

**位置：** `HealthMi/Health/HealthKitReader.swift:25-55, 82-115`

摘要与趋势查询多处用 `try?`，发生授权、entitlement 或查询错误时就返回 `nil` / 空数组。界面显示“—”或“暂无趋势数据”，难以区分确实无数据与查询失败。

**建议：**保留查询错误并在界面区分“无样本”“未授权/不可用”“查询失败”。这对 HealthKit 排查很重要，但应排在补上 entitlement 和按钮错误反馈之后。

### B. iOS App 同步与数据一致性

#### S1｜P1：缺少或不完整的 API 分页字段会被当作成功并推进游标

**位置：** `HealthMi/MiFitness/MiAPIClient.swift:181-189, 210-217, 239-247`、`HealthMi/Sync/SyncEngine.swift:105-120, 253`

响应顶层 `code` 解析通过后，如果 `result` 丢失或类型不符，客户端返回空字典；分页解析又会把缺失/类型错误的 `data_list` 或 `sport_records` 当作空页，把缺失/错误的 `has_more` 默认成 `false`，并在 `has_more=true` 但 `next_key` 缺失时直接结束。同步引擎随后会把这次不完整响应当成功并写入新的 `highWater = Date()`。若服务端协议变化、短暂返回错误结构或响应被截断，可能只导入部分数据却推进游标，后续增量不再覆盖全部缺失区间。

**建议：**严格校验 `result` 及必需的列表/分页字段；不合法响应抛 `invalidResponse`，不得更新游标。

#### S2｜P1：数字字符串解析失败可能被误判为成功码，极端值还可能触发运行时错误

**位置：** `HealthMi/MiFitness/MiModels.swift:147-150`；调用点 `MiAPIClient.swift:185-187`

字符串转数字失败时使用 `Int(Double(s) ?? 0)`，会把无效字符串变成 `0`。在 API `code` 字段中，`"not-a-number"` 这类异常响应可能因此被解释为成功码 0，再走到“空 result”路径。该转换还会先把整数文本转成 `Double`，再向零截断为 `Int`，例如小数字符串会被静默取整；如果解析出的浮点值超出 `Int` 可表示范围，转换可能触发运行时错误。此 helper 也用于解析来自网络的时间戳、步数、心率和睡眠编码，因此不只是 API code 的协议校验风险。Apple 的 Swift 文档说明，浮点转整数会截去小数，输入超出目标整数范围时运行时可能报错。

**建议：**整数文本直接用可失败的 `Int(s)` 解析；若协议确实允许小数，先检查数值为 finite 且位于目标整数范围，再按明确规则转换。无效数值应返回 `nil` 并让协议校验失败，不要静默变成 0。

#### S3｜P2：切换小米账号不会清理 HealthKit 中旧账号记录，external UUID 又不含账号

**位置：** `HealthMi/Health/TypeMapper.swift:19-35, 43-54, 190`、`HealthMi/MiFitness/MiModels.swift:33, 75, 81, 119`、`HealthMi/App/AppModel.swift:107-117`

应用退出账号时会清除本地游标/压力/日志，但不会删除 HealthKit 中旧样本。若之后换账号，步数 UUID 按日期生成，心率/血氧/体重 UUID 按整秒时间生成，运动 UUID 按 workoutId 生成，均没有账号命名空间。新账号若同一时间有记录，会被旧 UUID 去重；不同账号的值也可能继续并存在 HealthKit。

**建议：**决定账号切换语义；至少让应用生成的 external UUID 稳定包含账号作用域，或提供清楚的数据保留/清理行为。注意不能自动删除用户自己或其它来源写入的 HealthKit 数据。

#### S4｜P2：区域时区固定 UTC 偏移，日期计算不统一

**位置：** `HealthMi/MiFitness/MiRegion.swift:18-29`、`HealthMi/Sync/SyncEngine.swift:64-75, 148-165`、`HealthMi/Health/TypeMapper.swift:246-258`、`HealthMi/Health/HealthKitReader.swift:51-53`；Python 对照 `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/adapters/mi_fitness_cloud.py:271-283` 和 `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/config.py:19-25`

欧洲固定 UTC+1、美国固定 UTC−8，无法涵盖夏令时与多时区；API 窗口、按区域映射日样本、HealthKit 读回趋势又混用设备当前 Calendar。跨时区或 DST 日期附近可能错日、窗口重叠或趋势错位。`TypeMapper.calendar` 还是静态缓存，启动后切换地区时不会重建。另一个跨实现差异是 Python adapter 只对 `cn` 使用 UTC+8，所有非 `cn` 区域都用 UTC；Swift 则对 `ru/de/us` 使用 UTC+3/+1/−8。相同非中国区日期字符串会生成不同的 API epoch 查询窗口。Python 的 `config.timezone` 目前只由 `get_profile` 回传，没有参与窗口换算。仅凭仓库代码无法确定哪套边界符合小米服务端的地区约定，但两套实现的输出不等价。

**建议：**使用带 DST 规则的 IANA 时区，明确统一日界线的业务时区；让 Swift 与 Python 按相同规则计算请求窗口；区域变化时重建相关 Calendar。先用包含 `zone_offset`、`zone_name` 和日边界附近样本的脱敏记录确认服务端约定。

#### S5｜P2：API 同步过程中 token 失效时连接状态可能仍显示正常

**位置：** `HealthMi/MiFitness/MiAPIClient.swift:41-45`、`HealthMi/App/AppModel.swift:296-313, 324-328`

API 客户端识别 `code=70016`，但 `AppModel.isAuthError` 只识别登录阶段的 `MiLoginError.loginRejected`。已经连接后在数据接口遇到 `MiAPIError.api(code:70016)`，会记一类数据同步失败，却不一定设置 `authNeedsRefresh` 或更新 `connected` 状态。

**建议：**同步错误统一映射登录/令牌失效状态，在界面明确要求刷新凭据；避免重复重试永久失效的 token。

#### S6｜P2：取消请求时重试与分页等待可能继续运行

**位置：** `HealthMi/MiFitness/MiAPIClient.swift:105-127, 222, 251`；`HealthMi/Sync/BackgroundSync.swift:23-37`；`HealthMi/App/SyncIntent.swift:26-31`

退避和分页间隔使用 `try? Task.sleep`，取消错误会被忽略；网络错误又被统一包装为可重试错误。快捷指令超时或系统后台任务过期时，任务可能继续进入下一轮请求，而不是及时结束。

**建议：**对 `CancellationError` 立即向上传播；分页循环前检查取消状态；后台任务确保完成回调仅由一个路径负责。

#### S7｜P2：运动写入在关联心率失败时可能留下“已保存但不完整”的 workout

**位置：** `HealthMi/Health/HealthWriter.swift:47-90`、`HealthMi/Sync/SyncEngine.swift:228-253`

代码先 `finishWorkout()` 保存 workout，之后才通过 `store.add` 加入平均/最大心率。若后续加入失败，方法抛错；重试时 `existingExternalIDs` 已能找到该 workout，正常增量会跳过，不会自动补写缺失关联心率。

**建议：**把运动和关联样本的恢复语义设计为可重试/可修复，或者将不完整状态记录下来供重试；用模拟 `store.add` 失败的测试覆盖。

#### S8｜P3：HealthKit 分页遇到同一开始时间超过页长时可能不前进

**位置：** `HealthMi/Health/HealthWriter.swift:17-39, 130-157`

分页锚点仅取最后一个样本的 `startDate`，下一页查询包含该边界（`>= anchor`）。若超过 1000 条样本共享相同开始时间，锚点可能不变，查询重复相同一页。

**建议：**使用可严格推进的分页游标/查询机制；至少为大量同时间戳样本增加终止保护与回归测试。

#### S9｜P3：凭据先写入 Keychain、后验证登录

**位置：** `HealthMi/App/AppModel.swift:95-105`

`saveCredentials` 先保存 userId/passToken，再连接小米 API。若验证失败，凭据仍会留在 Keychain；下次启动 `bootstrap()` 只要读到凭据就会将 `isConfigured` 设为 true。

**建议：**先验证临时凭据，再保存成功的会话；或登录失败后回滚新写入值。

#### S10｜P3：用户关闭所有同步类型后重启会恢复全选

**位置：** `HealthMi/App/AppModel.swift:48-50, 71-92`

`loadEnabledTypes()` 只有在持久化集合非空时才覆盖默认值。用户有意清空全部类别时，空数组会被解释为“没有设置过”，重启后恢复全部类型。

**建议：**区分“键不存在”与“键存在但数组为空”。

#### S11｜P1：强制回填先删除旧 HealthKit 样本，后写入失败会造成数据缺口

**位置：** `HealthMi/Sync/SyncEngine.swift:90-107, 233-249`

`forceBackfill` 对普通健康样本先按 external UUID 删除 HealthKit 中范围内的旧记录，再调用 `writer.save` 写入新记录。删除成功但新样本保存失败时，旧记录已丢失，本次同步会报错且游标不会前进。运动回填同样先删除旧 workout 和关联心率，再调用 `saveWorkout`。删除和保存不是本项目可包成单个事务的操作，因此当前顺序存在可见的数据丢失窗口。

**建议：**为回填设计可恢复的两阶段替换：先确认完整的新数据和可写入状态，再替换旧样本；若 HealthKit 接口要求先删后写，需保留足以恢复旧样本的内容或记录补偿任务。重点覆盖“删除成功、保存失败”和 workout 已保存但关联心率写入失败。

#### S12｜P2：强制回填不会清理上游已消失的数据

**位置：** `HealthMi/Sync/SyncEngine.swift:88-118, 228-253`

普通类型只在 `fetchAndMap` 返回的 `groups` 上执行回填删除。如果指定类型本次返回空集合，循环体不执行，HealthKit 中不再出现在小米响应里的旧记录仍会保留。运动回填也只对新响应里仍存在的 `draft` 删除和重写旧 workout，不会清理范围内已从云端消失的 workout。因此“全量重拉并重写”在空响应或已删除记录场景下实际只会重写当前仍返回的记录。

**建议：**先确认 API 响应完整、分页结束且解析成功，再根据新旧 external UUID 集合差异做范围清理；协议错误或分页不完整时保留旧样本。

#### S13｜P2：全局同步被步数写入权限统一拦截

**位置：** `HealthMi/App/AppModel.swift:124-138, 184-194`

`healthKitAuthorized` 只表示 `stepCount` 的 HealthKit 写入状态。`syncAll` 在同步任何数据类型前都要求它为 `true`，否则直接返回。用户即使只启用其它可写类型，也会因步数被拒绝而被全局阻止；压力数据本身存 Core Data、不写 HealthKit，却同样无法同步。

**建议：**按启用的数据类型分别处理 HealthKit 写入失败；HealthKit 之外的数据（至少压力）不应依赖步数授权。界面状态应拆分为授权请求状态、步数写入状态和各类型的实际写入结果，避免一个状态代表所有权限。

#### S14｜P2：未识别的睡眠阶段被默认伪装成浅睡

**位置：** `HealthMi/MiFitness/MiParser.swift:113-123`

当前只明确映射 state `2` 至 `5`，其余值（包括缺失或未来新增编码）全部返回 `.light`，再由 `TypeMapper` 写成 HealthKit `asleepCore`。这会把未知或异常记录伪造成有效浅睡样本，影响睡眠分期与统计。

**建议：**让解析结果能表达未知或无效状态；未知分期应跳过或保留原始编码并记录诊断，避免默认映射为浅睡。用已确认的小米编码样例覆盖所有支持的状态值。

#### S15｜P1：总卡路里被写成 HealthKit 活动能量

**位置：** `HealthMi/MiFitness/MiParser.swift:18, 26, 36, 40-54`；写入映射见 `HealthMi/Health/TypeMapper.swift:34-39`；对照 `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/adapters/mi_fitness_cloud.py:463-496` 和 `tools/mi-fitness-mcp-cn/tests/test_mi_fitness_cloud.py:40-76`。

Swift 端先把 `steps` key 的 `calories` 累加到 `kcalFromSteps`，再把 `calories` key 返回的总量覆盖到同一字段，最终赋给 `MiDailyActivity.activeKcal`。`TypeMapper.dailyActivitySamples` 将其作为 `HKQuantityType(.activeEnergyBurned)` 写入健康数据。Python 实现则把 `steps` 中的 calories 保存为 `active_kcal`，把独立 `calories` key 认作包含基础代谢的 `total_kcal`，并由测试验证两者分别为 3 和 12。Swift 的现有测试使用 100+50 与 210，并断言 `activeKcal == 210`，与 Python 端的已测试语义相反。

**影响：**如果这两个 API key 的字段语义与仓库 Python 实现及测试一致，App 会把每日总消耗而非活动消耗写入 Apple 健康的活动能量，通常会显著高估活动热量。现有 Swift 测试会让该错误持续通过。

**建议：**活动能量只从 `steps` 数据的活动 calories 计算；若产品需要总消耗，应在模型中单独保留，不映射到 `activeEnergyBurned`。先用脱敏的真实 API 响应或稳定样例确认字段语义，再修正 Swift 与 Python 的共同夹具和测试期望。此问题是代码/数据映射问题，不是 TrollStore 权限弹窗问题。

#### S16｜P2：Swift App 与 Python 工具的睡眠阶段编码不一致

**位置：** `HealthMi/MiFitness/MiParser.swift:113-123`；`tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/adapters/mi_fitness_cloud.py:418-429`；Swift 测试见 `HealthMiTests/MiParserTests.swift:38-64`。

Swift App 映射为 `2=deep, 3=light, 4=REM, 5=awake`；Python MCP 工具映射为 `1=deep, 2/3=light, 4=awake, 5=REM`。Swift 源码注释称其映射已按实际数据修正，Python 映射为旧版本，但仓库没有保留可复核的原始响应夹具或协议文档来独立判定哪套映射符合小米当前协议。Swift 测试只覆盖 `2/4/5`，没有覆盖 `3`、未知编码或与 Python 共享的样例；Python 测试也未覆盖该映射。

**影响：**两个工具面对相同睡眠记录会输出不同阶段；若旧 Python 映射仍被下游使用，REM、深睡和清醒时长会错分。该差异不影响 HealthKit 授权弹窗，也不能仅凭代码断言 Swift 当前映射错误。

**建议：**保存脱敏的真实云端睡眠记录作为黄金夹具，明确每个 state 的协议语义，并让 Swift 与 Python 共用同一组预期映射。未知值应保留为未知或跳过，不能默认伪装成浅睡（参见 S14）。

#### S17｜P2：睡眠总时长的区间边界与按日归属未定义

**位置：** `HealthMi/Health/HealthKitReader.swift:27-44, 50-84, 126-145, 168-182`。

`summary(days:)` 从当前时刻向前回退日历天数，并把查询返回的每个睡眠样本完整时长相加；当前 `predicateForSamples` 调用没有启用 `strictStartDate` / `strictEndDate`，因此与所选区间相交的样本也会返回，跨越起始边界的样本会把区间外时长一并计入总量。趋势查询则把每段睡眠的完整分钟数归到 `sample.startDate` 所在日，没有按午夜切分；例如跨午夜的一段睡眠会全部落在开始日。是否应按“入睡夜晚”归属需要产品定义，但当前数据不能解释为严格的日历日睡眠分钟数。查询还会直接相加所有来源的睡眠样本，没有检查来源或重叠区间；若不同来源记录了重叠睡眠，也会重复累计。

**影响：**最近 N 天摘要可能包含边界之外的睡眠；趋势图可能把整晚显示在入睡日；多来源重叠记录可能高估睡眠时长。实际误差取决于设备样本的时间范围和来源。

**建议：**明确采用日历日切分还是睡眠夜归属；对查询区间边界裁剪样本时长，并按选定策略处理跨午夜区间。多来源样本需要有明确的来源优先级或重叠去重规则。Apple 将 `strictStartDate` / `strictEndDate` 定义为要求样本起止时间落在目标区间内的选项；当前调用未传这些严格选项，因此应按可能跨界返回的样本处理。

#### S18｜P2：快捷指令/后台任务取消与完成路径没有统一收敛

**位置：** `HealthMi/App/SyncIntent.swift:20-34`；`HealthMi/Sync/BackgroundSync.swift:25-37`；`HealthMi/App/AppModel.swift:209-212, 270-278`；重试等待见 `HealthMi/MiFitness/MiAPIClient.swift:105-127, 218-251`。

快捷指令创建了独立 `Task` 执行 `syncAll`，只由 55 秒 watchdog 主动取消；代码没有把 `perform()` 调用方的取消显式传递给该任务。`syncAll` 检查到取消后只 `break` 数据类型循环，随后仍更新状态、刷新 HealthKit 摘要并可能发送通知。API 重试和分页等待用 `try? Task.sleep`，取消产生的错误被吞掉：重试等待取消后仍可能尝试下一次请求，分页等待取消后会直接进入下一页。

后台刷新有两个完成入口：`expirationHandler` 异步安排取消并立即调用 `setTaskCompleted(false)`；同步任务正常返回后也调用 `setTaskCompleted(success:)`。两条路径没有共享的一次性完成门闩；若过期与同步结束并发，存在重复报告完成的竞态。取消分支在 `guard !Task.isCancelled else { return }` 处提前返回，也不会清空静态 `syncTask` 引用。

**影响：**系统已过期或快捷指令调用方已取消后，仍可能继续做重试等待和 HealthKit 读取；后台任务可能出现重复完成报告或保留过期任务引用。此问题不解释授权表单/来源列表缺失。

**建议：**让取消沿结构化任务传播；重试等待遇到取消立即抛出，循环每个请求边界都检查取消；`syncAll` 取消后尽早返回，不再运行摘要查询；后台任务用单一完成状态协调过期与正常完成，并通过 `defer` 清除任务引用。用“取消与同步完成同时发生”的测试验证完成回调只走一次。

#### S19｜P1：增量同步会永久跳过已写入日期的更新值

**位置：** `HealthMi/Health/TypeMapper.swift:12-39`；`HealthMi/Sync/SyncEngine.swift:64-75, 85-118`；`HealthMi/Health/HealthWriter.swift:15-37`。

步数、距离和活动能量的样本覆盖整日，external UUID 只由日期组成（例如 `mi_fitness_steps_2026-11-23`）。增量同步会重叠查询前一天以获取迟到数据，但正常分支只按 external UUID 过滤“已经存在”的样本，不比较数值，也不替换原样本。因此同一天第一次同步写入部分累计值后，后续同步即使重新取到更大的步数/距离/热量，也会因 UUID 相同而跳过。按时间戳生成 UUID 的其它指标同样不会自动更新同一 ID 的修正值。

**影响：**在当天中途触发同步后，HealthKit 中当天的总步数、距离和活动能量会停留在首次写入时的部分值；上游迟到或修正的相同记录也可能一直旧到用户手动强制回填。一天重叠窗口只能重新取数，不能修复去重策略。

**建议：**对会变化的聚合/修正数据实施按 external UUID 的内容比较和安全替换，或明确延迟写入当天未完成的聚合数据并仍处理迟到修正。添加同一天连续两次返回不同计数的回归场景，确认最终 HealthKit 样本更新为新值。

#### S20｜P2：强制回填心率会删除 workout 关联心率样本

**位置：** `HealthMi/Sync/SyncEngine.swift:89-105, 233-249`；`HealthMi/Health/HealthWriter.swift:61-91`；`HealthMi/Health/TypeMapper.swift:178-195`。

仅当强制回填 `.heartRate` 本次确实从 API 取到并映射出非空心率样本组时，代码才会执行这一删除。此时 `existingExternalIDs` 会查询该 HealthKit 心率类型下范围内所有带 external UUID 的样本，并删除范围内的所有 ID。普通同步心率使用 `mi_fitness_hr_*` / `mi_fitness_resting_hr_*`，但 `saveWorkout` 也会把平均/最大心率作为同一 HealthKit `.heartRate` 类型样本写入，ID 为 `mi_fitness_workout_*_avg_hr` / `_max_hr`。因此回填这组普通心率时也会删除 workout 关联心率，只重写普通心率记录。只有之后 workout 类型也被启用且成功重新取到该运动记录时，关联数据才会恢复；用户关闭运动同步、该类型同步失败或上游不再返回 workout 时，关联数据会丢失。若心率映射结果为空，则这段代码不会进入删除循环。

**建议：**强制回填只删除本次数据类型实际拥有的 ID 命名空间，或在统一的回填事务/协调流程中保护 workout 关联样本。覆盖“回填心率但关闭运动同步”和“心率成功、运动回填失败”两种场景。

#### S21｜P2：HealthKit 写入批次内部没有按 external UUID 去重

**位置：** `HealthMi/MiFitness/MiAPIClient.swift:210-214, 239-243`；`HealthMi/Sync/SyncEngine.swift:89-118`；`HealthMi/Health/HealthWriter.swift:41-44`；external UUID 生成见 `HealthMi/Health/TypeMapper.swift:43-71, 90-108`。

客户端把各分页结果直接追加到数组；同步时查询的是写入前 HealthKit 中已有的 ID，然后用这个固定集合过滤 `group.objects`。过滤过程中不会把本批已通过的 ID 加入集合，因此同一批次出现的相同 ID 都会被送入 `writer.save`。另外，普通心率、血氧和体重类 ID 将时间戳截到整数秒；两个同类型样本若落在同一秒，也会得到相同 ID。代码没有在保存前去除这些批内重复项。

**影响：**当服务端分页重叠、重复返回记录，或同一秒有多个同类型测量时，本次同步会把多个具有相同 external UUID 的对象交给 HealthKit 保存。HealthKit 对这类批次的实际接受结果未在本轮运行验证；即使写入成功，下一次查询也只能看到“该 ID 已存在”，无法凭现有逻辑识别并修复这次重复或冲突。

**建议：**保存前按 external UUID 对批次建索引并定义冲突策略（保留最新记录、合并或报协议错误）；对秒级 ID 增加稳定的事件标识或更高精度组成。为分页重复及同一秒冲突分别增加回归案例。

#### S22｜P3：服务端分页游标未进行 JSON 字符串转义

**位置：** `HealthMi/MiFitness/MiAPIClient.swift:93-103, 213-223, 242-252`。

`dataString` 手工插入 `key` 和 `nextKey` 到 JSON 字符串。`key` 来自代码中的固定名称，但 `nextKey` 来自服务端响应；如果游标含有引号、反斜杠或控制字符，下一页请求体会变成无效 JSON。仓库未包含小米分页游标格式的协议定义，因此该风险是否会由当前服务端真实触发仍需脱敏游标样例确认。

**建议：**用 `JSONSerialization` 或 `JSONEncoder` 编码请求对象，避免对服务端游标做字符串插值；保留当前已验证的字段和值语义并用含特殊字符的游标夹具验证。

#### S23｜P3：CSV 导出 `days` 参数没有参与筛选

**位置：** `HealthMi/App/DataExporter.swift:7-28`；当前调用 `HealthMi/App/DashboardView.swift` 的 CSV 导出按钮。

`exportCSV(days:trends:stressRecords:)` 接收 `days`，但函数体没有读取它；实际行数完全由 `trends` 决定。当前界面传入的趋势本身是最近 7 天，所以现有按钮路径看起来一致；若后续调用方传入 30 天或更长的 `trends`，参数名称会让调用者误以为函数会限制为所选天数。

**建议：**若筛选由调用方负责，删除未使用的 `days` 参数并在调用点明确传入已筛选数据；若函数负责范围，则用 `days` 对趋势和压力记录统一裁剪。

### C. 仓库内 Python MCP/CLI 参考工具

此目录是独立的 Python 小米运动健康同步/MCP 工具，不是 iOS App HealthKit 弹窗的直接调用链；以下问题不会解释 iPhone 上权限列表没有 HealthMi。

#### P1｜按用户隔离不完整，切换账号可能覆盖记录和共享游标

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/storage/__init__.py:224-229, 294-307, 422-435, 462-474, 507-518`；适配器 ID 生成见 `adapters/mi_fitness_cloud.py:498-504, 700-709`

`sync_state` 的唯一键只有 `data_type`，没有 `user_id`；多类记录以日期/秒级时间生成全局 `id`，部分 upsert 在 `ON CONFLICT(id)` 时更新指标但不更新 `user_id`。若一个 SQLite 库先后服务不同小米账号，游标会共享，碰撞记录也可能由一个账号的值覆盖而仍保留另一个账号的 user_id。

**建议：**为同步游标加入用户作用域，并让记录主键/唯一约束及 upsert 策略一致地按用户隔离。

#### P2｜指标序列只查每日活动，`weight_kg` 等身体指标会返回空

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/services/query_service.py:54-82`

`get_metric_series()` 始终从 `get_daily_summaries()` 取数据；每日摘要不含体重，因此调用指标 `weight_kg` 得不到身体测量记录。

**建议：**按指标路由到对应存储查询；为每日活动、身体测量、心率、血氧等分别定义指标类型。

#### P2｜周/月聚合的未知模式默认按 sum

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/services/query_service.py:104-115, 137-148`

`aggregation == "latest"` 未单独处理，会落入 `else: sum(values)`，导致请求最新值却得到总和；拼错聚合名称也不会报错。

**建议：**显式支持 `latest`，不支持的聚合值应校验报错。

#### P2｜CLI/MCP 诊断会暴露凭据标识和原始健康记录

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/main.py:32, 70, 154-156`；`server.py:476-489`；探测脚本 `probe_mifitness.py:34-40, 243, 260-264`、`probe_apnea.py:7-9, 88-101, 143-160`

命令行支持 `--pass-token`，不同操作系统可能允许同用户进程或诊断工具读取进程命令行；setup/doctor/探测程序会打印完整 user ID。即使呼吸探测脚本从 Keychain 加载时先遮盖 ID，随后仍会打印完整值。MCP 的 `get_profile` 直接返回完整 `user_id`；两个探测脚本还会把原始运动/睡眠健康记录 JSON 输出到终端，复制诊断日志时可能一并泄露个人标识与健康信息。

**建议：**避免把 passToken 放在命令行参数中；默认脱敏 user ID；探测程序输出样例时删去账号、精确时间和健康数据，或明确提供脱敏模式。

#### P3｜MCP SQLite 连接缺少显式关闭接口

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/storage/__init__.py:31-42, 269-283`；`tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/server.py:649-662`

`Database` 延迟创建并将 SQLite connection 长期缓存在实例字段中，但没有 `close()` 方法；`with self._get_connection()` 仅管理事务，不关闭该缓存连接。MCP server 退出时 `finally` 关闭 adapter，却没有关闭数据库连接。通常单进程 CLI 退出后由进程回收资源，所以暂未发现会影响正常短命令的故障；若数据库对象在嵌入式/测试进程中反复创建或服务关闭后继续驻留，连接与文件锁会持续占用到对象/进程结束。

**建议：**为 `Database` 增加显式生命周期关闭接口，并在 server/CLI teardown 中调用；测试也应关闭数据库对象，避免测试进程残留连接。

#### P3｜部分同步失败后仍打印“同步完成”

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/main.py:125-140`

逐数据类型失败会打印错误，但流程随后总会打印“同步完成！”，没有整体失败状态或非零退出码。

**建议：**汇总成功/失败数据类型；存在部分失败时明确标示部分完成，并返回可供自动化检测的失败状态。

#### P3｜本地健康数据 SQLite 未见数据库加密配置

**位置：** `tools/mi-fitness-mcp-cn/src/mi_fitness_mcp/storage/__init__.py:270-280`

工具把健康数据存入普通 SQLite 连接，源码中未见 SQLCipher 或额外的数据库加密层。若数据库落在多人可读设备或被备份同步的位置，应评估静态数据保护和文件权限。

### D. 既有问题记录的时效性

仓库中未跟踪的 `项目分析-优先关注问题.md` 标记分析基线为 `5930b70`，早于当前源码审查基线 `82fef0f`。其中“压力部分回填会清空全部历史”“压力保存失败吞错”等条目在当前代码已处理：`SyncEngine.syncStress` 返回实际查询范围，`StressStore.replaceRange` 只替换该范围，Core Data 保存错误会向上抛出。旧文档适合作为历史记录，不能直接当作当前结论。

当前工作区有此未跟踪文件，本次没有修改、暂存或提交它。

### E. iOS 17 SwiftData 到 Core Data 迁移核对

从历史提交 `565cd71^` 读取到的 iOS 17 版本使用 `Schema([SyncState.self, StressRecord.self, SyncLogEntry.self])` 与默认 `ModelConfiguration(schema:)` 打开 SwiftData；当前 `LegacySwiftDataImporter.importIfNeeded` 使用相同模型集合和同一默认配置。模型字段、SwiftData unique 属性也与当前迁移器读取的 v1 schema 对应。因此静态代码未发现“新旧版本使用了不同默认 SwiftData store 配置”的明显错误。

当前单元测试通过内存 SwiftData 容器调用 `importRecords` 验证记录字段、幂等标记和旧库保留，但没有用**历史版本实际落盘的默认 SwiftData store**执行启动升级测试。这个仍是验证缺口，不能仅凭内存导入测试断言真实升级路径已在 iOS 17 用户数据上成功。

## 六、修复与验证建议

### 第一优先级：确认最终安装包的 entitlement

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

### 第二优先级：修复打包方式

1. 选择本次分发目标：Apple 开发者签名包或 TrollStore 包。
2. Apple 开发者签名包需确保 App ID、profile 和签名中的 HealthKit capability 配套。
3. TrollStore 包需按其安装流程准备主可执行文件的 HealthKit entitlement，并在安装后再次检查实际 entitlement；不能假设它会从 XcodeGen 的 `.entitlements` 源文件推断权限。
4. 修改 workflow 的 artifact 命名，明确区分 `unsigned` 与 `trollstore/healthkit-enabled`，避免把“可以安装”误解成“具备 HealthKit entitlement”。

### 第三优先级：给授权请求加可见错误

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
- 没有取得用户手机上最终安装的 IPA，也没有 iOS 16.3 设备日志/HealthKit 错误码。
- 没有运行构建、测试、HealthKit 请求或外部小米 API 请求；本报告的非 entitlement 代码缺陷为静态风险，需要后续用针对性测试验证。
- 本次没有运行 GitHub runner；现有静态证据和本地 IPA 包结构足以定位当前最可能的构建配置问题，无需为此公开仓库。
- 本次没有修改项目源码、没有改变 GitHub 仓库公开性、没有 push。
- 本次补充审查开始时，`main` 相对 `personal/main` 领先 3 个本地提交；已存在的未跟踪文件 `项目分析-优先关注问题.md` 保持原样。
- 2026-11-23 继续静态审查代码基线 `82fef0f`，补充核对 Swift/Python 卡路里与睡眠分期差异、HealthKit 睡眠区间统计、快捷指令取消和后台任务完成竞态；本轮另有独立只读复核确认，本地 unsigned IPA 主可执行文件没有 `LC_CODE_SIGNATURE`。这仍不能证明用户手机上的最终安装包经过后处理后缺少 entitlement。
- 后续静态检查继续覆盖增量日活动更新、强制回填与 workout 心率关联、API 分页字段校验、Swift 数值转换、跨区域请求时区、MCP 敏感输出及 SQLite 连接生命周期；这些均为代码阅读结论，尚未运行对应回归场景。
- 本轮补充核对批次内 external UUID 去重、分页游标 JSON 编码和 CSV 导出参数；确认其为静态可见的实现缺口，但相关服务端重复页/特殊游标及 HealthKit 对重复批次的行为没有真实样本或运行证据。
- 本轮没有运行构建、测试或 GitHub runner；没有修改业务代码，未改变仓库可见性，未 push。`项目分析-优先关注问题.md` 未跟踪文件保持未暂存、未修改。

## 八、参考资料

- Apple：[HealthKit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.healthkit)——应用必须配置 HealthKit entitlement 才能使用相应 HealthKit 能力。
- Apple：[Authorizing access to health data](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)——应用通过 HealthKit 授权 API 请求读写类型权限；读取授权状态受隐私保护，不能据此读取用户是否允许读取数据。
- Apple：[HKHealthStore requestAuthorization API](https://developer.apple.com/documentation/healthkit/hkhealthstore/requestauthorization(toshare:read:completion:))——请求 HealthKit 访问授权的 API。
- Apple：[HKHealthStore getRequestStatusForAuthorization API](https://developer.apple.com/documentation/healthkit/hkhealthstore/getrequeststatusforauthorization(toshare:completion:))——检查针对指定数据类型的授权请求当前是否需要系统展示表单；授权调用成功本身不能证明用户已授予所有读写权限。
- Apple：[HKHealthStore authorizationStatus API](https://developer.apple.com/documentation/healthkit/hkhealthstore/authorizationstatus(for:))——查询指定对象类型的共享/写入授权状态。
- Apple：[HKQuery `predicateForSamples`](https://developer.apple.com/documentation/healthkit/hkquery/predicateforsamples(withstart:end:options:))——样本查询的时间范围可按样本与区间相交来匹配，计算边界区间总时长时需明确裁剪策略。
- Apple：[HKQueryOptions](https://developer.apple.com/documentation/healthkit/hkqueryoptions)——`strictStartDate` 与 `strictEndDate` 分别要求样本起始/结束时间落在目标区间内。
- Apple：[BGTask `expirationHandler`](https://developer.apple.com/documentation/backgroundtasks/bgtask/expirationhandler) 与 [`setTaskCompleted(success:)`](https://developer.apple.com/documentation/backgroundtasks/bgtask/settaskcompleted(success:))——后台任务到期处理和完成状态的官方接口。
- Swift 标准库：[`Int.init(_ source: Double)`](https://developer.apple.com/documentation/swift/int/init(_:))——浮点转整数要求输入值可由目标整数类型表示；对外部文本解析应先验证范围与有限性。
- Python 标准库：[sqlite3 connection context manager](https://docs.python.org/3/library/sqlite3.html#how-to-use-the-connection-context-manager)——连接上下文管理器提交或回滚事务，但不会关闭连接。
- TrollStore：[官方 README](https://github.com/opa334/TrollStore/blob/main/README.md)——用于核对其支持范围和 entitlement 处理方式；TrollStore 可处理带任意 entitlement 的应用，但安装成功本身并不证明 HealthKit entitlement 存在。
