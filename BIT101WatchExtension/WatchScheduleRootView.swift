import SwiftUI

@MainActor
final class WatchScheduleStatusModel: ObservableObject {
    private static let maxVisibleOccurrences = 50

    @Published private(set) var snapshot: ScheduleExternalSnapshot?
    @Published private(set) var nextOccurrence: ScheduleExternalOccurrence?
    @Published private(set) var upcomingOccurrences: [ScheduleExternalOccurrence] = []

    func activate() {
        WatchScheduleSyncManager.shared.activateIfNeeded()
        #if os(watchOS)
        WatchScheduleSyncManager.shared.requestLatestSnapshotFromPhone()
        #endif
        reload()
    }

    func reload() {
        let snapshot = ScheduleExternalSnapshotStore.load()
        self.snapshot = snapshot
        let occurrences = snapshot
            .map { ScheduleOccurrenceResolver.upcomingOccurrences(from: $0) }
            ?? []
        self.nextOccurrence = occurrences.first
        self.upcomingOccurrences = Array(occurrences.prefix(Self.maxVisibleOccurrences))
    }

    func requestRefresh() {
        #if os(watchOS)
        WatchScheduleSyncManager.shared.requestLatestSnapshotFromPhone()
        #endif
        reload()
    }
}

struct WatchScheduleRootView: View {
    @ObservedObject var model: WatchScheduleStatusModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading) {
                if let snapshot = model.snapshot, snapshot.isLoggedIn, let next = model.nextOccurrence {
                    VStack(alignment: .leading) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(next.isCurrent() ? "正在上课" : "下一节")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 0)

                            Text(next.relativeDayText())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(next.title)
                            .font(.title)
                            .lineLimit(2)

                        Text(next.rangeText)
                            .font(.title)

                        if !next.classroom.isEmpty {
                            Text(next.classroom)
                                .font(.title)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if model.upcomingOccurrences.count > 1 {
                        Divider()
                            .padding(.vertical, 2)

                        Text("后续课节")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(Array(model.upcomingOccurrences.dropFirst())) { occurrence in
                            VStack(alignment: .leading) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(occurrence.relativeDayText())
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)

                                    Spacer(minLength: 4)

                                    Text(occurrence.rangeText)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }

                                Text(occurrence.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)

                                if !occurrence.classroom.isEmpty {
                                    Text(occurrence.classroom)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else if let snapshot = model.snapshot, !snapshot.isLoggedIn {
                    Text("请先在手机上登录")
                        .font(.headline)
                } else {
                    Text("打开手机 App 同步课表")
                        .font(.headline)
                }

                Button("重新同步") {
                    model.requestRefresh()
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("课表")
        .onAppear {
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scheduleExternalSnapshotDidChange)) { _ in
            model.reload()
        }
    }
}
