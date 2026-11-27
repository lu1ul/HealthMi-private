import Foundation
import MetricKit

indirect enum DiagnosticJSONValue: Codable, Hashable, Sendable {
    case object([String: DiagnosticJSONValue])
    case array([DiagnosticJSONValue])
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if try single.decodeNil() {
                self = .null
            } else if let value = try? single.decode(Bool.self) {
                self = .boolean(value)
            } else if let value = try? single.decode(Int64.self) {
                self = .integer(value)
            } else if let value = try? single.decode(UInt64.self) {
                self = .unsignedInteger(value)
            } else if let value = try? single.decode(Double.self) {
                self = .number(value)
            } else if let value = try? single.decode(String.self) {
                self = .string(value)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Unsupported JSON value"
                )
            }
            return
        }

        if var values = try? decoder.unkeyedContainer() {
            var result: [DiagnosticJSONValue] = []
            while !values.isAtEnd {
                result.append(try values.decode(DiagnosticJSONValue.self))
            }
            self = .array(result)
            return
        }

        let values = try decoder.container(keyedBy: DiagnosticJSONKey.self)
        var result: [String: DiagnosticJSONValue] = [:]
        for key in values.allKeys {
            result[key.stringValue] = try values.decode(DiagnosticJSONValue.self, forKey: key)
        }
        self = .object(result)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let values):
            var container = encoder.container(keyedBy: DiagnosticJSONKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: DiagnosticJSONKey(key))
            }
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .unsignedInteger(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .boolean(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    var diagnosticSummary: String {
        switch self {
        case .object(let values):
            let keys = values.keys.sorted().prefix(6).joined(separator: ", ")
            return keys.isEmpty ? "JSON 对象（无字段）" : "JSON 对象字段：\(keys)"
        case .array(let values):
            return "JSON 数组：\(values.count) 项"
        case .string:
            return "JSON 字符串"
        case .integer, .unsignedInteger, .number:
            return "JSON 数值"
        case .boolean:
            return "JSON 布尔值"
        case .null:
            return "JSON 空值"
        }
    }
}

private struct DiagnosticJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) { return nil }
    init(_ stringValue: String) {
        self.stringValue = stringValue
    }
}

final class MetricKitDiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitDiagnosticsSubscriber()

    private let registrationLock = NSLock()
    private var isRegistered = false

    private override init() {
        super.init()
    }

    func start() {
        registrationLock.lock()
        guard !isRegistered else {
            registrationLock.unlock()
            return
        }
        isRegistered = true
        registrationLock.unlock()

        MXMetricManager.shared.add(self)
        DiagnosticLogger.record(
            .info,
            category: .diagnostics,
            event: "metrickit.subscription.started",
            message: "已注册系统诊断报告接收器"
        )
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        DiagnosticLogger.record(
            .notice,
            category: .diagnostics,
            event: "metrickit.diagnostics.received",
            message: "系统投递了应用诊断报告",
            metadata: ["reportCount": String(payloads.count)]
        )
        for payload in payloads {
            DiagnosticLogStore.shared.appendMetricKitReport(payload.jsonRepresentation())
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {}
}

extension DiagnosticMetricKitReport {
    var formattedPayload: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8)
        else { return "无法格式化诊断报告 JSON" }
        return text
    }
}
