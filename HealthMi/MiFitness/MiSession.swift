import Foundation

/// 一次成功登录后的会话凭据（对应 Python `_login_with_token` 得到的字段）。
struct MiSessionState: Sendable {
    let userId: String
    let passToken: String
    /// 解 Base64 后的 ssecurity 原始字节，用于派生 RC4 密钥。
    let ssecurity: [UInt8]
    /// 重定向后收集到的会话 Cookie 串（`name=value; name=value`）。
    let cookies: String
}

enum MiLoginError: LocalizedError {
    case badPayload(String)
    case loginRejected(code: Int?, description: String?)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .badPayload(let detail):
            return "登录响应格式异常：\(detail)"
        case .loginRejected(let code, let description):
            return "登录被拒绝（code=\(code ?? -1)）：\(description ?? "未知错误")"
        case .network(let error):
            return "网络错误：\(error.localizedDescription)"
        }
    }
}

/// 登录 HTTP 客户端（对应 Python `_login_with_token` + `_read_login_payload`）。
enum MiSessionClient {
    private static let loginPrefix = "&&&START&&&"

    /// 用小米账号 Cookie 换取服务会话。
    /// - Parameters:
    ///   - userId: account.xiaomi.com Cookie 中的 userId
    ///   - passToken: 账号 Cookie 中的 passToken（有效期短，过期后需重新获取）
    static func login(
        userId: String,
        passToken: String,
        requestPolicy: MiRequestPolicy = .standard
    ) async throws -> MiSessionState {
        let loginStartedAt = ProcessInfo.processInfo.systemUptime
        DiagnosticLogger.record(
            .info,
            category: .authentication,
            event: "mi.login.exchange.started",
            message: "开始向小米账号服务交换会话",
            metadata: ["endpointPath": "/pass/serviceLogin"]
        )
        var request = URLRequest(url: URL(string: "https://account.xiaomi.com/pass/serviceLogin?_json=true&sid=miothealth")!)
        request.timeoutInterval = try requestPolicy.timeoutForNextRequest()
        request.setValue("userId=\(userId); passToken=\(passToken)", forHTTPHeaderField: "Cookie")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            DiagnosticLogger.record(
                .error,
                category: .authentication,
                event: "mi.login.exchange.network_failed",
                message: "小米账号会话交换请求失败",
                error: error,
                metadata: ["durationMs": durationMilliseconds(since: loginStartedAt)]
            )
            throw MiLoginError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            DiagnosticLogger.record(
                .error,
                category: .authentication,
                event: "mi.login.exchange.invalid_response",
                message: "小米账号会话交换未返回 HTTP 响应",
                metadata: ["responseBytes": String(data.count)]
            )
            throw MiLoginError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            DiagnosticLogger.record(
                .error,
                category: .authentication,
                event: "mi.login.exchange.http_failed",
                message: "小米账号会话交换返回非成功 HTTP 状态",
                metadata: [
                    "httpStatus": String(http.statusCode),
                    "responseBytes": String(data.count),
                    "durationMs": durationMilliseconds(since: loginStartedAt),
                ]
            )
            throw MiLoginError.loginRejected(code: http.statusCode, description: "HTTP \(http.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(loginPrefix) else {
            DiagnosticLogger.record(
                .error,
                category: .authentication,
                event: "mi.login.exchange.invalid_payload_prefix",
                message: "小米账号会话交换响应缺少预期格式前缀",
                metadata: ["responseBytes": String(data.count)]
            )
            throw MiLoginError.badPayload("响应缺少 \(loginPrefix) 前缀")
        }

        let json = text.dropFirst(loginPrefix.count).data(using: .utf8) ?? Data()
        guard let obj = MiJSON.object(from: json) else {
            DiagnosticLogger.record(
                .error,
                category: .authentication,
                event: "mi.login.exchange.json_parse_failed",
                message: "小米账号会话交换响应 JSON 无法解析",
                metadata: ["responseBytes": String(data.count)]
            )
            throw MiLoginError.badPayload("无法解析 JSON")
        }

        // 若登录被拒，服务端返回 code 而非 passToken
        if let code = MiJSON.int(obj["code"]), code != 0, obj["passToken"] == nil {
            DiagnosticLogger.record(
                .warning,
                category: .authentication,
                event: "mi.login.exchange.rejected",
                message: "小米账号服务拒绝会话交换",
                metadata: [
                    "serviceCode": String(code),
                    "durationMs": durationMilliseconds(since: loginStartedAt),
                ]
            )
            throw MiLoginError.loginRejected(code: code, description: MiJSON.string(obj["description"]))
        }

        guard let newPassToken = MiJSON.string(obj["passToken"]),
              let ssecurityB64 = MiJSON.string(obj["ssecurity"]),
              let ssecurity = Data(base64Encoded: ssecurityB64),
              let location = MiJSON.string(obj["location"])
        else {
            DiagnosticLogger.record(
                .error,
                category: .authentication,
                event: "mi.login.exchange.required_fields_missing",
                message: "小米账号响应缺少建立会话所需字段",
                metadata: [
                    "hasPassToken": String(MiJSON.string(obj["passToken"]) != nil),
                    "hasSecurityMaterial": String(MiJSON.string(obj["ssecurity"]) != nil),
                    "hasLocation": String(MiJSON.string(obj["location"]) != nil),
                ]
            )
            throw MiLoginError.badPayload("缺少 passToken/ssecurity/location")
        }
        let resolvedUserId = MiJSON.string(obj["userId"]) ?? userId

        // 跟随 location 收集会话 Cookie。
        guard let redirectURL = URL(string: location) else {
            DiagnosticLogger.record(
                .error,
                category: .authentication,
                event: "mi.login.redirect.invalid_url",
                message: "小米账号返回的会话重定向地址无法解析"
            )
            throw MiLoginError.badPayload("location 无法解析为 URL")
        }
        let redirectStartedAt = ProcessInfo.processInfo.systemUptime
        DiagnosticLogger.record(
            .debug,
            category: .authentication,
            event: "mi.login.redirect.started",
            message: "开始请求小米账号会话重定向",
            metadata: ["host": redirectURL.host ?? "unknown"]
        )
        let redirectResult: (Data, URLResponse)
        do {
            redirectResult = try await URLSession.shared.data(from: redirectURL)
        } catch {
            DiagnosticLogger.record(
                .error,
                category: .authentication,
                event: "mi.login.redirect.network_failed",
                message: "小米账号会话重定向请求失败",
                error: error,
                metadata: ["durationMs": durationMilliseconds(since: redirectStartedAt)]
            )
            throw MiLoginError.network(error)
        }
        let redirectResponse = redirectResult.1
        guard let redirectHTTP = redirectResponse as? HTTPURLResponse else {
            DiagnosticLogger.record(
                .error,
                category: .authentication,
                event: "mi.login.redirect.invalid_response",
                message: "小米账号会话重定向未返回 HTTP 响应"
            )
            throw MiLoginError.network(URLError(.badServerResponse))
        }
        if !(200..<400).contains(redirectHTTP.statusCode) {
            DiagnosticLogger.record(
                .warning,
                category: .authentication,
                event: "mi.login.redirect.http_failed",
                message: "小米账号会话重定向返回异常 HTTP 状态",
                metadata: [
                    "httpStatus": String(redirectHTTP.statusCode),
                    "durationMs": durationMilliseconds(since: redirectStartedAt),
                ]
            )
        }

        // 注意：URLSession 会把多个 Set-Cookie 头合并成一个 ", " 连接的字符串，
        // 而 `value(forHTTPHeaderField:)` 只返回第一个。这里必须解析合并串拿到全部 cookie
        // （否则会丢掉关键的 serviceToken，导致后续数据请求被判定未认证）。
        let cookieHeader = (redirectHTTP.allHeaderFields.first {
            ($0.key as? String)?.lowercased() == "set-cookie"
        }?.value as? String) ?? ""

        let cookieParts: [String] = cookieHeader
            .components(separatedBy: ", ")
            .compactMap { chunk in
                let nameValue = chunk.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                return nameValue.contains("=") ? nameValue : nil
            }
        let cookies = cookieParts.joined(separator: "; ")

        DiagnosticLogger.record(
            .info,
            category: .authentication,
            event: "mi.login.exchange.completed",
            message: "小米账号会话建立完成",
            metadata: [
                "cookieCount": String(cookieParts.count),
                "redirectHTTPStatus": String(redirectHTTP.statusCode),
                "redirectDurationMs": durationMilliseconds(since: redirectStartedAt),
                "totalDurationMs": durationMilliseconds(since: loginStartedAt),
            ]
        )

        return MiSessionState(
            userId: resolvedUserId,
            passToken: newPassToken,
            ssecurity: Array(ssecurity),
            cookies: cookies
        )
    }

    private static func durationMilliseconds(since start: TimeInterval) -> String {
        String(max(0, Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)))
    }
}
