# GitHub Actions iOS IPA 构建与仓库连接说明

调查日期：2026-11-23

## 结论

可以用 GitHub Actions 在 macOS runner 上构建 HealthMi，并把导出的 IPA 作为 Actions artifact 保存或下载。**仓库不必公开，私有仓库也能运行 Actions**（GitHub 标注的旧版按仓库计费方案可能受限）。公开仓库使用标准 GitHub-hosted runner 免费；私有仓库先使用账号套餐包含的 compute 用量，超额后按 runner 费率计费。按 2026-11-23 查到的标准 macOS（3/4 核）runner 费率为每分钟 0.062 美元，不足一分钟按整分钟计；具体额度与费用以 GitHub 当前计费页和账户方案为准。

## 私有仓库 Actions 额度估算（2026-11-23）

GitHub 当前把包含的 Actions compute 额度按**美元金额**计算，不是固定的分钟数；额度按账号/计费账户共享，并在每个账单周期开始时重置。个人 **Free** 套餐每周期包含 **$12 USD** compute，**Pro** 包含 **$18 USD**。私有仓库的标准 macOS runner 费率为 **$0.062/分钟**；每个 job 使用的分钟数（包括不足一分钟的部分）向上取整。

| 个人套餐 | 每周期包含 compute | 按标准 macOS runner 粗略折算 |
| --- | ---: | ---: |
| Free | $12 | 约 193 个计费分钟（约 3 小时 13 分钟） |
| Pro | $18 | 约 290 个计费分钟（约 4 小时 50 分钟） |

如果你的个人账号是 Free，且**本计费周期尚未消耗其他共享 compute**，首次使用时可按约 193 个 macOS 计费分钟估算。额度不是单独给 HealthMi 仓库的；同一计费账户下的其他私有仓库 runner 使用，以及 GitHub cloud sandbox compute/memory，也会共用这笔额度。实际 IPA 构建的 runner 时间还包括检出代码、准备环境、归档和导出等步骤；失败的 job 已经运行的时间也会计入。

Free 套餐另含 **500 MB Actions artifact 存储**，与 GitHub Packages 共用；存储超额按使用时长计费。若账户没有有效的付款方式，包含额度用完后 GitHub 会阻止继续使用；若有付款方式，则可能对超额用量收费。可在账号 Billing 的 Budgets and alerts 中为 Actions 设置预算，并启用“Stop usage when budget limit is reached”来限制超额支出。

只把代码推到 GitHub 不会自动生成 IPA。仓库需要配置工作流（通常放在 `.github/workflows/`），让 macOS runner 执行 Xcode archive 和 export，再用 Actions artifact 上传导出的文件。

如果目标是**可在真机安装或分发**的 IPA，需要有效的 Apple 签名身份和与 App ID 匹配的 provisioning profile。HealthMi 声明了 HealthKit entitlement，因此所用 App ID/profile 也必须具有匹配的 HealthKit 能力。签名证书、私钥和 profile 应通过 GitHub Actions Secrets 安全提供，不应提交到 Git 仓库。模拟器构建成功本身不代表生成了可分发的设备 IPA。

## 对本仓库的检查

- 仓库当前的 `origin` 指向上游 `https://github.com/ShawnDiego/HealthMi.git`。向 `origin` 推送会指向上游，因此不要用 `git push origin ...` 来发布个人副本。
- 当前工作环境没有安装 GitHub CLI（`gh`），也未完成 GitHub 账号认证；我还没有连接到你的 GitHub 账号。
- 仓库目前没有 `.github/workflows/`，尚未配置 GitHub Actions 构建工作流。
- 仓库有 `HealthMi.xcodeproj` 和 `project.yml`；README 记载工程由 XcodeGen 生成。工作流可用 macOS 上的 XcodeGen 从 `project.yml` 生成工程，再用 `xcodebuild` 构建。
- `project.yml` 的最低部署版本为 iOS 16.0，HealthMi entitlement 文件启用了 `com.apple.developer.healthkit`。

## 建议的仓库连接方式

建议在自己的 GitHub 账号创建一个**私有**空仓库（例如 `HealthMi`），保留现有 `origin` 作为上游，再给个人仓库添加单独的 remote。这样上游和个人仓库的目标名称不同，推送时更容易确认目标。

