# HealthKit entitlement 注入与权限错误反馈设计

日期：2026-11-24

状态：待用户确认

## 目标

修复两个相互关联的问题：

1. 点击“请求健康权限”失败时，界面不能再静默显示“没有反应”，而是显示可读的 HealthKit 错误。
2. GitHub Actions 设备构建生成一个可直接交给 TrollStore 安装的 HealthKit IPA，使最终主程序包含 com.apple.developer.healthkit=true。

用户已经选择：由 GitHub macOS runner 完成 TrollStore 包处理，手机只安装最终 artifact。

## 当前事实

- 当前 DashboardView 的权限按钮使用 Task { try? await model.requestHealthKit() }，会丢弃所有错误。
- HealthMi/Support/HealthMi.entitlements 已声明 com.apple.developer.healthkit。
- 当前设备 IPA workflow 使用 CODE_SIGNING_ALLOWED=NO、CODE_SIGNING_REQUIRED=NO，因此现有 artifact 没有 LC_CODE_SIGNATURE。
- 原版和当前版的 HealthKit 源码、Info.plist、Bundle ID 相同；问题重点在最终包处理和错误可见性。
- Homebrew 提供 ldid formula，可在 macOS runner 安装并操作 Mach-O 签名块。
- TrollStore 路线不是 Apple Developer distribution signing；它是把 entitlement 写入 Mach-O 后交给 TrollStore 安装的独立产物。

## 目标范围

### 要做

- 在 AppModel 增加专门的 HealthKit 错误状态，不与同步错误混用。
- 在 requestHealthKit 失败时保存包含 HKError domain/code 的可读信息，并继续抛出错误给调用方。
- 在 DashboardView 的权限状态区域展示错误；按钮仍可重试。
- 在网页登录完成后请求权限的路径中去掉静默 try?，让失败进入现有 onboarding 错误区域。
- 保留一个明确标记为 unsigned 的 IPA，便于构建和包结构对照。
- 新增一个手动触发的 TrollStore HealthKit IPA workflow，或在当前设备 workflow 中增加可选产物。
- 使用 ldid 处理主程序，重新打包并在 CI 中检查签名和 entitlement。
- 在本地研究记录和审查报告中记录 workflow 产物类型和验证结果。

### 不做

- 不把 Apple Developer 证书、私钥或 provisioning profile 上传到仓库。
- 不把 TrollStore 产物误命名为 Apple App Store 或 TestFlight 签名包。
- 不修改 HealthKit 类型清单、同步协议或 Core Data 迁移逻辑。
- 不自动清理用户手机已有的健康授权状态。
- 不把 iOS 模拟器授权结果当作 iOS 16.3 真机结果。


## 方案对比

### 方案 A：GitHub runner 生成 TrollStore-ready IPA（采用）

步骤：

1. xcodegen 生成 iOS 16 工程。
2. xcodebuild 构建未使用 Apple 证书的 Release app。
3. 将 app 复制到 Payload。
4. 运行 ldid -SHealthMi/Support/HealthMi.entitlements Payload/HealthMi.app/HealthMi。
5. 用 ldid -e 导出并检查 entitlement。
6. 用 Mach-O 检查确认 LC_CODE_SIGNATURE 存在。
7. 检查 Bundle ID 和两个 HealthKit 用途说明。
8. 打包为 HealthMi-trollstore-healthkit.ipa。
9. 上传独立 artifact 和 entitlement-report.txt。

优点：

- 构建步骤可重复；
- 手机只需安装最终包；
- 不需要在越狱手机上手工执行命令；
- CI 会拒绝缺少 HealthKit entitlement 的产物。

代价：

- ldid 生成的是 TrollStore 使用的伪签名/签名块，不是 Apple Developer distribution signature；
- 产物只面向支持 TrollStore 的安装环境；
- ldid 版本和 runner 镜像需要在日志中记录。

### 方案 B：GitHub 只生成 unsigned IPA，手机或本地手工 ldid

不采用。它保留了当前最容易出错的手工步骤，无法保证每一次安装的 IPA 都经过同样的 entitlement 处理，也难以从 GitHub artifact 判断最终包是否可用。

### 方案 C：GitHub 使用 Apple Developer certificate 正常签名

暂不采用。它适合标准真机分发，但需要安全配置证书、私钥、profile 和团队信息；当前目标是先恢复 TrollStore 下的 HealthKit 授权验证。

## 错误反馈设计

### AppModel

新增：

    @Published var healthKitError: String?

requestHealthKit 的行为：

1. 开始请求前清空 healthKitError。
2. 检查 HealthKit 可用性。
3. 调用 HealthKitManager.requestAuthorization。
4. 成功后刷新 healthKitAuthorized。
5. 失败时将 NSError domain、code 和 localizedDescription 转成可读文本，写入 healthKitError，然后重新抛出原错误，保持 onboarding 的错误处理能力。

