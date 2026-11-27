# 快捷指令直接增量同步实施计划

用户已要求开始实施。每个工作阶段单独本地提交；不得推送到原始 `origin`。最终构建使用 `personal` 私有仓库的 GitHub Actions 和 `gh`。

## 阶段 1：实现直接执行和有界同步

- [x] 更新 `SyncHealthDataIntent`：不再排队/调度 BGTask；直接准备数据库、运行增量同步并返回字符串结果，不新增 dialog。
- [x] 保持运行历史：复用 queued run ID、避免重复执行 running run，持久化启动/成功/失败/部分完成状态和错误。
- [x] 为快捷指令同步增加独立执行配置：22 秒总预算、单请求最多 8 秒、关闭自动重试、按类别检查预算；成功类别及时写游标，截止后不假报成功。
- [x] 快捷指令路径跳过授权弹窗和仪表盘摘要刷新；缺少先决授权时返回清晰错误。
- [x] BGAppRefresh 的周期刷新保持原行为。
- [x] 运行 `git diff --check` 并核对 `syncAll` 调用点、Intent 调度调用点和请求策略引用；Release 构建留到阶段 3。

## 阶段 2：版本与文档

- [ ] 将 `CURRENT_PROJECT_VERSION` 从 5 增至 6。
- [ ] 更新 `CHANGELOG.md`、本设计状态、iOS 16 适配记录和全面审查报告，注明执行时限与验证边界。
- [ ] 提交 build 6 和实施记录。

## 阶段 3：GitHub 构建和 IPA 核验

- [ ] 确认 `gh` 已登录 `lu1ul`，只向 `personal` 推送已提交分支，不推送 `origin`。
- [ ] 等待 `build-unsigned-ipa.yml` 成功，使用 `gh run download` 下载 unsigned 与 TrollStore IPA。
- [ ] 检查 ZIP、`Info.plist`、最低系统版本、build 6、App Intents metadata、TrollStore HealthKit entitlements 和 SHA-256。
- [ ] 把 workflow run、文件路径、核验结果写入本地记录并提交最终文档。

## 验证边界

GitHub 编译不能模拟 iOS 16.3 的 Shortcuts 后台时间预算、真实小米网络、HealthKit 授权弹窗或设备是否强制结束 Intent。构建成功后 IPA 可交付；最终设备端确认需在用户 iPhone 上执行一次快捷指令并查看它返回的运行摘要和同步历史。

## 阶段 1 实施记录

- Intent 现在直接准备 Core Data 并调用 `AppModel.syncAll`，不提交 BGAppRefresh；保留 `openAppWhenRun = false`。
- 返回值为 `ReturnsValue<String>`，没有重新加入 `ProvidesDialog`；结果包含运行状态、各类型计数和错误摘要。
- 快捷路径设置 22 秒预算、8 秒请求上限、0 次自动重试、保留分页间隔；每个类型前检查剩余时间，网络请求读取剩余预算并设置自身超时。
- 快捷路径不刷新仪表盘，也不弹 HealthKit 首次授权；完成配置后可无前台 UI 执行。周期 BGAppRefresh 仍走原执行上下文。
- 本机已通过 `git diff --check` 和调用点/过时队列 API 搜索；Windows 工作区没有 Xcode，Release 编译待阶段 3 的 GitHub workflow。
