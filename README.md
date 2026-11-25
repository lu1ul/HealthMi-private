# HealthMi

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

把小米运动健康（Mi Fitness）云端的健康数据，写入 Apple 健康（HealthKit）的纯 iOS App。

## 功能特性

- **9 类数据同步**：日常活动（步数/距离/卡路里）、心率（含静息）、睡眠（含分期）、血氧、呼吸频率、心率变异性、体重/体脂/BMI/肌肉量/基础代谢、运动记录（含心率）、压力
- **多区域支持**：中国大陆 / 俄罗斯 / 欧洲 / 国际 / 新加坡 / 美国，自动适配 API 域名和时区
- **增量同步 + 回填**：按类型独立记录游标，增量只拉新数据；支持 7/30/90/全部天数强制回填
- **后台自动同步**：`BGAppRefreshTask` 后台周期增量同步，失败时发送本地通知
- **Swift Charts 趋势图**：7 天步数/心率/睡眠/HRV 趋势可视化
- **每日详情页**：点击趋势图中任一天查看当日全部数据 + 压力记录
- **同步历史日志**：持久化每次同步的结果（成功/失败/拉取数/新增数），自动裁剪 200 条
- **诊断日志**：在 App 内查看、搜索和筛选应用/网络/HealthKit/快捷指令日志；一键复制脱敏文本，或导出 JSON 文件分享。日志只保存在本机，不上传
- **数据导出**：一键导出最近 7 天每日数据为 CSV，通过系统分享面板发送
- **快捷指令**：通过 Siri 或快捷指令快速排队后台同步，并提供“查询同步状态”动作和详细错误通知；仪表盘入口可直接打开 HealthMi 的系统快捷指令页面
- **压力数据展示**：从小米云端读取 stress key，存入 App 内 Core Data 展示（HealthKit 无对应类型）
- **WebView 登录**：App 内 WKWebView 登录小米账号页面，自动捕获 Cookie

## 原理

`HealthMi` 用 Swift 重新实现了已验证的开源工具 [mi-fitness-mcp-cn](tools/mi-fitness-mcp-cn) 的取数逻辑：

