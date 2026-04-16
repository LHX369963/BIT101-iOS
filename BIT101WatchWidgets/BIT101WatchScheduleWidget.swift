import SwiftUI
import WidgetKit

/// 手表侧还没有收到任何镜像时的提示文案。
private let watchScheduleWidgetCampusNetworkMessage = "打开手机 App 同步课表"
/// 用户尚未在手机侧登录时的提示文案。
private let watchScheduleWidgetLoginMessage = "请先登录"
/// 当前没有任何下一节课时的提示文案。
private let watchScheduleWidgetRestMessage = "今天没课啦"

/// 手表 complication 使用的时间线条目。
private struct WatchScheduleEntry: TimelineEntry {
    let date: Date
    let nextOccurrence: ScheduleExternalOccurrence?
    let message: String?
}

/// complication 视图统一消费的展示摘要。
private struct WatchScheduleDisplaySummary {
    let location: ScheduleCompactLocation
    let startTimeText: String
    let rangeText: String
    let dateText: String
    let courseTitle: String
    let inlineText: String

    init(occurrence: ScheduleExternalOccurrence) {
        let rawLocation = occurrence.classroom.isEmpty ? occurrence.title : occurrence.classroom
        let compactLocation = ScheduleDisplayNormalizer.compactLocation(for: rawLocation)
        let courseTitle = occurrence.classroom.isEmpty ? "" : occurrence.title
        let startTimeText = ScheduleSharedDateCodec.formatTime(occurrence.startDate)
        let dateText = occurrence.relativeDayText()

        self.location = compactLocation
        self.startTimeText = startTimeText
        self.rangeText = occurrence.rangeText
        self.dateText = dateText
        self.courseTitle = courseTitle

        var inlineParts = [compactLocation.lightText, startTimeText, dateText]
        if !courseTitle.isEmpty {
            inlineParts.append(courseTitle)
        }
        self.inlineText = inlineParts
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

private extension WatchScheduleEntry {
    var displaySummary: WatchScheduleDisplaySummary? {
        guard let nextOccurrence else { return nil }
        return WatchScheduleDisplaySummary(occurrence: nextOccurrence)
    }

    var circularStatusText: String {
        switch message {
        case watchScheduleWidgetCampusNetworkMessage:
            return "同步"
        case watchScheduleWidgetLoginMessage:
            return "登录"
        default:
            return "无课"
        }
    }

    var cornerStatusText: String {
        switch message {
        case watchScheduleWidgetCampusNetworkMessage:
            return "待同步"
        case watchScheduleWidgetLoginMessage:
            return "未登录"
        default:
            return "无课"
        }
    }
}

/// 负责把共享快照转换成 watch widget 时间线。
private struct WatchScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchScheduleEntry {
        WatchScheduleEntry(
            date: Date(),
            nextOccurrence: ScheduleExternalOccurrence(
                id: "preview",
                title: "高等数学",
                classroom: "综合教学楼A101",
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
    /// complication 统一只展示“下一节课”，不展示当前正在上的课。
    private func loadEntry(now: Date = Date()) -> WatchScheduleEntry {
        let resolved = ScheduleOccurrenceResolver.loadResolvedSnapshot(now: now, limit: 32)

        guard let snapshot = resolved.snapshot else {
            return WatchScheduleEntry(date: now, nextOccurrence: nil, message: watchScheduleWidgetCampusNetworkMessage)
        }

        guard snapshot.isLoggedIn else {
            return WatchScheduleEntry(date: now, nextOccurrence: nil, message: watchScheduleWidgetLoginMessage)
        }

        let nextOccurrence = resolved.upcomingOccurrences.first(where: { $0.startDate > now })
        return WatchScheduleEntry(
            date: now,
            nextOccurrence: nextOccurrence,
            message: nextOccurrence == nil ? watchScheduleWidgetRestMessage : nil
        )
    }

    /// complication 只需要在“当前展示的下一节课开始时”刷新一次，
    /// 让界面自动切到再下一节；没有下一节课时则定期兜底刷新。
    private func nextRefreshDate(for entry: WatchScheduleEntry) -> Date {
        let now = Date()
        if let nextStartDate = entry.nextOccurrence?.startDate, nextStartDate > now.addingTimeInterval(30) {
            return nextStartDate
        }
        return Calendar.current.date(byAdding: .minute, value: 30, to: now) ?? now.addingTimeInterval(1800)
    }
}

/// 提供给 Apple Watch complication 与 Smart Stack 的课表卡片。
struct BIT101WatchScheduleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BIT101WatchScheduleWidget", provider: WatchScheduleProvider()) { entry in
            WatchScheduleEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("课表")
        .description("在表盘或 Smart Stack 里查看下一节课。")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryInline,
            .accessoryCorner,
            .accessoryRectangular,
        ])
    }
}

/// 根据 family 分发不同的 complication 视图。
private struct WatchScheduleEntryView: View {
    @Environment(\.widgetFamily) private var family

    let entry: WatchScheduleEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            WatchScheduleCircularView(entry: entry)
        case .accessoryCorner:
            WatchScheduleCornerView(entry: entry)
        case .accessoryInline:
            WatchScheduleInlineView(entry: entry)
        case .accessoryRectangular:
            WatchScheduleRectangularView(entry: entry)
        @unknown default:
            WatchScheduleRectangularView(entry: entry)
        }
    }
}

private struct WatchScheduleCircularView: View {
    let entry: WatchScheduleEntry

    var body: some View {
        if let summary = entry.displaySummary {
            VStack(spacing: 0) {
                Text(summary.location.maxBuilding)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Text(summary.location.room ?? " ")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
            }
            .multilineTextAlignment(.center)
        } else {
            Text(entry.circularStatusText)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
        }
    }
}

private struct WatchScheduleCornerView: View {
    let entry: WatchScheduleEntry

    var body: some View {
        if let summary = entry.displaySummary {
            Text(summary.location.maxText)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .widgetCurvesContent()
                .widgetLabel {
                    Text("\(summary.dateText) \(summary.rangeText)")
                }
        } else {
            Text(entry.cornerStatusText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

private struct WatchScheduleInlineView: View {
    let entry: WatchScheduleEntry

    var body: some View {
        if let summary = entry.displaySummary {
            Text(summary.inlineText)
        } else {
            Text(entry.message ?? watchScheduleWidgetRestMessage)
        }
    }
}

private struct WatchScheduleRectangularView: View {
    let entry: WatchScheduleEntry

    var body: some View {
        if let summary = entry.displaySummary {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("下一节")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 4)

                    Text(summary.dateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(summary.location.lightText)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(summary.rangeText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if !summary.courseTitle.isEmpty {
                    Text(summary.courseTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
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