先通过 GitHub 网页创建私有空仓库。在安装了 GitHub CLI 的环境中，先运行 `gh auth login` 完成登录，再执行：

```sh
git remote add personal https://github.com/<你的用户名>/HealthMi.git
git remote -v
git push -u personal main
```

上面的 `git push` 是供你确认目标后执行的示例；本次调查没有连接账户、添加 remote 或推送任何内容。执行前核对 `git remote -v`，确认 `personal` 是你新建的仓库。不要把 `personal` 改成上游地址，也不要向当前 `origin` 推送。也可以使用 GitHub Desktop 登录账户、添加现有本地仓库并发布到个人仓库。

本工作环境目前没有 `gh` 命令；如果要让我在此环境中继续设置，需要先安装 GitHub CLI 并完成浏览器登录，或让你使用 GitHub Desktop/Git Credential Manager 完成本地认证。认证完成后，仍应先核对 `git remote -v`，再决定是否向个人仓库推送。

## 构建工作流大致步骤

1. 在 `push` 或手动触发时启动 macOS runner。
2. 检出代码；按项目需要安装 XcodeGen 并生成 `HealthMi.xcodeproj`。
3. 执行 `xcodebuild archive`，再通过 `xcodebuild -exportArchive` 和导出配置生成 IPA。
4. 使用 `actions/upload-artifact` 保存 IPA，供工作流完成后下载。
5. 若要设备安装或分发，配置 Apple 开发者团队、匹配 HealthKit 能力的 App ID/profile 及签名证书，并将敏感材料放入 Actions Secrets。仅做不带签名的模拟器构建时，不会获得可供真机安装的 IPA。

需要留意，项目当前的 Bundle Identifier 是 `com.healthmi.HealthMi`。若该标识不属于自己的开发者团队，正式签名分发前通常要换成团队可用的唯一 Bundle Identifier，并同步更新对应 App ID 和 profile。

## 官方资料

### GitHub

- [GitHub-hosted runners 说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)：托管 runner 的操作系统与使用方式；另见[选择工作流 runner](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job)。
- [GitHub Actions runner 计费](https://docs.github.com/en/billing/reference/actions-runner-pricing)：私有仓库的标准 runner 使用套餐额度，超出后按费率计费；公开仓库标准 runner 规则不同。
- [各套餐包含的产品用量](https://docs.github.com/en/billing/reference/product-usage-included)：Free、Pro 等套餐的 Actions compute 与 artifact 存储额度。
- [GitHub Actions 计费机制](https://docs.github.com/en/billing/concepts/product-billing/github-actions)：额度共享、计费周期、artifact 存储、超额用量和每个 runner 类型费率。
- [设置预算控制计量产品支出](https://docs.github.com/en/billing/how-tos/set-up-budgets)：设置用量告警和达到预算后停止使用。
- [Workflow Artifacts](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts)：工作流生成文件的上传和下载。
- [在 GitHub Actions 中使用 Secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)：向工作流提供敏感值。
- [将本地代码添加到 GitHub](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github)：创建仓库、添加 remote 并推送现有本地项目。

### Apple

- [将 App 分发到已注册设备](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices/)：Xcode 导出 iOS Package Archive（IPA）并选择 profile 的流程。
- [手动管理分发签名](https://help.apple.com/xcode/mac/current/en.lproj/devcac6ab5b3.html)：导出 iOS App 时使用分发证书和 provisioning profile。
- [启用 App 能力](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/)：在 App ID 上启用能力；更改后可能需要重新生成 provisioning profile。
- [设置 HealthKit](https://developer.apple.com/documentation/healthkit/setting-up-healthkit)：在 iOS App 中启用 HealthKit 能力。
- [创建开发 provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile)：profile 与 App ID、证书、设备之间的关系。

## 资料适用范围

GitHub 的套餐、额度和 runner 名称可能调整，实际执行前以 GitHub 当前计费页面和账户页面为准。Apple 的签名方式也取决于目标分发渠道（开发设备、Ad Hoc、TestFlight 或 App Store）；工作流应针对目标渠道选择相应的导出方法和 profile。
