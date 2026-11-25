import HealthKit
import Foundation

/// 幂等写入器，复刻 `healthloom.app` 的 `HealthKitWriter` 模式：
/// - 每个样本带 `HKMetadataKeyExternalUUID`；
/// - 写入前按「类型 + 时间段」一次查询已有的 externalID，内存里 diff 后只保存新增批次；
/// - 更新 = 按 externalID 删除 + 重插（HK 样本不可变）。
actor HealthWriter {
    private let store: HKHealthStore

    init(store: HKHealthStore = HealthKitManager.healthStore) {
        self.store = store
    }

    /// 该类型在 `[start, end]` 内已写入的 externalID 集合。
    /// 使用软边界（不限制 strictStart/strictEnd），确保跨越窗口起点的睡眠会话不会被漏掉。
    func existingExternalIDs(ofType type: HKSampleType, start: Date, end: Date) async throws -> Set<String> {
        let startedAt = Date()
        DiagnosticLogger.record(
            .debug,
            category: .healthKit,
            event: "healthkit.dedup.query.started",
            message: "开始查询 HealthKit 中已有的去重标识",
            metadata: ["sampleType": type.identifier]
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID),
        ])
        var ids = Set<String>()
        var anchor: Date? = nil
        var pageIndex = 0
        while true {
            pageIndex += 1
            let samples: [HKSample]
            do {
                samples = try await queryPage(type: type, predicate: predicate, anchor: anchor)
            } catch {
                DiagnosticLogger.record(
                    .error,
                    category: .healthKit,
                    event: "healthkit.dedup.query.failed",
                    message: "查询 HealthKit 去重标识失败",
                    error: error,
                    metadata: ["sampleType": type.identifier, "pageIndex": String(pageIndex)]
                )
                throw error
            }
            DiagnosticLogger.record(
                .debug,
                category: .healthKit,
                event: "healthkit.dedup.page.completed",
                message: "HealthKit 去重查询页面完成",
                metadata: [
                    "sampleType": type.identifier,
                    "pageIndex": String(pageIndex),
                    "sampleCount": String(samples.count),
                ]
            )
            guard !samples.isEmpty else { break }
            for sample in samples {
                if let uuid = sample.metadata?[HKMetadataKeyExternalUUID] as? String {
                    ids.insert(uuid)
                }
                if let last = samples.last, last.startDate > (anchor ?? .distantPast) {
                    anchor = last.startDate
                }
            }
            if samples.count < Self.pageSize { break }
        }
        DiagnosticLogger.record(
            .info,
            category: .healthKit,
            event: "healthkit.dedup.query.completed",
            message: "HealthKit 去重查询完成",
            metadata: [
                "sampleType": type.identifier,
                "existingIDCount": String(ids.count),
                "pageCount": String(pageIndex),
                "durationMs": Self.durationMilliseconds(since: startedAt),
            ]
        )
        return ids
    }

    /// 一次性批量保存（空批次直接跳过）。
    func save(_ batch: [HKObject]) async throws {
        guard !batch.isEmpty else { return }
        let sampleTypes = Set(batch.compactMap { ($0 as? HKSample)?.sampleType.identifier }).sorted()
        DiagnosticLogger.record(
            .info,
            category: .healthKit,
            event: "healthkit.samples.save.started",
            message: "开始向 HealthKit 保存样本批次",
            metadata: [
                "objectCount": String(batch.count),
                "sampleTypes": sampleTypes.joined(separator: ","),
            ]
        )
        let startedAt = Date()
        do {
            try await store.save(batch)
            DiagnosticLogger.record(
                .info,
                category: .healthKit,
                event: "healthkit.samples.save.completed",
                message: "HealthKit 样本批次保存成功",
                metadata: [
                    "objectCount": String(batch.count),
                    "durationMs": Self.durationMilliseconds(since: startedAt),
                ]
            )
        } catch {
            DiagnosticLogger.record(
                .error,
                category: .healthKit,
                event: "healthkit.samples.save.failed",
                message: "HealthKit 样本批次保存失败",
                error: error,
                metadata: ["objectCount": String(batch.count)]
            )
            throw error
        }
    }

    /// 用 `HKWorkoutBuilder` 构建并保存一条运动记录。
    /// 保留 externalUUID metadata（builder 支持 addMetadata），继续用于去重。
    /// 若草稿包含心率数据，创建关联心率样本并挂载到运动记录上。
    func saveWorkout(_ draft: TypeMapper.WorkoutDraft) async throws -> HKWorkout {
        let startedAt = Date()
        DiagnosticLogger.record(
            .info,
            category: .healthKit,
            event: "healthkit.workout.save.started",
            message: "开始构建并保存 HealthKit 运动记录"
        )
        let config = HKWorkoutConfiguration()
        config.activityType = draft.activityType
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
        do {
            try await builder.beginCollection(at: draft.start)
            try await builder.addMetadata([HKMetadataKeyExternalUUID: draft.externalUUID])
            try await builder.endCollection(at: draft.end)
            guard let workout = try await builder.finishWorkout() else {
                throw HealthWriterError.workoutBuildFailed
            }

            // 关联心率样本（平均/最大），用 externalUUID 前缀确保去重
            var hrSamples: [HKQuantitySample] = []
            let hrType = HKQuantityType(.heartRate)
            let hrUnit = HKUnit.count().unitDivided(by: .minute())
            if let avg = draft.avgHeartRateBpm, avg > 0 {
                hrSamples.append(HKQuantitySample(
                    type: hrType,
                    quantity: HKQuantity(unit: hrUnit, doubleValue: Double(avg)),
                    start: draft.start, end: draft.end,
                    metadata: [HKMetadataKeyExternalUUID: "\(draft.externalUUID)_avg_hr"]
                ))
            }
            if let max = draft.maxHeartRateBpm, max > 0 {
                hrSamples.append(HKQuantitySample(
                    type: hrType,
                    quantity: HKQuantity(unit: hrUnit, doubleValue: Double(max)),
                    start: draft.start, end: draft.end,
                    metadata: [HKMetadataKeyExternalUUID: "\(draft.externalUUID)_max_hr"]
                ))
            }
            if !hrSamples.isEmpty {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    store.add(hrSamples, to: workout) { success, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if !success {
                            continuation.resume(throwing: HealthWriterError.workoutBuildFailed)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }

            DiagnosticLogger.record(
                .info,
                category: .healthKit,
                event: "healthkit.workout.save.completed",
                message: "HealthKit 运动记录保存成功",
                metadata: [
                    "associatedHeartRateCount": String(hrSamples.count),
                    "durationMs": Self.durationMilliseconds(since: startedAt),
                ]
            )
            return workout
        } catch {
            builder.discardWorkout()
            DiagnosticLogger.record(
                .error,
                category: .healthKit,
                event: "healthkit.workout.save.failed",
                message: "构建或保存 HealthKit 运动记录失败",
                error: error,
                metadata: ["durationMs": Self.durationMilliseconds(since: startedAt)]
            )
            throw error
        }
    }

    enum HealthWriterError: LocalizedError {
        case workoutBuildFailed
        var errorDescription: String? { "运动记录构建失败" }
    }

    /// 按 externalID 删除指定类型的对象，返回删除数量。
    @discardableResult
    func delete(ofType type: HKObjectType, externalIDs: Set<String>) async throws -> Int {
        guard !externalIDs.isEmpty else { return 0 }
        DiagnosticLogger.record(
            .notice,
            category: .healthKit,
            event: "healthkit.samples.delete.started",
            message: "开始按应用外部标识删除 HealthKit 样本",
            metadata: ["sampleType": type.identifier, "externalIDCount": String(externalIDs.count)]
        )
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID,
            allowedValues: Array(externalIDs)
        )
        do {
            let count = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                store.deleteObjects(of: type, predicate: predicate) { _, count, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: count)
                    }
                }
            }
            DiagnosticLogger.record(
                .notice,
                category: .healthKit,
                event: "healthkit.samples.delete.completed",
                message: "HealthKit 样本删除操作已返回",
                metadata: ["sampleType": type.identifier, "deletedCount": String(count)]
            )
            return count
        } catch {
            DiagnosticLogger.record(
                .error,
                category: .healthKit,
                event: "healthkit.samples.delete.failed",
                message: "删除 HealthKit 样本失败",
                error: error,
                metadata: ["sampleType": type.identifier]
            )
            throw error
        }
    }

    // MARK: - 分页查询

    private static let pageSize = 1000

    private static func durationMilliseconds(since start: Date) -> String {
        String(max(0, Int(Date().timeIntervalSince(start) * 1_000)))
    }

    private func queryPage(
        type: HKSampleType, predicate: NSPredicate, anchor: Date?
    ) async throws -> [HKSample] {
        let typeIdentifier = type.identifier
        var combined = predicate
        if let anchor {
            combined = NSCompoundPredicate(andPredicateWithSubpredicates: [
                predicate,
                HKQuery.predicateForSamples(withStart: anchor, end: nil),
            ])
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: type, predicate: combined,
                limit: Self.pageSize, sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    DiagnosticLogger.record(
                        .error,
                        category: .healthKit,
                        event: "healthkit.query.page.failed",
                        message: "HealthKit 样本分页查询失败",
                        error: error,
                        metadata: ["sampleType": typeIdentifier]
                    )
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }
}
