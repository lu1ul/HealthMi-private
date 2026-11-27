# 快捷指令发现 FBS 问题：低风险隔离修复记录

## 背景与结论

用户提供的 iOS 16.3 系统日志与 HealthMi 应用日志已经按时间关联，详见《HealthMi项目代码全面审查报告.md》9.29 节：

- 应用内 `ShortcutsLink` 被点击后，快捷指令 App 成功打开。
- 随后 `Shortcuts`/`linkd` 在获取 HealthMi App Intent action/phrase 时，尝试以 suspended、sceneless 方式连接 HealthMi，出现 FBS Code 5 和底层 XPC Code 3。
- 后续直接运行“同步健康数据”时，`SyncHealthDataIntent` 被正常启动、排队并返回；本次未出现快捷指令 Intent 崩溃。
- build 3 的 IPA metadata 含有 `SyncHealthDataIntent` 和 `QueryLatestSyncStatusIntent`，但用户的 iOS 16.3 快捷指令动作列表只显示同步动作。
- 当前证据没有暴露 FBS 连接失败对应的具体 action/phrase，不能断言问题由“查询同步状态”Intent 单独引起，也不能保证移除链接会修复系统的全部发现问题。

## 已选择方案

用户选择“低风险隔离”：

1. 从仪表盘移除 `ShortcutsLink`，避免应用主动打开 App Shortcuts 页面并触发已观察到的 LinkServices sceneless discovery 路径。
2. 用静态的应用内说明替代该入口，指导用户在快捷指令 App 中通过“添加操作”搜索 HealthMi。
3. 保留 `SyncHealthDataIntent` 和 `QueryLatestSyncStatusIntent` 的定义、注册和现有无值 `.result()` 返回行为；不恢复 dialog，也不改成值返回。
4. 将 `CURRENT_PROJECT_VERSION` 从 3 提升为 4。
5. 经用户的 `personal` GitHub remote 构建 unsigned IPA 与 TrollStore HealthKit IPA；下载后检查 ZIP 完整性、版本号、最低系统版本、两个 App Intent metadata、HealthKit/TrollStore entitlement，并记录 SHA-256。
6. 所有提交留在本地后推送到用户仓库 `lu1ul/HealthMi-private` 以触发 GitHub Actions；不推送到原始 `origin` `ShawnDiego/HealthMi`。

## 本次不改变的行为

- “同步健康数据”仍然是快速排队后无 dialog 返回；`Shortcuts` 显示 workflow 成功只代表动作返回成功，不代表 BGTask 已领取或健康数据已同步完成。
- 查询状态 Intent 仍然只记录查询结果并返回空结果，不会把状态文本传给快捷指令。
- 此次代码和 IPA 检查无法替代 iOS 16.3 真机验证。移除 `ShortcutsLink` 后，仍需在设备上检查动作发现列表和系统日志，才能确认 FBS 路径是否消失以及“查询同步状态”是否出现。

## 实施步骤与验收

1. **设计记录**：保存本方案并本地提交。
2. **代码与版本**：替换 `DashboardView` 中的 `ShortcutsLink` 为简洁操作说明；build number 升至 4；本地检查 diff 并提交。
3. **GitHub 构建**：只向 `personal` remote 推送已提交更改；通过 `gh` 等待 Actions 完成并下载两个 IPA 产物。
4. **IPA 核验**：确认 `CFBundleVersion=4`、`MinimumOSVersion=16.0`、包内两个 App Intent metadata、TrollStore 签名及 HealthKit entitlement，并记录文件大小和 SHA-256。
5. **报告更新**：把实际工作流运行、构建结果、产物路径和验证边界写入本文件及《HealthMi项目代码全面审查报告.md》，再本地提交。

### 执行状态

- 设计记录：已完成并提交（`76cc3db`）。
- 代码变更：已完成并提交（`fa086b1`）；`ShortcutsLink` 已替换为添加操作说明，build number 已提升至 4。
- GitHub Actions：已成功（`lu1ul/HealthMi-private`，运行 `45918462737`，提交 `fa086b1f5fe91427e4d3f37b61db1eab1c6254fc`）。
- IPA 核验：已完成；两份 IPA 的 build、最低系统版本、ZIP 完整性和双 Intent metadata 检查通过。TrollStore entitlement 由工作流报告和本地下载的验证报告确认。
- iOS 16.3 真机复测：尚未完成。IPA 检查不能证明系统动作列表会显示“查询同步状态”，也不能证明 FBS Code 5 在设备上已消失。

### Build 4 产物

工作流产物已通过 `gh run download` 下载至 `build/shortcut-build-4-45918462737/`：

| 产物 | 本地文件 | 大小 | SHA-256 |
|---|---|---:|---|
| TrollStore HealthKit IPA | `build/shortcut-build-4-45918462737/HealthMi-trollstore-healthkit-ipa/HealthMi-trollstore-healthkit.ipa` | 2,103,181 字节 | `C81EA38C02E06A90DDEF0C2419593E0D7BB8A893866BC79AAE7E3437BB06673A` |
| Unsigned IPA | `build/shortcut-build-4-45918462737/HealthMi-unsigned-ipa/HealthMi-unsigned.ipa` | 2,043,053 字节 | `CF2846BE9F3253DEE68FB273E56A9438B6213524B367DE30709B7B1271905009` |

两个包均为 `com.healthmi.HealthMi`、版本 `1.1.0`、build `4`、`MinimumOSVersion=16.0`，ZIP 完整性测试通过；均包含 `Metadata.appintents/root.ssu.yaml`，文件中包含 `SyncHealthDataIntent` 和 `QueryLatestSyncStatusIntent`。TrollStore 包的 CI `ldid -e` 校验确认 HealthKit entitlement、TrollStore application/team identifier、Keychain access groups、签名载荷及 HealthKit usage descriptions，且没有 embedded provisioning profile。

## Apple 官方资料

- [ShortcutsLink](https://developer.apple.com/documentation/appintents/shortcutslink)：用于打开当前 App 在快捷指令中的 App Shortcuts 页面；本次隔离替换的入口。
- [AppShortcutsProvider](https://developer.apple.com/documentation/appintents/appshortcutsprovider)：声明系统可展示的预配置 App Shortcuts。
- [IntentResult.result(value:)](https://developer.apple.com/documentation/appintents/intentresult/result(value:)) 与 [ReturnsValue](https://developer.apple.com/documentation/appintents/returnsvalue)：iOS 16 起可返回值；本次按低风险方案暂不更改查询 Intent 的返回契约。

## 资料来源和限制

本记录基于仓库源码、build 3 IPA 检查结果、用户提供的 `shortcut-debug-4.jsonl` 系统日志与同一时段应用内日志。设备原始日志未复制到仓库。Apple API 页面用于核实 `ShortcutsLink`、`AppShortcutsProvider` 和值返回能力；API 的可用性不证明 iOS 16.3 设备上的实际发现行为。