1. **登录**：用小米账号 `userId` / `passToken`（account.xiaomi.com 的 Cookie）经 `serviceLogin` 换取 `ssecurity` 与会话 Cookie；
2. **签名请求**：每个请求用 `signed_nonce = SHA256(ssecurity||nonce)` 做 RC4 加密 + SHA1 签名，调用 `hlth.io.mi.com` 的 `get_fitness_data_by_time` / `get_sport_records_by_time`；
3. **数据映射**：步数/距离/卡路里、心率（含静息）、睡眠（含分期）、血氧、呼吸频率、心率变异性、体重/体脂/BMI/肌肉量/基础代谢、运动记录、压力 → HealthKit 类型（压力无对应类型，存 App 内）；
4. **幂等写入**：每个样本带 `HKMetadataKeyExternalUUID`，按类型+时间区间查重后**一次批量保存**（复刻 [healthloom.app](https://github.com/wpowiertowski/healthloom.app) 的 `HealthKitWriter` 模式）。

## 数据映射

| 小米数据 | Apple Health 类型 | 换算 |
|---|---|---|
| 步数 | `stepCount` | count |
| 距离 | `distanceWalkingRunning` | m |
| 活动卡路里 | `activeEnergyBurned` | kcal |
| 心率采样 / 静息 | `heartRate` / `restingHeartRate` | count/min |
| 睡眠 | `sleepAnalysis` | inBed + 分期（awake / AsleepCore / AsleepDeep / AsleepREM），不写整晚 asleep 聚合 |
| 血氧 | `oxygenSaturation` | **百分比 → 分数**（98% → 0.98） |
| 呼吸频率（睡眠均値） | `respiratoryRate` | count/min |
| 心率变异性（睡眠 HRV） | `heartRateVariabilitySDNN` | ms |
| 体重 / 体脂 / BMI / 肌肉量 / 基础代谢 | `bodyMass` / `bodyFatPercentage` / `bodyMassIndex` / `leanBodyMass` / `basalEnergyBurned` | 体脂百分比 → 分数 |
| 运动 | `HKWorkout` | 关键词映射 `HKWorkoutActivityType`，关联平均/最大心率样本 |
| 压力 | App 内 Core Data 展示 | HealthKit 无对应类型，存 App 内不写入 HealthKit |

> abnormal_heart_beat 暂无 HealthKit 对应类型，未纳入（数据仍可从小米云端读到）。

## 目录结构

```
project.yml          XcodeGen 工程定义（改配置后 xcodegen generate 重新生成）
HealthMi/
  App/               入口、引导、主界面、Keychain 凭据、App 状态
    DataExporter      CSV 数据导出
    DiagnosticsLogView 诊断日志列表、筛选、复制、详情和分享
    DayDetailView     每日详情页
    SyncHistoryView   同步历史日志
    SyncIntent        App Intents / 快捷指令
    TrendChartView    Swift Charts 趋势图
  MiFitness/         小米云 API 的 Swift 移植（Crypto/Session/API/Models/Parser/Region）
  Health/            HealthKit 授权、幂等写入器、数据映射、读取器
    Sync/              同步引擎、Core Data 存储、旧 SwiftData 迁移、后台任务
  Support/           Info.plist、HealthKit entitlement、通知管理、统一诊断日志
  Resources/         资源（AppIcon 等）
HealthMiTests/       加密向量 / 解析 / 映射 / 引擎 / 游标 / 区域 单测
tools/               已验证的 Python 参考实现（mi-fitness-mcp-cn）
```

## 前置条件

- Xcode 16+（Swift 6.0）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- iOS 16.0+（最低部署目标）
- 真机写入 HealthKit 需要付费开发者账号

## 构建与测试

```bash
# 生成工程（首次或改 project.yml 后）
xcodegen generate

# 编译（iOS 模拟器）
xcodebuild -project HealthMi.xcodeproj -scheme HealthMi \
  -destination 'generic/platform=iOS Simulator' build

# 运行单测（对某一台已创建的模拟器）
xcodebuild -project HealthMi.xcodeproj -scheme HealthMi \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# 真机构建（需自己的开发团队）
xcodebuild -project HealthMi.xcodeproj -scheme HealthMi \
  -destination 'platform=iOS,id=<设备UDID>' \
  DEVELOPMENT_TEAM=<团队ID> -allowProvisioningUpdates build
```

### GitHub Actions IPA

向 `main` 推送 App 源码或工程配置后，工作流会在 macOS runner 上生成 `HealthMi-unsigned.ipa` 和带 HealthKit/TrollStore entitlement 的 `HealthMi-trollstore-healthkit.ipa`。前者需要用自己的开发团队证书和 provisioning profile 签名；后者用于 TrollStore 安装，不是开发者签名 IPA。手动运行时可在 `bundle_identifier` 中填写团队已注册的 Bundle Identifier。两个 artifact 均由 GitHub Actions 上传。

## 使用

1. 首次打开 App，通过 WebView 登录小米账号，或手动输入 `userId` / `passToken`；
2. 同意 HealthKit 读写权限；
3. 在账号区域选择所在区域（默认中国大陆）；
4. 点「立即增量同步」，选择首次回填天数（7/30/90/全部）；
5. 之后在「健康」App 里即可看到小米设备的数据；
6. 日常使用：打开 App 点同步，或运行快捷指令“同步 HealthMi 健康数据”。快捷指令只写本地队列并返回“已排队”和运行 ID；若当前进程已注册后台处理器则立即提交调度，否则由已有周期后台刷新领取。之后可运行“查询同步状态”查看成功类型和具体错误；也可从仪表盘“快捷指令”入口打开系统页面添加这两个动作；
7. 在趋势区域查看 7 天图表，点击某天进入每日详情；
8. 点击导航栏时钟图标查看同步历史日志；
9. 在“问题诊断”中查看日志详情、搜索/筛选日志并一键复制当前结果；也可导出完整 JSON 诊断文件并通过系统分享；
10. 数据导出区域可导出 CSV。

## 注意事项

- **非官方接口**：本项目通过小米**非官方私有 API**（`account.xiaomi.com` / `hlth.io.mi.com`）读取数据，非小米官方产品，接口随时可能变更或失效；请自行评估使用风险，勿高频请求。`passToken` 等同账号凭证，请妥善保管，本项目仅在设备本地 Keychain 中保存，不会上传。
- **passToken 有效期短**：过期后同步会报「登录被拒绝（code=70016）」，重新登录 account.xiaomi.com 复制新 token 更新即可。
- **HealthKit 仅 iOS 可用**：原生 macOS App 无法写 HealthKit（需 Mac Catalyst + entitlement），因此本方案做成纯 iOS。
- **后台同步**：已接入 `BGAppRefreshTask`（每小时周期刷新），模拟器不触发，需真机验证。快捷指令只写轻量队列；只有在 App Intent 进程确认已注册后台处理器时才提交立即调度，系统仍不保证马上执行。从多任务划掉 App 后，后台任务通常不会运行，直到再次打开 App 或系统重新调度。
- **真机部署**：把 `project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER` 换成你自己的，并在 Xcode 中配置开发团队（HealthKit entitlement 需要付费开发者账号）。
- **运动记录**：用 `HKWorkoutBuilder` 构建；关联平均/最大心率样本（不与日总计重复计数）；不关联能量/距离样本，避免与每日活动总量重复计算。
- **本地数据库**：Core Data 存储同步游标、压力记录和同步历史。升级到本版本的 iOS 17+ 用户会在首次启动时导入旧 SwiftData 数据；迁移完成前原 SwiftData 库保留，迁移失败时应用提供重试入口。
- **压力数据**：从小米云端读取 stress key，存入 App 内 Core Data 展示（不写入 HealthKit，因其无对应类型）；回填只替换 API 实际查询的时间范围。
- **API 健壮性**：网络错误自动重试（指数退避 + 抖动，最多 3 次），分页请求间 200ms 间隔避免限流，认证错误（code=70016）不重试。
- **诊断日志隐私**：本地 JSONL 日志最多 20 MiB、保留 14 天；日志不包含凭据、Cookie、请求/响应正文或健康样本值。复制和 JSON 导出均执行脱敏，分享由用户主动选择目标。

## 测试说明

`MiCryptoTests` 使用 `tools/mi-fitness-mcp-cn`（已验证的 Python 实现）作为"预言机"生成固定向量，保证 Swift 移植的 RC4/签名算法与 Python 逐字节一致，不依赖网络。`SyncEngineTests` 验证窗口计算逻辑（首次/增量/回填），`SyncStateStoreTests` 验证游标记录与清除，`MiRegionTests` 验证区域配置。可选的真实 API 集成测试需要提供有效凭据，未包含在默认单测中。

## 许可证

本项目以 **Apache License 2.0** 开源，详见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。

内置参考工具 [mi-fitness-mcp-cn](tools/mi-fitness-mcp-cn) 使用 **MIT License** 发布（Copyright © 2026 Aleksej Kubulashvili），详见 [tools/mi-fitness-mcp-cn/LICENSE](tools/mi-fitness-mcp-cn/LICENSE)。

## 更新日志

详见 [CHANGELOG.md](CHANGELOG.md)。
