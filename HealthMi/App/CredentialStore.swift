import Foundation
import Security

/// 小米凭据的 Keychain 存储。
enum CredentialStore {
    private static let service = "com.healthmi.HealthMi"
    /// 旧版 service 标识符（标识符统一前的值，用于一次性迁移）。
    private static let legacyService = "com.example.HealthMi"
    private static let userIdKey = "mi_fitness_user_id"
    private static let passTokenKey = "mi_fitness_pass_token"
    private static let migrationKey = "keychain_migrated_v1"

    /// 一次性迁移：把旧 service 下的凭据迁移到新 service。
    /// 在 App 启动时调用，已迁移过则跳过。
    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            DiagnosticLogger.record(
                .debug,
                category: .keychain,
                event: "keychain.migration.skipped",
                message: "Keychain 凭据迁移已完成，跳过"
            )
            return
        }
        DiagnosticLogger.record(
            .info,
            category: .keychain,
            event: "keychain.migration.started",
            message: "开始检查旧 Keychain 服务中的凭据"
        )
        // 新 service 下已有凭据则无需迁移
        if load() != nil {
            UserDefaults.standard.set(true, forKey: migrationKey)
            DiagnosticLogger.record(
                .info,
                category: .keychain,
                event: "keychain.migration.current_credentials_found",
                message: "当前 Keychain 服务已有完整凭据，无需迁移"
            )
            return
        }
        // 尝试从旧 service 读取
        guard let userId = get(key: userIdKey, service: legacyService),
              let passToken = get(key: passTokenKey, service: legacyService)
        else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            DiagnosticLogger.record(
                .notice,
                category: .keychain,
                event: "keychain.migration.no_legacy_credentials",
                message: "未找到旧服务凭据，迁移标记已完成"
            )
            return
        }
        // 写入新 service
        do {
            try set(key: userIdKey, value: userId, service: service)
            try set(key: passTokenKey, value: passToken, service: service)
        } catch {
            // 写入失败不标记已迁移，下次启动重试
            DiagnosticLogger.record(
                .error,
                category: .keychain,
                event: "keychain.migration.failed",
                message: "迁移旧 Keychain 凭据失败",
                error: error
            )
            return
        }
        // 删除旧 service 下的凭据
        try? delete(key: userIdKey, service: legacyService)
        try? delete(key: passTokenKey, service: legacyService)
        UserDefaults.standard.set(true, forKey: migrationKey)
        DiagnosticLogger.record(
            .info,
            category: .keychain,
            event: "keychain.migration.completed",
            message: "旧 Keychain 凭据迁移完成"
        )
    }

    static func save(userId: String, passToken: String) throws {
        DiagnosticLogger.record(
            .info,
            category: .keychain,
            event: "keychain.credentials.write.started",
            message: "开始写入小米凭据"
        )
        do {
            try set(key: userIdKey, value: userId, service: service)
            try set(key: passTokenKey, value: passToken, service: service)
            DiagnosticLogger.record(
                .info,
                category: .keychain,
                event: "keychain.credentials.write.completed",
                message: "小米凭据已写入 Keychain"
            )
        } catch {
            DiagnosticLogger.record(
                .error,
                category: .keychain,
                event: "keychain.credentials.write.failed",
                message: "写入小米凭据失败",
                error: error
            )
            throw error
        }
    }

    static func load() -> (userId: String, passToken: String)? {
        let userId = get(key: userIdKey, service: service)
        let passToken = get(key: passTokenKey, service: service)
        guard let userId, let passToken else {
            DiagnosticLogger.record(
                .debug,
                category: .keychain,
                event: "keychain.credentials.read.incomplete",
                message: "Keychain 中没有完整的小米凭据",
                metadata: ["hasAccountField": String(userId != nil), "hasSessionField": String(passToken != nil)]
            )
            return nil
        }
        DiagnosticLogger.record(
            .debug,
            category: .keychain,
            event: "keychain.credentials.read.completed",
            message: "Keychain 凭据读取成功"
        )
        return (userId, passToken)
    }

    /// 读取凭据并保留 Keychain 系统错误，供后台排队和详细错误报告使用。
    /// 返回 nil 表示本机没有完整凭据；Keychain 访问失败则抛出具体 OSStatus。
    static func loadThrowing() throws -> (userId: String, passToken: String)? {
        do {
            let userId = try getThrowing(key: userIdKey, service: service)
            let passToken = try getThrowing(key: passTokenKey, service: service)
            guard let userId, let passToken else {
                DiagnosticLogger.record(
                    .notice,
                    category: .keychain,
                    event: "keychain.credentials.read_throwing.incomplete",
                    message: "Keychain 中没有完整的小米凭据",
                    metadata: ["hasAccountField": String(userId != nil), "hasSessionField": String(passToken != nil)]
                )
                return nil
            }
            DiagnosticLogger.record(
                .debug,
                category: .keychain,
                event: "keychain.credentials.read_throwing.completed",
                message: "Keychain 凭据读取成功"
            )
            return (userId, passToken)
        } catch {
            DiagnosticLogger.record(
                .error,
                category: .keychain,
                event: "keychain.credentials.read_throwing.failed",
                message: "读取 Keychain 凭据失败",
                error: error
            )
            throw error
        }
    }

    static func delete() {
        var failures = 0
        do {
            try delete(key: userIdKey, service: service)
        } catch {
            failures += 1
            DiagnosticLogger.record(
                .error,
                category: .keychain,
                event: "keychain.credentials.delete.account_field.failed",
                message: "删除 Keychain 账号字段失败",
                error: error
            )
        }
        do {
            try delete(key: passTokenKey, service: service)
        } catch {
            failures += 1
            DiagnosticLogger.record(
                .error,
                category: .keychain,
                event: "keychain.credentials.delete.session_field.failed",
                message: "删除 Keychain 会话字段失败",
                error: error
            )
        }
        if failures == 0 {
            DiagnosticLogger.record(
                .notice,
                category: .keychain,
                event: "keychain.credentials.deleted",
                message: "小米凭据已从 Keychain 删除"
            )
        }
    }

    // MARK: - 底层

    private static func set(key: String, value: String, service: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                DiagnosticLogger.record(
                    .error,
                    category: .keychain,
                    event: "keychain.item.add.failed",
                    message: "Keychain 添加凭据失败",
                    errorDomain: "Security",
                    errorCode: Int(addStatus)
                )
                throw KeychainError(status: addStatus)
            }
            DiagnosticLogger.record(
                .debug,
                category: .keychain,
                event: "keychain.item.added",
                message: "Keychain 凭据条目已创建"
            )
        } else if status != errSecSuccess {
            DiagnosticLogger.record(
                .error,
                category: .keychain,
                event: "keychain.item.update.failed",
                message: "Keychain 更新凭据失败",
                errorDomain: "Security",
                errorCode: Int(status)
            )
            throw KeychainError(status: status)
        } else {
            DiagnosticLogger.record(
                .debug,
                category: .keychain,
                event: "keychain.item.updated",
                message: "Keychain 凭据条目已更新"
            )
        }
    }

    private static func get(key: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                DiagnosticLogger.record(
                    .warning,
                    category: .keychain,
                    event: "keychain.item.read.failed",
                    message: "Keychain 读取凭据条目失败",
                    errorDomain: "Security",
                    errorCode: Int(status)
                )
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func getThrowing(key: String, service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            DiagnosticLogger.record(
                .error,
                category: .keychain,
                event: "keychain.item.read_throwing.failed",
                message: "Keychain 读取凭据条目失败",
                errorDomain: "Security",
                errorCode: Int(status)
            )
            throw KeychainError(status: status)
        }
        guard let data = result as? Data else {
            throw KeychainError(status: errSecDecode)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return value
    }

    private static func delete(key: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Keychain 错误（\(status)）"
        }
    }
}
