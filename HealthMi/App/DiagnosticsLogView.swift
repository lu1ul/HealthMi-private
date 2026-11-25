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
            let searchable = [
                event.event,
                event.message,
                event.category.displayName,
                event.category.rawValue,
                event.level.displayName,
                event.dataType ?? "",
                event.runID ?? "",
                event.errorDomain ?? "",
                event.errorCode.map { String($0) } ?? "",
                event.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
            ].joined(separator: " ").localizedLowercase
            return searchable.contains(query)
        }
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
                        Text("\(snapshot.events.count) 条")
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
                Text("复制会生成可粘贴的脱敏文本；文件导出包含全部保留日志和最近同步摘要。日志保存在本机，最多 20 MiB，保留 14 天。")
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
        .searchable(text: $searchText, prompt: "搜索事件、错误、运行 ID")
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
            Text("此操作只删除诊断日志，不会清除同步历史、同步游标或压力数据。")
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
        let run = event.runID.map { String($0.prefix(8)) } ?? "-"
        var line = "[\(timestamp)] [\(event.level.rawValue.uppercased())] [\(event.category.displayName)] \(event.event) run=\(run)"
        if let dataType = event.dataType { line += " type=\(dataType)" }
        line += " — \(event.message)"
        if let errorDomain = event.errorDomain {
            line += " error=\(errorDomain)/\(event.errorCode ?? 0)"
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
