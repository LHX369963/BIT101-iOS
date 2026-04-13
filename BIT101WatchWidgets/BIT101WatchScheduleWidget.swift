import SwiftUI
import WidgetKit

private let watchScheduleWidgetCampusNetworkMessage = "打开手机 App 同步课表"
private let watchScheduleWidgetLoginMessage = "请先登录"
private let watchScheduleWidgetRestMessage = "今天没课啦"

private struct WatchScheduleEntry: TimelineEntry {
    let date: Date
    let nextOccurrence: ScheduleExternalOccurrence?
    let message: String?
}

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

    private func loadEntry() -> WatchScheduleEntry {
        guard let snapshot = ScheduleExternalSnapshotStore.load() else {
            return WatchScheduleEntry(date: Date(), nextOccurrence: nil, message: watchScheduleWidgetCampusNetworkMessage)
        }

        guard snapshot.isLoggedIn else {
            return WatchScheduleEntry(date: Date(), nextOccurrence: nil, message: watchScheduleWidgetLoginMessage)
        }

        let occurrence = ScheduleOccurrenceResolver.upcomingOccurrences(from: snapshot).first
        return WatchScheduleEntry(
            date: Date(),
            nextOccurrence: occurrence,
            message: occurrence == nil ? watchScheduleWidgetRestMessage : nil
        )
    }

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
