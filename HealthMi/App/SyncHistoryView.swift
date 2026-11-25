import CoreData
import SwiftUI

/// 同步历史日志页面。
@MainActor
struct SyncHistoryView: View {
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "timestamp", ascending: false)])
    private var entries: FetchedResults<SyncLogEntryEntity>
    @State private var latestRun: SyncRunRecord?

    var body: some View {
        List {
            if let latestRun {
                Section("最近一次后台运行") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(latestRun.dialogText)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("运行 ID：\(latestRun.id.uuidString)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无同步记录")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(entries, id: \.objectID) { entry in
                    logRow(entry)
                }
            }
        }
        .navigationTitle("同步历史")
        .onAppear {
            latestRun = SyncRunStore.latest()
        }
    }

    private func logRow(_ entry: SyncLogEntryEntity) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.displayName)
                        .font(.subheadline)
                    if entry.success {
                        Text("+\(entry.added)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                if let error = entry.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("拉取 \(entry.fetched)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct SyncHistoryView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SyncHistoryView()
                .environment(\.managedObjectContext, CoreDataSchema.makePreviewContainer().viewContext)
        }
    }
}
