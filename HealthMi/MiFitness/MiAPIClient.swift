import Foundation
import os

enum MiAPIError: LocalizedError {
    case notConnected
    case api(code: Int, message: String?)
    case paginationLimit
    case cursorLoop
    case executionDeadlineExceeded
    case invalidResponse(String)
    case network(Error)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "尚未登录小米服务"
        case .api(let code, let message):
            return "小米 API 错误（code=\(code)）：\(message ?? "未知")"
        case .paginationLimit:
            return "分页超过安全上限"
        case .cursorLoop:
            return "分页游标循环，已终止"
        case .executionDeadlineExceeded:
            return "快捷指令执行时间将用尽，已停止启动新的网络请求。"
        case .invalidResponse(let detail):
            return "响应解析失败：\(detail)"
        case .network(let error):
            return "网络错误：\(error.localizedDescription)"
        case .http(let code):
            return "HTTP 错误：\(code)"
        }
    }

    /// 是否可重试（网络错误、429/5xx 类 HTTP 错误）。
    var isRetriable: Bool {
        switch self {
        case .network: return true
        case .http(let code): return code == 429 || (500...599).contains(code)
        default: return false
        }
    }

    /// 是否认证错误（passToken 过期/无效，code=70016），不可重试。
    var isAuthError: Bool {
        if case .api(let code, _) = self, code == 70016 { return true }
        return false
    }

    /// Task 或 URLSession 被取消时不应进入指数退避重试。
    var isCancellation: Bool {
        switch self {
        case .network(let underlying):
            if underlying is CancellationError { return true }
            let nsError = underlying as NSError
            return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        default:
            return false
        }
    }

    var isExecutionDeadlineExceeded: Bool {
        if case .executionDeadlineExceeded = self { return true }
        return false
    }
}

struct MiRequestPolicy: Sendable {
    let requestTimeoutInterval: TimeInterval
    let maxRetries: Int
    let pageDelayNanoseconds: UInt64
    let deadline: Date?
    let safetyMargin: TimeInterval

    static let standard = MiRequestPolicy(
        requestTimeoutInterval: 30,
        maxRetries: 3,
        pageDelayNanoseconds: 200_000_000,
        deadline: nil,
        safetyMargin: 0
    )

    static func shortcut(deadline: Date) -> Self {
        MiRequestPolicy(
            requestTimeoutInterval: 8,
            maxRetries: 0,
            pageDelayNanoseconds: 200_000_000,
            deadline: deadline,
            safetyMargin: 1
        )
    }

    func timeoutForNextRequest(now: Date = Date()) throws -> TimeInterval {
        guard let deadline else { return requestTimeoutInterval }
        let remaining = deadline.timeIntervalSince(now) - safetyMargin
        guard remaining > 0 else { throw MiAPIError.executionDeadlineExceeded }
        return min(requestTimeoutInterval, remaining)
    }

    func checkDeadline() throws {
        guard deadline != nil else { return }
        _ = try timeoutForNextRequest()
    }
}