格式示例：

    HealthKit 授权失败（HKErrorDomain / code=4）：系统错误文本

### DashboardView

“Apple 健康”区域在“请求健康权限”按钮下方显示 healthKitError。

按钮使用显式 do/catch：

    Task {
        do {
            try await model.requestHealthKit()
        } catch {
            // requestHealthKit 已把可读错误写入模型；这里避免未处理的 Task 错误
        }
    }

按钮保持可重复点击，便于用户在修复签名或修改系统设置后重试。

### OnboardingView

网页登录回调不再使用 try?；失败信息进入现有 onboarding 错误区域。手动输入凭据路径继续使用现有 do/catch。


## Workflow 设计

### 产物

保留两个不同的 artifact：

- HealthMi-unsigned-ipa：仅用于构建和包结构对照，不承诺 HealthKit entitlement。
- HealthMi-trollstore-healthkit-ipa：经过 ldid 处理并通过 entitlement 验证，可交给 TrollStore。

### 工具安装

在 macOS runner：

    brew install xcodegen
    brew install ldid
    xcodegen generate

记录：

    xcodebuild -version
    xcodegen --version
    ldid -V

### 构建

使用当前 iOS 16 的 project.yml：

    xcodebuild -project HealthMi.xcodeproj -scheme HealthMi -configuration Release -destination generic/platform=iOS -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build

### 注入 entitlement

对主程序执行：

    ldid -SHealthMi/Support/HealthMi.entitlements build/ipa-package/Payload/HealthMi.app/HealthMi

如果 ldid 返回非零退出码，workflow 失败。

### 验证

必须在打包前完成：

- 主程序存在 LC_CODE_SIGNATURE；
- ldid -e 输出 com.apple.developer.healthkit=true；
- Info.plist 含 NSHealthShareUsageDescription；
- Info.plist 含 NSHealthUpdateUsageDescription；
- Bundle ID 为 com.healthmi.HealthMi；
- 主程序为 arm64；
- 包内存在 Payload/HealthMi.app/HealthMi；
- SHA-256 写入 workflow 日志。

验证失败时不上传 TrollStore artifact。

### 打包

将经过 ldid 处理的 app 放入 Payload，生成 HealthMi-trollstore-healthkit.ipa。

同时上传 entitlement-report.txt，记录：

- IPA SHA-256；
- executable SHA-256；
- Bundle ID；
- 版本号；
- ldid 版本；
- entitlement 检查结果；
- 是否发现 LC_CODE_SIGNATURE；
- 是否发现 embedded.mobileprovision。

## 验收场景

### 权限错误反馈

- 模拟没有 HealthKit entitlement 的请求，界面显示明确错误；
- HealthKit 请求成功时，按钮消失或状态变为已授权；
- 用户拒绝请求后，界面显示未授权且可以再次进入系统设置；
- 登录回调请求失败时，Onboarding 页面显示错误，而不是静默关闭。

### GitHub workflow

- unsigned artifact 仍能生成，并明确命名；
- TrollStore artifact 能生成；
- workflow 日志能看到 ldid 版本和 SHA-256；
- entitlement 缺失时 workflow 失败；
- artifact 内主程序存在 LC_CODE_SIGNATURE；
- entitlement report 明确记录 com.apple.developer.healthkit=true。

### 手机验证

- 下载 HealthMi-trollstore-healthkit.ipa；
- 使用 TrollStore 安装；
- 删除旧的 HealthMi 后重新安装，避免混淆 Bundle ID 和旧授权状态；
- 点击“请求健康权限”；
- 检查“健康”App 的来源列表；
- 检查健康数据访问页面；
- 如果仍然失败，导出安装后主程序，用 ldid -e 再检查一次。


## 风险与限制

- ldid 产物不是 Apple Developer 签名包；不能用于 App Store、TestFlight 或普通未越狱设备。
- GitHub runner 的 ldid 版本变化可能影响 Mach-O 处理，因此构建日志和 entitlement report 必须保留。
- HealthKit 授权状态与设备系统、用户选择和 Bundle ID 相关；CI 验证 entitlement 不能替代 iOS 16.3 真机验证。
- workflow 只写入 HealthKit entitlement，不会自动写入 Apple Developer provisioning profile。
- 现有工程的 .entitlements 文件只作为 ldid 输入，最终是否有效以主程序内的签名块检查为准。

## 资料

- Homebrew ldid formula：https://formulae.brew.sh/formula/ldid
- TrollStore 官方 README：https://raw.githubusercontent.com/opa334/TrollStore/main/README.md
- Apple HealthKit entitlement：https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.healthkit
- Apple requestAuthorization：https://developer.apple.com/documentation/healthkit/hkhealthstore/requestauthorization%28toshare%3Aread%3A%29

## 待确认

请确认是否按“方案 A + 专门 healthKitError 状态 + 独立 TrollStore artifact + CI entitlement 硬校验”实施。

