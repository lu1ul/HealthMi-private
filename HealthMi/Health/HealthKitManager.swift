import HealthKit
import Foundation

/// HealthKit 授权与类型清单。
enum HealthKitManager {
    static let healthStore = HKHealthStore()

    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// 需要写入（并读取用于去重）的健康数据类型。
    static let typesToShare: Set<HKSampleType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.heartRate),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.oxygenSaturation),
        HKQuantityType(.respiratoryRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.bodyMass),
        HKQuantityType(.bodyMassIndex),
        HKQuantityType(.leanBodyMass),
        HKQuantityType(.basalEnergyBurned),
        HKQuantityType(.bodyFatPercentage),
        HKCategoryType(.sleepAnalysis),
        HKObjectType.workoutType(),
    ]

    static let typesToRead: Set<HKObjectType> = typesToShare

    /// 请求读写授权（系统会展示授权弹窗）。
    static func requestAuthorization() async throws {
        DiagnosticLogger.record(
            .info,
            category: .healthKit,
            event: "healthkit.authorization.system_request.started",
            message: "调用 HealthKit 授权请求 API",
            metadata: [
                "shareTypeCount": String(typesToShare.count),
                "readTypeCount": String(typesToRead.count),
                "shareTypeIdentifiers": typesToShare.map(\.identifier).sorted().joined(separator: ","),
                "readTypeIdentifiers": typesToRead.map(\.identifier).sorted().joined(separator: ","),
                "healthDataAvailable": String(isAvailable),
            ]
        )
        do {
            try await healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead)
            DiagnosticLogger.record(
                .info,
                category: .healthKit,
                event: "healthkit.authorization.system_request.returned",
                message: "HealthKit 授权请求 API 已返回"
            )
        } catch {
            DiagnosticLogger.record(
                .error,
                category: .healthKit,
                event: "healthkit.authorization.system_request.failed",
                message: "HealthKit 授权请求 API 抛出错误",
                error: error
            )
            throw error
        }
    }
}