/// 小米健康云数据客户端。Swift 移植自 `mi_fitness_cloud.MiFitnessCloudAdapter`。
///
/// 行为要点（与 Python 完全一致）：
/// - 用 Cookie 登录换取 `ssecurity` 与重定向会话 Cookie；
/// - 每个请求体用 `signed_nonce = SHA256(ssecurity||nonce)` 做 RC4 加密 + SHA1 签名；
/// - 数据接口 `get_fitness_data_by_time` 按 key 分页拉取；
/// - 运动记录走独立的 `get_sport_records_by_time`。
actor MiAPIClient {
    /// 当前区域的时区（用于日边界计算）。
    static var regionTimeZone: TimeZone { MiRegion.current.timeZone }


    private var baseURL: String { MiRegion.current.baseURL }
    private let dataPath = "/app/v1/data/get_fitness_data_by_time"
    private let sportRecordsPath = "/app/v1/data/get_sport_records_by_time"
    private let maxPages = 200

    private var state: MiSessionState?
    private var diagnosticRunID: UUID?
    private let session: URLSession
    private let requestPolicy: MiRequestPolicy

    init(requestPolicy: MiRequestPolicy = .standard) {
        self.requestPolicy = requestPolicy
        let config = URLSessionConfiguration.ephemeral
        // 与 Python 一致：手动管理 Cookie，不交给 URLSession 的存储。
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = requestPolicy.requestTimeoutInterval
        self.session = URLSession(configuration: config)
    }

    var isConnected: Bool { state != nil }

    func setDiagnosticRunID(_ runID: UUID?) {
        diagnosticRunID = runID
    }

    /// 登录并建立会话。
    func connect(userId: String, passToken: String) async throws {
        self.state = try await MiSessionClient.login(
            userId: userId,
            passToken: passToken,
            requestPolicy: requestPolicy
        )
    }

    // MARK: - 请求签名与发送（对应 Python `_request`）

    /// 按 Python 端字典插入顺序（start_time, end_time, key, limit?, next_key?）生成紧凑 JSON，
    /// 保证与已验证实现逐字节一致（JSONSerialization 的键序不确定，不能使用）。
    static func dataString(
        startTime: Int, endTime: Int, key: String, limit: Int? = nil, nextKey: String? = nil
    ) -> String {
        var s = "{\"start_time\":\(startTime),\"end_time\":\(endTime),\"key\":\"\(key)\""
        if let limit { s += ",\"limit\":\(limit)" }
        if let nextKey { s += ",\"next_key\":\"\(nextKey)\"" }
        s += "}"
        return s
    }

    /// 带重试的签名请求：网络错误和 429/5xx HTTP 错误自动重试，
    /// 认证错误（code=70016）不重试直接抛出。
    private func signedRequest(
        path: String,
        dataString: String,
        operation: String
    ) async throws -> [String: Any] {
        let retries = requestPolicy.maxRetries
        var lastError: Error?
        for attempt in 0...retries {
            if attempt > 0 {
                // 指数退避：1s → 2s → 4s，加 0–200ms 随机抖动
                let baseDelay = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
                let jitter = UInt64.random(in: 0...200_000_000)
                DiagnosticLogger.record(
                    .warning,
                    category: .network,
                    event: "mi.api.request.retry_scheduled",
                    message: "小米 API 请求将按退避策略重试",
                    runID: diagnosticRunID,
                    dataType: operation,
                    metadata: [
                        "path": path,
                        "attempt": String(attempt),
                        "maximumRetries": String(retries),
                        "delayMs": String((baseDelay + jitter) / 1_000_000),
                    ]
                )
                AppLog.apiClient.info("重试 \(attempt)/\(retries) path=\(path)")
                try await Task.sleep(nanoseconds: baseDelay + jitter)
            }
            do {
                return try await signedRequestOnce(
                    path: path,
                    dataString: dataString,
                    operation: operation,
                    attempt: attempt
                )
            } catch let error as MiAPIError {
                if error.isAuthError || error.isCancellation || !error.isRetriable {
                    DiagnosticLogger.record(
                        error.isCancellation ? .notice : .error,
                        category: .network,
                        event: "mi.api.request.failed_without_retry",
                        message: "小米 API 请求失败且不会重试",
                        runID: diagnosticRunID,
                        dataType: operation,
                        error: error,
                        metadata: [
                            "path": path,
                            "attempt": String(attempt),
                            "isAuthenticationError": String(error.isAuthError),
                            "isCancellation": String(error.isCancellation),
                        ]
                    )
                    throw error
                }
                lastError = error
            } catch is CancellationError {
                DiagnosticLogger.record(
                    .notice,
                    category: .network,
                    event: "mi.api.request.cancelled",
                    message: "小米 API 请求收到取消",
                    runID: diagnosticRunID,
                    dataType: operation,
                    metadata: ["path": path, "attempt": String(attempt)]
                )
                throw CancellationError()
            } catch where Task.isCancelled {
                DiagnosticLogger.record(
                    .notice,
                    category: .network,
                    event: "mi.api.request.cancelled",
                    message: "小米 API 请求所属任务已取消",
                    runID: diagnosticRunID,
                    dataType: operation,
                    metadata: ["path": path, "attempt": String(attempt)]
                )
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        DiagnosticLogger.record(
            .error,
            category: .network,
            event: "mi.api.request.retries_exhausted",
            message: "小米 API 请求达到最大重试次数",
            runID: diagnosticRunID,
            dataType: operation,
            error: lastError,
            metadata: ["path": path, "maximumRetries": String(retries)]
        )
        throw lastError ?? MiAPIError.invalidResponse("重试耗尽")
    }

    private func signedRequestOnce(
        path: String,
        dataString: String,
        operation: String,
        attempt: Int
    ) async throws -> [String: Any] {
        guard let state else { throw MiAPIError.notConnected }

        var form: [String: String] = ["data": dataString]
        let nonce = MiCrypto.genNonce()
        let signedNonce = MiCrypto.genSignedNonce(ssecurity: state.ssecurity, nonce: nonce)

        // 第一次签名只含 data
        form["rc4_hash__"] = MiCrypto.genSignature(
            method: "POST", path: path, values: form, signedNonce: signedNonce
        )

        // 用 RC4 加密 data 与 rc4_hash__，再对加密值签名
        var encrypted: [String: String] = [:]
        for (key, value) in form {
            let cipher = MiCrypto.rc4Crypt(key: signedNonce, payload: Array(value.utf8))
            encrypted[key] = Data(cipher).base64EncodedString()
        }
        encrypted["signature"] = MiCrypto.genSignature(
            method: "POST", path: path, values: encrypted, signedNonce: signedNonce
        )
        encrypted["_nonce"] = Data(nonce).base64EncodedString()

        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.timeoutInterval = try requestPolicy.timeoutForNextRequest()
        request.httpMethod = "POST"
        request.setValue(state.cookies, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Python `urlencode`：值做百分号编码（Base64 中的 + / = 必须转义）
        let body = encrypted
            .map { "\($0.key)=\(percentEncode($0.value))" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let data: Data
        let response: URLResponse
        let requestStartedAt = ProcessInfo.processInfo.systemUptime
        DiagnosticLogger.record(
            .debug,
            category: .network,
            event: "mi.api.request.started",
            message: "开始发送小米健康 API 请求",
            runID: diagnosticRunID,
            dataType: operation,
            metadata: [
                "method": "POST",
                "path": path,
                "attempt": String(attempt),
                "requestTimeoutMs": String(Int(request.timeoutInterval * 1_000)),
                "requestBytes": String(request.httpBody?.count ?? 0),
            ]
        )
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            DiagnosticLogger.record(
                .error,
                category: .network,
                event: "mi.api.request.transport_failed",
                message: "小米健康 API 请求传输失败",
                runID: diagnosticRunID,
                dataType: operation,
                error: error,
                metadata: [
                    "path": path,
                    "attempt": String(attempt),
                    "durationMs": Self.durationMilliseconds(since: requestStartedAt),
                ]
            )
            throw MiAPIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            DiagnosticLogger.record(
                .error,
                category: .network,
                event: "mi.api.request.invalid_http_response",
                message: "小米健康 API 请求未返回 HTTP 响应",
                runID: diagnosticRunID,
                dataType: operation,
                metadata: [
                    "path": path,
                    "attempt": String(attempt),
                    "responseBytes": String(data.count),
                    "durationMs": Self.durationMilliseconds(since: requestStartedAt),
                ]
            )
            throw MiAPIError.invalidResponse("响应不是 HTTP")
        }
        DiagnosticLogger.record(
            .debug,
            category: .network,
            event: "mi.api.request.response_received",
            message: "收到小米健康 API HTTP 响应",
            runID: diagnosticRunID,
            dataType: operation,
            metadata: [
                "path": path,
                "attempt": String(attempt),
                "httpStatus": String(http.statusCode),
                "responseBytes": String(data.count),
                "durationMs": Self.durationMilliseconds(since: requestStartedAt),
            ]
        )
        if http.statusCode != 200 {
            AppLog.apiClient.error("HTTP \(http.statusCode) path=\(path)")
            throw MiAPIError.http(http.statusCode)
        }
        guard let base64 = String(data: data, encoding: .utf8),
              let cipher = Data(base64Encoded: base64)
        else {
            DiagnosticLogger.record(
                .error,
                category: .network,
                event: "mi.api.response.invalid_base64",
                message: "小米健康 API 响应不是合法 Base64",
                runID: diagnosticRunID,
                dataType: operation,
                metadata: ["path": path, "attempt": String(attempt), "responseBytes": String(data.count)]
            )
            throw MiAPIError.invalidResponse("响应不是合法 Base64")
        }

        let plain = MiCrypto.rc4Crypt(key: signedNonce, payload: Array(cipher))
        guard let obj = MiJSON.object(from: Data(plain)) else {
            DiagnosticLogger.record(
                .error,
                category: .network,
                event: "mi.api.response.invalid_json",
                message: "小米健康 API 响应解密后无法解析为 JSON",
                runID: diagnosticRunID,
                dataType: operation,
                metadata: ["path": path, "attempt": String(attempt), "responseBytes": String(data.count)]
            )
            throw MiAPIError.invalidResponse("解密后不是合法 JSON")
        }
        let code = MiJSON.int(obj["code"]) ?? -1
        guard code == 0 else {
            DiagnosticLogger.record(
                .error,
                category: .network,
                event: "mi.api.response.service_error",
                message: "小米健康 API 返回服务端错误码",
                runID: diagnosticRunID,
                dataType: operation,
                metadata: [
                    "path": path,
                    "attempt": String(attempt),
                    "serviceCode": String(code),
                ]
            )
            throw MiAPIError.api(code: code, message: MiJSON.string(obj["message"]))
        }
        DiagnosticLogger.record(
            .debug,
            category: .network,
            event: "mi.api.response.decrypted",
            message: "小米健康 API 响应解密和外层解析成功",
            runID: diagnosticRunID,
            dataType: operation,
            metadata: [
                "path": path,
                "attempt": String(attempt),
                "serviceCode": String(code),
                "durationMs": Self.durationMilliseconds(since: requestStartedAt),
            ]
        )
        // 与 Python 一致：返回内层 result 字典（data_list / sport_records 都在里面）
        return MiJSON.object(from: Data(plain))?["result"] as? [String: Any] ?? [:]
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    // MARK: - 分页拉取

    /// 按 key 拉取某时间区间的数据（对应 `_fetch_key`）。
    func fetchData(key: String, startTime: Int, endTime: Int) async throws -> [MiItem] {
        let fetchStartedAt = ProcessInfo.processInfo.systemUptime
        DiagnosticLogger.record(
            .info,
            category: .network,
            event: "mi.api.data_fetch.started",
            message: "开始分页拉取小米健康数据",
            runID: diagnosticRunID,
            dataType: key,
            metadata: ["path": dataPath, "startEpoch": String(startTime), "endEpoch": String(endTime)]
        )
        var items: [MiItem] = []
        var nextKey: String?
        var seen = Set<String>()
        var page = 0
        while true {
            page += 1
            guard page <= maxPages else {
                DiagnosticLogger.record(
                    .error,
                    category: .network,
                    event: "mi.api.pagination.limit_reached",
                    message: "小米健康数据分页达到安全上限",
                    runID: diagnosticRunID,
                    dataType: key,
                    metadata: ["path": dataPath, "pageCount": String(page - 1)]
                )
                throw MiAPIError.paginationLimit
            }
            let body = Self.dataString(
                startTime: startTime, endTime: endTime, key: key, nextKey: nextKey
            )
            let pageStartedAt = ProcessInfo.processInfo.systemUptime
            DiagnosticLogger.record(
                .debug,
                category: .network,
                event: "mi.api.data_page.started",
                message: "开始请求小米健康数据分页",
                runID: diagnosticRunID,
                dataType: key,
                metadata: ["path": dataPath, "pageIndex": String(page)]
            )
            let result = try await signedRequest(path: dataPath, dataString: body, operation: key)

            var pageItemCount = 0
            if let list = result["data_list"] as? [[String: Any]] {
                pageItemCount = list.count
                items.append(contentsOf: list.map(Self.makeItem))
            }
            let hasMore = MiJSON.bool(result["has_more"]) ?? false
            let cursor = MiJSON.string(result["next_key"])
            DiagnosticLogger.record(
                .debug,
                category: .network,
                event: "mi.api.data_page.completed",
                message: "小米健康数据分页解析完成",
                runID: diagnosticRunID,
                dataType: key,
                metadata: [
                    "path": dataPath,
                    "pageIndex": String(page),
                    "itemCount": String(pageItemCount),
                    "hasMore": String(hasMore),
                    "durationMs": Self.durationMilliseconds(since: pageStartedAt),
                ]
            )
            if !hasMore || cursor == nil { break }
            if seen.contains(cursor!) {
                DiagnosticLogger.record(
                    .error,
                    category: .network,
                    event: "mi.api.pagination.cursor_loop",
                    message: "小米健康数据分页游标重复，已停止请求",
                    runID: diagnosticRunID,
                    dataType: key,
                    metadata: ["path": dataPath, "pageIndex": String(page)]
                )
                throw MiAPIError.cursorLoop
            }
            seen.insert(cursor!)
            nextKey = cursor
            // 分页请求间隔，避免高频请求触发小米限流
            try requestPolicy.checkDeadline()
            try await Task.sleep(nanoseconds: requestPolicy.pageDelayNanoseconds)
        }
        DiagnosticLogger.record(
            .info,
            category: .network,
            event: "mi.api.data_fetch.completed",
            message: "小米健康数据分页拉取完成",
            runID: diagnosticRunID,
            dataType: key,
            metadata: [
                "path": dataPath,
                "pageCount": String(page),
                "itemCount": String(items.count),
                "durationMs": Self.durationMilliseconds(since: fetchStartedAt),
            ]
        )
        return items
    }

    /// 拉取运动记录（对应 `_fetch_sport_records_by_time`）。
    func fetchSportRecords(startTime: Int, endTime: Int) async throws -> [MiItem] {
        let fetchStartedAt = ProcessInfo.processInfo.systemUptime
        DiagnosticLogger.record(
            .info,
            category: .network,
            event: "mi.api.sport_fetch.started",
            message: "开始分页拉取小米运动记录",
            runID: diagnosticRunID,
            dataType: "sport",
            metadata: ["path": sportRecordsPath, "startEpoch": String(startTime), "endEpoch": String(endTime)]
        )
        var items: [MiItem] = []
        var nextKey: String?
        var seen = Set<String>()
        var page = 0
        while true {
            page += 1
            guard page <= maxPages else {
                DiagnosticLogger.record(
                    .error,
                    category: .network,
                    event: "mi.api.sport_pagination.limit_reached",
                    message: "小米运动记录分页达到安全上限",
                    runID: diagnosticRunID,
                    dataType: "sport",
                    metadata: ["path": sportRecordsPath, "pageCount": String(page - 1)]
                )
                throw MiAPIError.paginationLimit
            }
            let body = Self.dataString(
                startTime: startTime, endTime: endTime, key: "sport", limit: 50, nextKey: nextKey
            )
            let pageStartedAt = ProcessInfo.processInfo.systemUptime
            DiagnosticLogger.record(
                .debug,
                category: .network,
                event: "mi.api.sport_page.started",
                message: "开始请求小米运动记录分页",
                runID: diagnosticRunID,
                dataType: "sport",
                metadata: ["path": sportRecordsPath, "pageIndex": String(page)]
            )
            let result = try await signedRequest(
                path: sportRecordsPath,
                dataString: body,
                operation: "sport"
            )

            var pageItemCount = 0
            if let list = result["sport_records"] as? [[String: Any]] {
                pageItemCount = list.count
                items.append(contentsOf: list.map(Self.makeItem))
            }
            let hasMore = MiJSON.bool(result["has_more"]) ?? false
            let cursor = MiJSON.string(result["next_key"])
            DiagnosticLogger.record(
                .debug,
                category: .network,
                event: "mi.api.sport_page.completed",
                message: "小米运动记录分页解析完成",
                runID: diagnosticRunID,
                dataType: "sport",
                metadata: [
                    "path": sportRecordsPath,
                    "pageIndex": String(page),
                    "itemCount": String(pageItemCount),
                    "hasMore": String(hasMore),
                    "durationMs": Self.durationMilliseconds(since: pageStartedAt),
                ]
            )
            if !hasMore || cursor == nil { break }
            if seen.contains(cursor!) {
                DiagnosticLogger.record(
                    .error,
                    category: .network,
                    event: "mi.api.sport_pagination.cursor_loop",
                    message: "小米运动记录分页游标重复，已停止请求",
                    runID: diagnosticRunID,
                    dataType: "sport",
                    metadata: ["path": sportRecordsPath, "pageIndex": String(page)]
                )
                throw MiAPIError.cursorLoop
            }
            seen.insert(cursor!)
            nextKey = cursor
            // 分页请求间隔，避免高频请求触发小米限流
            try requestPolicy.checkDeadline()
            try await Task.sleep(nanoseconds: requestPolicy.pageDelayNanoseconds)
        }
        DiagnosticLogger.record(
            .info,
            category: .network,
            event: "mi.api.sport_fetch.completed",
            message: "小米运动记录分页拉取完成",
            runID: diagnosticRunID,
            dataType: "sport",
            metadata: [
                "path": sportRecordsPath,
                "pageCount": String(page),
                "itemCount": String(items.count),
                "durationMs": Self.durationMilliseconds(since: fetchStartedAt),
            ]
        )
        return items
    }

    private static func durationMilliseconds(since start: TimeInterval) -> String {
        String(max(0, Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)))
    }

    // MARK: - 时间换算（中国区 +08:00）

    /// 某日历日 00:00:00(+08:00) 的时间戳。
    static func dayStartEpoch(of day: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.regionTimeZone
        let start = cal.startOfDay(for: day)
        return Int(start.timeIntervalSince1970)
    }

    /// 某日历日 23:59:59(+08:00) 的时间戳。
    static func dayEndEpoch(of day: Date) -> Int {
        dayStartEpoch(of: day) + 86_399
    }

    // MARK: - 原始条目提取

    private static func makeItem(_ raw: [String: Any]) -> MiItem {
        var valueData: Data?
        if let string = raw["value"] as? String {
            valueData = Data(string.utf8)
        } else if let dict = raw["value"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict) {
            valueData = data
        } else if let arr = raw["value"] as? [Any],
                  let data = try? JSONSerialization.data(withJSONObject: arr) {
            valueData = data
        }
        return MiItem(
            time: MiJSON.int(raw["time"]),
            zoneOffset: MiJSON.int(raw["zone_offset"]),
            zoneName: MiJSON.string(raw["zone_name"]),
            sid: MiJSON.string(raw["sid"]),
            key: MiJSON.string(raw["key"]),
            category: MiJSON.string(raw["category"]),
            valueData: valueData
        )
    }
}
