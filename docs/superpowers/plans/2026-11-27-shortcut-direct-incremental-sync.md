# 快捷指令直接增量同步实施计划

用户已要求开始实施。每个工作阶段单独本地提交；不得推送到原始 `origin`。最终构建使用 `personal` 私有仓库的 GitHub Actions 和 `gh`。

## 阶段 1：实现直接执行和有界同步

- [ ] 更新 `SyncHealthDataIntent`：不再排队/调度 BGTask；直接准备数据库、运行增量同步并返回字符串结果，不新增 dialog。
- [ ] 保持运行历史：复用 queued run ID、避免重复执行 running run，持久化启动/成功/失败/部分完成状态和错误。
- [ ] 为快捷指令同步增加独立执行配置：22 秒总预算、单请求最多 8 秒、关闭自动重试、按类别检查预算；成功类别及时写游标，截止后不假报成功。
- [ ] 快捷指令路径跳过授权弹窗和仪表盘摘要刷新；缺少先决授权时返回清晰错误。
- [ ] BGAppRefresh 的周期刷新保持原行为。
- [ ] 运行 Swift 格式/差异检查与 Release 构建所需静态检查；本阶段提交代码。

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
