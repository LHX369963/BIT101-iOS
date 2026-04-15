import SwiftUI
import WidgetKit

/// 手表侧还没有收到任何镜像时的提示文案。
private let watchScheduleWidgetCampusNetworkMessage = "打开手机 App 同步课表"
/// 用户尚未在手机侧登录时的提示文案。
private let watchScheduleWidgetLoginMessage = "请先登录"
/// 当前与后续都没有课程时的提示文案。
private let watchScheduleWidgetRestMessage = "今天没课啦"

/// Smart Stack 卡片使用的时间线条目。
private struct WatchScheduleEntry: TimelineEntry {
    let date: Date
    let nextOccurrence: ScheduleExternalOccurrence?
    let message: String?
}

/// 负责把共享快照转换成 watch widget 时间线。
private struct WatchScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchScheduleEntry {
        WatchScheduleEntry(
            date: Date(),
            nextOccurrence: ScheduleExternalOccurrence(
                id: "preview",
                title: "高等数学",
                classroom: "理教201",
                teacher: "张老师",
                startDate: Date().addingTimeInterval(20 * 60),
                endDate: Date().addingTimeInterval(110 * 60),
                displayUntilDate: Date().addingTimeInterval(110 * 60)
            ),
            message: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchScheduleEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchScheduleEntry>) -> Void) {
        let entry = loadEntry()
        let refreshDate = nextRefreshDate(for: entry)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }

    /// 从本地共享快照生成当前条目。
    ///
    /// 这里不主动请求 iPhone；WidgetKit 只消费 watch 本地已落地的数据。
    private func loadEntry() -> WatchScheduleEntry {
        let resolved = ScheduleOccurrenceResolver.loadResolvedSnapshot(limit: 1)

        guard let snapshot = resolved.snapshot else {
            return WatchScheduleEntry(date: Date(), nextOccurrence: nil, message: watchScheduleWidgetCampusNetworkMessage)
        }

        guard snapshot.isLoggedIn else {
            return WatchScheduleEntry(date: Date(), nextOccurrence: nil, message: watchScheduleWidgetLoginMessage)
        }

        let occurrence = resolved.nextOccurrence
        return WatchScheduleEntry(
            date: Date(),
            nextOccurrence: occurrence,
            message: occurrence == nil ? watchScheduleWidgetRestMessage : nil
        )
    }

    /// 计算下一次时间线刷新时机。
    ///
    /// 优先卡在“上课开始”或“本节展示截止”这两个边界点附近，
    /// 这样卡片能在课程状态切换时尽快刷新。
    private func nextRefreshDate(for entry: WatchScheduleEntry) -> Date {
        let now = Date()
        let candidates = [entry.nextOccurrence?.startDate, entry.nextOccurrence?.displayUntilDate]
            .compactMap { $0 }
            .filter { $0 > now.addingTimeInterval(30) }
            .sorted()

        if let next = candidates.first {
            return next
        }

        return Calendar.current.date(byAdding: .minute, value: 30, to: now) ?? now.addingTimeInterval(1800)
    }
}

/// 提供给 Smart Stack 的课表卡片。
struct BIT101WatchScheduleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BIT101WatchScheduleWidget", provider: WatchScheduleProvider()) { entry in
            WatchScheduleEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("课表")
        .description("在 Smart Stack 里查看当前课或下一节课。")
        .supportedFamilies([.accessoryRectangular])
    }
}

/// Smart Stack 卡片的具体渲染视图。
private struct WatchScheduleEntryView: View {
    let entry: WatchScheduleEntry

    var body: some View {
        VStack(alignment: .leading) {
            if let next = entry.nextOccurrence {
                HStack(alignment: .firstTextBaseline) {
                    Text(next.isCurrent() ? "正在上课" : "下一节")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Text(next.relativeDayText())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading) {
                    Text(next.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    HStack(alignment: .firstTextBaseline) {
                        Text(next.rangeText)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Spacer(minLength: 4)

                        if !next.classroom.isEmpty {
                            Text(next.classroom)
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading) {
                    Text(entry.message ?? watchScheduleWidgetRestMessage)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.message == watchScheduleWidgetCampusNetworkMessage {
                        Text("先打开手机 App。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
