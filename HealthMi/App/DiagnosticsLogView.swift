import SwiftUI
import UIKit

@MainActor
struct DiagnosticsLogView: View {
    @State private var snapshot = DiagnosticLogSnapshot(
        events: [], storageBytes: 0, corruptedLineCount: 0
    )
    @State private var searchText = ""
    @State private var selectedLevel: DiagnosticLogLevel?
    @State private var selectedCategory: DiagnosticLogCategory?
    @State private var showWarningsAndErrors = false
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var showClearConfirmation = false
    @State private var shareFile: ShareFile?
    @State private var errorMessage: String?
    @State private var copyMessage: String?

    private let visibleEventLimit = 2_000
    private let copyEventLimit = 10_000
    private static let copyTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var filteredEvents: [DiagnosticLogEvent] {
        snapshot.events.filter { event in
            if let selectedLevel, event.level != selectedLevel { return false }
            if let selectedCategory, event.category != selectedCategory { return false }
            if showWarningsAndErrors && event.level.severity < DiagnosticLogLevel.warning.severity {
                return false
            }
            guard !searchText.isEmpty else { return true }
            let query = searchText.localizedLowercase
            return Self.matchesSearch(event, query: query)
        }
    }

    private static func matchesSearch(_ event: DiagnosticLogEvent, query: String) -> Bool {
        var searchableFields = [
            event.event,
            event.message,
            event.category.displayName,
            event.category.rawValue,
            event.level.displayName,
            event.dataType ?? "",
            event.runID ?? "",
            event.errorDomain ?? "",
            event.errorCode.map { String($0) } ?? "",
            event.processSessionID ?? "",
            event.sequenceNumber.map { String($0) } ?? "",
            event.sourceFile ?? "",
            event.sourceFunction ?? "",
            event.sourceLine.map { String($0) } ?? "",
        ]
        if let errorChain = event.errorChain {
            searchableFields.append(contentsOf: errorChain.map { "\($0.domain)/\($0.code) \($0.message)" })
        }
        searchableFields.append(contentsOf: event.metadata.keys.sorted().map {
            "\($0)=\(event.metadata[$0] ?? "")"
        })
        return searchableFields.joined(separator: " ").localizedLowercase.contains(query)
    }

