import SwiftUI

/// watch 主页面使用的状态模型。
///
/// 它只关心三件事：
/// - 从共享快照仓库读取当前镜像
/// - 计算下一节课与后续课节
/// - 在需要时向 iPhone 发起一次显式刷新
@MainActor
final class WatchScheduleStatusModel: ObservableObject {
    /// 主页面最多展示的后续课节数量，避免长列表在手表上无限拉长。
    private static let maxVisibleOccurrences = 50

    @Published private(set) var snapshot: ScheduleExternalSnapshot?
    @Published private(set) var nextOccurrence: ScheduleExternalOccurrence?
    @Published private(set) var upcomingOccurrences: [ScheduleExternalOccurrence] = []

    /// 激活同步链路，并尝试立刻拿到最新课表。
    func activate() {
        WatchScheduleSyncManager.shared.activateIfNeeded()
        #if os(watchOS)
        WatchScheduleSyncManager.shared.requestLatestSnapshotFromPhone()
        #endif
        reload()
    }

    /// 仅从本地镜像重载当前页面。
    ///
    /// 这个方法不会主动访问网络；它只消费 iPhone 已经推送过来的共享快照。
    func reload() {
        let resolved = ScheduleOccurrenceResolver.loadResolvedSnapshot(limit: Self.maxVisibleOccurrences)
        self.snapshot = resolved.snapshot
        self.nextOccurrence = resolved.nextOccurrence
        self.upcomingOccurrences = resolved.upcomingOccurrences
    }

    /// 显式请求手机端重新推送一次最新课表。
    func requestRefresh() {
        #if os(watchOS)
        WatchScheduleSyncManager.shared.requestLatestSnapshotFromPhone()
        #endif
        reload()
    }
}

/// watch 主页面。
///
/// 展示顺序保持极简：先给出“当前/下一节”的摘要，再向下列出后续课节，
/// 让用户抬腕后能先看到最关键的信息，继续滚动时再看完整一些的安排。
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
                            .font(.title2)
                            .lineLimit(2)

                        Text(next.rangeText)
                            .font(.title2)

                        if !next.classroom.isEmpty {
                            Text(next.classroom)
                                .font(.title2)
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