    private var visibleEvents: [DiagnosticLogEvent] {
        Array(filteredEvents.prefix(visibleEventLimit))
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top) {
                    Label("保留日志", systemImage: "doc.text.magnifyingglass")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(snapshot.events.count) 条事件 · \(snapshot.metricKitReports.count) 份系统报告")
                        Text(Self.byteCountText(snapshot.storageBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let newestEvent = snapshot.newestEvent {
                            Text("最新：\(newestEvent.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let oldestEvent = snapshot.oldestEvent {
                            Text("最早：\(oldestEvent.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if snapshot.corruptedLineCount > 0 {
                    Label(
                        "有 \(snapshot.corruptedLineCount) 条记录无法解析，其他日志仍可查看",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }

                if let copyMessage {
                    Label(copyMessage, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button(action: copyFilteredLogs) {
                    Label(copyButtonTitle, systemImage: "doc.on.doc")
                }
                .disabled(filteredEvents.isEmpty)

                Button(action: exportAndShare) {
                    if isExporting {
                        Label("正在生成诊断文件…", systemImage: "hourglass")
                    } else {
                        Label("导出 JSON 诊断文件并分享", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting)

                Button("清空本地诊断日志", role: .destructive) {
                    showClearConfirmation = true
                }
            } footer: {
                Text("复制会生成可粘贴的脱敏事件文本；文件导出包含事件、系统诊断报告和最近同步摘要。日志和报告自动保存在本机，不会自动上传；只有主动导出/分享时才会离开应用。总容量最多 20 MiB，保留 14 天。")
            }

            Section("存储健康（本进程启动以来）") {
                LabeledContent("事件写入失败", value: "\(snapshot.storageHealth.eventWriteFailureCount) 次")
                LabeledContent("系统报告写入失败", value: "\(snapshot.storageHealth.metricKitWriteFailureCount) 次")
                LabeledContent("清理维护失败", value: "\(snapshot.storageHealth.maintenanceFailureCount) 次")
                LabeledContent("日志文件轮转", value: "\(snapshot.storageHealth.rotatedFileCount) 次")
                LabeledContent(
                    "清理旧文件",
                    value: "\(snapshot.storageHealth.prunedFileCount) 个 / \(Self.byteCountText(snapshot.storageHealth.prunedByteCount))"
                )
                if let domain = snapshot.storageHealth.lastErrorDomain {
                    LabeledContent("最近存储错误") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(domain)/\(snapshot.storageHealth.lastErrorCode ?? 0)")
                            if let message = snapshot.storageHealth.lastErrorMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                } else {
                    LabeledContent("最近存储错误", value: "无")
                }
                LabeledContent("无法解析的记录", value: "\(snapshot.corruptedLineCount) 条")
            }

            Section("筛选") {
                Picker("级别", selection: $selectedLevel) {
                    Text("全部级别").tag(nil as DiagnosticLogLevel?)
                    ForEach(DiagnosticLogLevel.allCases) { level in
                        Text(level.displayName).tag(Optional(level))
                    }
                }

                Picker("分类", selection: $selectedCategory) {
                    Text("全部分类").tag(nil as DiagnosticLogCategory?)
                    ForEach(DiagnosticLogCategory.allCases) { category in
                        Text(category.displayName).tag(Optional(category))
                    }
                }

                Toggle("仅显示警告及错误", isOn: $showWarningsAndErrors)
            }

            Section("系统诊断报告（MetricKit）") {
                if snapshot.metricKitReports.isEmpty {
                    Text("当前没有系统诊断报告。iOS 仅在生成并投递报告时提供数据；没有报告不代表没有异常。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.metricKitReports) { report in
                        NavigationLink {
                            MetricKitDiagnosticDetailView(report: report)
                        } label: {
                            MetricKitDiagnosticRow(report: report)
                        }
                    }
                }
            }

            Section("日志（最新在前）") {
                if isLoading && snapshot.events.isEmpty {
                    HStack {
                        ProgressView()
                        Text("正在读取日志…")
                            .foregroundStyle(.secondary)
                    }
                } else if visibleEvents.isEmpty {
                    Text(searchText.isEmpty ? "暂无匹配日志" : "没有符合搜索条件的日志")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleEvents) { event in
                        NavigationLink {
                            DiagnosticLogDetailView(event: event)
                        } label: {
                            DiagnosticLogRow(event: event)
                        }
                    }

                    if filteredEvents.count > visibleEventLimit {
                        Text("列表显示最近 \(visibleEventLimit) 条匹配结果；复制最多包含最近 \(copyEventLimit) 条，JSON 导出包含全部保留日志。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索事件、错误、会话 ID、源码位置")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新日志")
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog(
            "清空本机诊断日志？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空日志", role: .destructive, action: clearLogs)
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会删除本机事件日志和 MetricKit 报告，不会清除同步历史、同步游标或压力数据。")
        }
        .alert(
            "无法完成操作",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .sheet(item: $shareFile) { file in
            DiagnosticActivitySheet(fileURL: file.url)
        }
    }

    private var copyButtonTitle: String {
        let count = min(filteredEvents.count, copyEventLimit)
        return "复制筛选日志文本（\(count) 条）"
    }

    private func reload() async {
        isLoading = true
        do {
            let loaded = try await Task.detached(priority: .utility) {
                try DiagnosticLogStore.shared.snapshot()
            }.value
            snapshot = loaded
            errorMessage = nil
        } catch {
            errorMessage = "读取诊断日志失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func copyFilteredLogs() {
        let events = Array(filteredEvents.prefix(copyEventLimit))
        UIPasteboard.general.string = events.map(Self.textLine(for:)).joined(separator: "\n")
        copyMessage = "已复制 \(events.count) 条脱敏日志"
        DiagnosticLogger.record(
            .info,
            category: .export,
            event: "diagnostics.copy.completed",
            message: "已复制筛选后的诊断日志文本",
            metadata: ["eventCount": String(events.count)]
        )
        Task { await reload() }
    }

    private func exportAndShare() {
        guard !isExporting else { return }
        isExporting = true
        DiagnosticLogger.record(
            .info,
            category: .export,
            event: "diagnostics.export.started",
            message: "开始生成 JSON 诊断文件"
        )

        Task {
            do {
                let syncRuns = try SyncRunStore.allThrowing()
                let deviceModel = UIDevice.current.model
                let systemVersion = UIDevice.current.systemVersion
                let result = try await Task.detached(priority: .utility) {
                    try DiagnosticLogExporter.writeBundle(
                        syncRuns: syncRuns,
                        deviceModel: deviceModel,
                        systemVersion: systemVersion
                    )
                }.value
                DiagnosticLogger.record(
                    .info,
                    category: .export,
                    event: "diagnostics.export.completed",
                    message: "JSON 诊断文件已生成",
                    metadata: [
                        "eventCount": String(result.eventCount),
                        "metricKitReportCount": String(result.reportCount),
                        "byteCount": String(result.byteCount),
                    ]
                )
                shareFile = ShareFile(url: result.url)
                await reload()
            } catch {
                DiagnosticLogger.record(
                    .error,
                    category: .export,
                    event: "diagnostics.export.failed",
                    message: "生成 JSON 诊断文件失败",
                    error: error
                )
                errorMessage = "导出诊断文件失败：\(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    private func clearLogs() {
        do {
            try DiagnosticLogStore.shared.clear()
            DiagnosticLogger.record(
                .notice,
                category: .export,
                event: "diagnostics.logs.cleared",
                message: "用户清空了本地诊断日志"
            )
            copyMessage = nil
            Task { await reload() }
        } catch {
            DiagnosticLogger.record(
                .error,
                category: .storage,
                event: "diagnostics.logs.clear.failed",
                message: "清空诊断日志失败",
                error: error
            )
            errorMessage = "清空诊断日志失败：\(error.localizedDescription)"
        }
    }

    private static func textLine(for event: DiagnosticLogEvent) -> String {
        let timestamp = copyTimestampFormatter.string(from: event.timestamp)
        let run = event.runID ?? "-"
        let sequence = event.sequenceNumber.map { String($0) } ?? "-"
        let session = event.processSessionID ?? "-"
        var line = "[\(timestamp)] [\(event.level.rawValue.uppercased())] [\(event.category.displayName)] \(event.event) pid=\(event.processID) main=\(event.isMainThread ? "yes" : "no") session=\(session) seq=\(sequence) run=\(run)"
        if let dataType = event.dataType { line += " type=\(dataType)" }
        if let sourceFile = event.sourceFile, let sourceLine = event.sourceLine {
            line += " source=\(sourceFile):\(sourceLine)"
            if let sourceFunction = event.sourceFunction { line += " function=\(sourceFunction)" }
        }
        line += " — \(event.message)"
        if let errorDomain = event.errorDomain {
            line += " error=\(errorDomain)/\(event.errorCode ?? 0)"
        }
        if let errorChain = event.errorChain, !errorChain.isEmpty {
            let chain = errorChain.map { "\($0.domain)/\($0.code): \($0.message)" }
            line += " underlying=[\(chain.joined(separator: " <- "))]"
        }
        if !event.metadata.isEmpty {
            let metadata = event.metadata.keys.sorted().map { "\($0)=\(event.metadata[$0] ?? "")" }
            line += " {\(metadata.joined(separator: ", "))}"
        }
        return line
    }

    private static func byteCountText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct DiagnosticLogRow: View {
    let event: DiagnosticLogEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(event.level.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(levelColor)
                Text(event.category.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(event.event)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(event.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
    }

    private var levelColor: Color {
        switch event.level {
        case .trace, .debug: return .secondary
        case .info, .notice: return .blue
        case .warning: return .orange
        case .error, .critical: return .red
        }
    }
}

private struct DiagnosticLogDetailView: View {
    let event: DiagnosticLogEvent

    var body: some View {
        List {
            Section("事件") {
                LabeledContent("时间", value: event.timestamp.formatted(date: .complete, time: .standard))
                LabeledContent("级别", value: event.level.displayName)
                LabeledContent("分类", value: event.category.displayName)
                LabeledContent("事件名", value: event.event)
                LabeledContent("进程 ID", value: String(event.processID))
                LabeledContent("主线程", value: event.isMainThread ? "是" : "否")
                if let processSessionID = event.processSessionID {
                    LabeledContent("进程会话 ID", value: processSessionID)
                }
                if let sequenceNumber = event.sequenceNumber {
                    LabeledContent("进程内序号", value: String(sequenceNumber))
                }
                if let sourceFile = event.sourceFile {
                    LabeledContent("源文件", value: sourceFile)
                }
                if let sourceFunction = event.sourceFunction {
                    LabeledContent("函数", value: sourceFunction)
                }
                if let sourceLine = event.sourceLine {
                    LabeledContent("行号", value: String(sourceLine))
                }
                if let runID = event.runID {
                    LabeledContent("运行 ID", value: runID)
                }
                if let dataType = event.dataType {
                    LabeledContent("同步类别", value: dataType)
                }
            }

            Section("说明") {
                Text(event.message)
                    .textSelection(.enabled)
            }

            if let errorDomain = event.errorDomain {
                Section("错误") {
                    LabeledContent("错误域", value: errorDomain)
                    LabeledContent("错误码", value: String(event.errorCode ?? 0))
                    if let errorChain = event.errorChain {
                        ForEach(Array(errorChain.enumerated()), id: \.offset) { index, item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(index == 0 ? "原始错误" : "底层错误 \(index)")
                                    .font(.caption.weight(.semibold))
                                Text("\(item.domain)/\(item.code): \(item.message)")
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            if !event.metadata.isEmpty {
                Section("安全元数据") {
                    ForEach(event.metadata.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: event.metadata[key] ?? "")
                    }
                }
            }
        }
        .navigationTitle("日志详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MetricKitDiagnosticRow: View {
    let report: DiagnosticMetricKitReport

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(report.reportType)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Text(report.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(report.summary)
                .font(.subheadline)
                .lineLimit(2)
            Text(ByteCountFormatter.string(fromByteCount: Int64(report.byteCount), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

@MainActor
private struct MetricKitDiagnosticDetailView: View {
    let report: DiagnosticMetricKitReport
    @State private var copyMessage: String?
    @State private var formattedPayload = ""
    @State private var isFormatting = true

    var body: some View {
        List {
            Section("报告") {
                LabeledContent("类型", value: report.reportType)
                LabeledContent("接收时间", value: report.receivedAt.formatted(date: .complete, time: .standard))
                LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(report.byteCount), countStyle: .file))
                LabeledContent("报告 ID", value: String(report.id.prefix(16)))
                Text("报告已在保存前执行敏感字段过滤。系统控制报告是否生成和投递；列表为空不能证明没有发生异常。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let copyMessage {
                Section {
                    Label(copyMessage, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("脱敏 JSON") {
                if isFormatting {
                    HStack {
                        ProgressView()
                        Text("正在准备报告内容…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(formattedPayload)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("系统诊断报告")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = formattedPayload
                    copyMessage = "已复制脱敏 MetricKit 报告"
                    DiagnosticLogger.record(
                        .info,
                        category: .export,
                        event: "diagnostics.metrickit.copy.completed",
                        message: "已复制单份脱敏 MetricKit 诊断报告",
                        metadata: ["reportID": String(report.id.prefix(16))]
                    )
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(isFormatting)
                .accessibilityLabel("复制系统诊断报告 JSON")
            }
        }
        .task(id: report.id) {
            isFormatting = true
            formattedPayload = await Task.detached(priority: .utility) {
                report.formattedPayload
            }.value
            isFormatting = false
        }
    }
}

private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct DiagnosticActivitySheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(
                x: controller.view.bounds.midX,
                y: controller.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        controller.completionWithItemsHandler = { _, completed, _, error in
            let level: DiagnosticLogLevel
            if error != nil {
                level = .error
            } else {
                level = completed ? .info : .notice
            }
            DiagnosticLogger.record(
                level,
                category: .export,
                event: "diagnostics.share.finished",
                message: error == nil
                    ? (completed ? "系统分享流程已完成" : "系统分享流程已关闭")
                    : "系统分享流程返回错误",
                error: error,
                metadata: ["completed": String(completed)]
            )
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
