//
//  BIT101ScheduleWidget.swift
//  BIT101ScheduleWidget
//
//  Created by Codex on 2026-03-28.
//

import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

/// 课表未同步时统一使用的 widget 空态提示。
private let scheduleWidgetCampusNetworkMessage = "请在校园网环境下，获取课表"
/// 当后续没有课程时统一使用的 widget 空态提示。
private let scheduleWidgetRestMessage = "课已经上完，好好休息"

/// 课表小组件与主 App 共享的 App Group 标识。
///
/// widget extension 无法直接访问主 App 沙盒，因此必须通过 App Group 共享一份精简快照。
private enum ScheduleWidgetSharedContainer {
    static let identifier = "group.BIT101-dev.BIT101-iOS.shared"
}

/// 从共享容器读取的精简节次模型。
///
/// 这是 widget 侧自己的镜像模型，故意不直接依赖主 app target 里的类型定义。
private struct ScheduleWidgetTimeSlotSnapshot: Codable {
    let id: Int
    let start: String
    let end: String
}

/// 从共享容器读取的精简课程模型。
///
/// 只保留 widget 展示“下一节课/后续课程”所需字段，尽量压缩共享数据体积。
private struct ScheduleWidgetCourseSnapshot: Codable {
    let id: String
    let name: String
    let classroom: String
    let teacher: String
    let weeks: [Int]
    let weekday: Int
    let startSection: Int
    let endSection: Int
}

/// 小组件共享课表快照。
///
/// 主 app 写、widget 读，只要这份结构稳定，两边就可以独立演进 UI。
private struct ScheduleWidgetSnapshot: Codable {
    let firstDayString: String
    let timeTable: [ScheduleWidgetTimeSlotSnapshot]
    let courses: [ScheduleWidgetCourseSnapshot]
}

/// 课程提醒 Live Activity 的固定属性。
struct CourseReminderActivityAttributes: ActivityAttributes {
    /// Live Activity 的动态显示内容。
    ///
    /// 这里只保留锁屏和灵动岛真正需要的最小字段，
    /// 避免把冗余信息带进 ActivityKit 的状态更新里。
    public struct ContentState: Codable, Hashable {
        let kindText: String
        let title: String
        let classroom: String
        let teacher: String
        let startDate: Date
        let endDate: Date
    }

    let studentID: String
}

/// 供 Widget 时间线使用的单节课程实例。
///
/// 这是从共享快照展开后的“真实课程 occurrence”，已经具备开始/结束时间，可直接参与排序和时间线刷新。
private struct ScheduleWidgetOccurrence: Identifiable {
    let id: String
    let title: String
    let classroom: String
    let teacher: String
    let startDate: Date
    let endDate: Date

    var isCurrent: Bool {
        let now = Date()
        return startDate <= now && now < endDate
    }

    var rangeText: String {
        "\(Self.timeFormatter.string(from: startDate))-\(Self.timeFormatter.string(from: endDate))"
    }

    var shortDateText: String {
        Self.dateFormatter.string(from: startDate)
    }

    var relativeDayText: String {
        let startOfToday = Self.calendar.startOfDay(for: Date())
        let startOfClassDay = Self.calendar.startOfDay(for: startDate)
        let dayDiff = Self.calendar.dateComponents([.day], from: startOfToday, to: startOfClassDay).day ?? 0

        switch dayDiff {
        case ...0:
            return "今天"
        case 1:
            return "明天"
        case 2:
            return "后天"
        case 3:
            return "大后天"
        default:
            return shortDateText
        }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}

@available(iOSApplicationExtension 16.2, *)
/// 课程提醒 Live Activity 配置。
///
/// 锁屏态展示完整信息；灵动岛紧凑态只保留“类型 + 分钟数”，
/// 尽量压缩横向宽度，减少对系统岛布局的影响。
struct CourseReminderLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CourseReminderActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(context.state.kindText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Text(context.state.startDate, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(context.state.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(context.state.classroom.isEmpty ? context.state.teacher : context.state.classroom)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(timerTargetDate(for: context.state), style: .timer)
                    .font(.title3.monospacedDigit())
                    .fontWeight(.semibold)
            }
            .padding(12)
            .activityBackgroundTint(.clear)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    Text(context.state.kindText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: -1) {
                        Text(countdownCaption(for: context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(timerTargetDate(for: context.state), style: .timer)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Text(context.state.kindText)
                    .font(.caption)
                    .lineLimit(1)
            } compactTrailing: {
                Text(compactMinutesText(for: context.state))
                    .font(.caption)
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "calendar.badge.clock")
            }
            .contentMargins([.leading, .trailing], 8, for: .expanded)
            .contentMargins([.top, .bottom], 4, for: .expanded)
            .widgetURL(URL(string: "bit101://schedule/courses"))
        }
    }

    private func timerTargetDate(for state: CourseReminderActivityAttributes.ContentState) -> Date {
        let now = Date()
        if state.startDate > now {
            return state.startDate
        }
        return state.endDate
    }

    /// 展开态右上角的小标题：未开始显示“距离”，进行中显示“剩余”。
    private func countdownCaption(for state: CourseReminderActivityAttributes.ContentState) -> String {
        state.startDate > Date() ? "距离" : "剩余"
    }

    /// 紧凑态右侧的分钟数文本，例如 `12分`。
    private func compactMinutesText(for state: CourseReminderActivityAttributes.ContentState) -> String {
        let now = Date()
        let target = state.startDate > now ? state.startDate : state.endDate
        let seconds = max(0, Int(target.timeIntervalSince(now)))
        let minutes = Int(ceil(Double(seconds) / 60.0))
        return "\(minutes)分"
    }
}

/// Widget 渲染使用的统一条目。
///
/// 一个时间线条目里既可能有后续课程，也可能只有一条空态消息。
private struct ScheduleWidgetEntry: TimelineEntry {
    let date: Date
    let nextOccurrences: [ScheduleWidgetOccurrence]
    let message: String?
}

/// 课表小组件的时间线提供器。
private struct ScheduleWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleWidgetEntry {
        ScheduleWidgetEntry(
            date: Date(),
            nextOccurrences: [
                ScheduleWidgetOccurrence(
                    id: "preview-next",
                    title: "高等数学",
                    classroom: "理教201",
                    teacher: "张老师",
                    startDate: Date().addingTimeInterval(20 * 60),
                    endDate: Date().addingTimeInterval(110 * 60)
                ),
                ScheduleWidgetOccurrence(
                    id: "preview-later",
                    title: "大学英语",
                    classroom: "文萃302",
                    teacher: "李老师",
                    startDate: Date().addingTimeInterval(180 * 60),
                    endDate: Date().addingTimeInterval(260 * 60)
                ),
            ],
            message: nil
        )
    }

    /// 供预览和系统快照使用的当前条目。
    func getSnapshot(in context: Context, completion: @escaping (ScheduleWidgetEntry) -> Void) {
        completion(loadEntry())
    }

    /// 构造一条时间线；下一次刷新时间取决于最近课程的开始/结束节点。
    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleWidgetEntry>) -> Void) {
        let entry = loadEntry()
        let refreshDate = nextRefreshDate(for: entry)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }

    private func loadEntry() -> ScheduleWidgetEntry {
        guard let snapshot = loadSnapshot() else {
            return emptyEntry(message: scheduleWidgetCampusNetworkMessage)
        }

        guard let firstDay = Self.parseDate(snapshot.firstDayString) else {
            return emptyEntry(message: scheduleWidgetCampusNetworkMessage)
        }

        guard !snapshot.courses.isEmpty else {
            return emptyEntry(message: scheduleWidgetCampusNetworkMessage)
        }

        let occurrences = buildUpcomingOccurrences(from: snapshot, firstDay: firstDay)
        let message = occurrences.isEmpty ? scheduleWidgetRestMessage : nil

        return ScheduleWidgetEntry(
            date: Date(),
            nextOccurrences: Array(occurrences.prefix(6)),
            message: message
        )
    }

    /// 构造统一的空态条目，避免多处重复写空数组与同样的文案。
    private func emptyEntry(message: String) -> ScheduleWidgetEntry {
        ScheduleWidgetEntry(
            date: Date(),
            nextOccurrences: [],
            message: message
        )
    }

    /// 从共享容器读取主 App 导出的课表快照。
    private func loadSnapshot() -> ScheduleWidgetSnapshot? {
        guard
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ScheduleWidgetSharedContainer.identifier
            )
        else {
            return nil
        }

        let fileURL = containerURL
            .appending(path: "Widgets", directoryHint: .isDirectory)
            .appending(path: "schedule-widget-snapshot.json")

        guard
            let data = try? Data(contentsOf: fileURL)
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScheduleWidgetSnapshot.self, from: data)
    }

    /// 把精简快照展开成“当前时刻之后的课程实例”。
    private func buildUpcomingOccurrences(
        from snapshot: ScheduleWidgetSnapshot,
        firstDay: Date
    ) -> [ScheduleWidgetOccurrence] {
        let slotMap = Dictionary(uniqueKeysWithValues: snapshot.timeTable.map { ($0.id, $0) })
        let now = Date()

        return snapshot.courses
            .flatMap { course in
                course.weeks.compactMap { week -> ScheduleWidgetOccurrence? in
                    guard
                        let startSlot = slotMap[course.startSection],
                        let endSlot = slotMap[course.endSection],
                        let startDate = Self.combine(date: firstDay, week: week, weekday: course.weekday, time: startSlot.start),
                        let endDate = Self.combine(date: firstDay, week: week, weekday: course.weekday, time: endSlot.end),
                        endDate > now
                    else {
                        return nil
                    }

                    return ScheduleWidgetOccurrence(
                        id: "\(course.id)-\(week)",
                        title: Self.normalizeCourseTitle(course.name),
                        classroom: Self.normalizeClassroom(course.classroom),
                        teacher: course.teacher,
                        startDate: startDate,
                        endDate: endDate
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                return lhs.title < rhs.title
            }
    }

    /// 计算 widget 下一次需要刷新的时间点。
    ///
    /// 优先在最近一节课的开始/结束节点刷新；没有课程时再走兜底刷新。
    private func nextRefreshDate(for entry: ScheduleWidgetEntry) -> Date {
        let now = Date()
        let candidates = entry.nextOccurrences
            .flatMap { [$0.startDate, $0.endDate] }
            .filter { $0 > now.addingTimeInterval(30) }
            .sorted()

        if let next = candidates.first {
            return next
        }

        return Calendar.current.date(byAdding: .minute, value: 30, to: now) ?? now.addingTimeInterval(1800)
    }

    /// 解析共享快照里的首周日期。
    private static func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        return dateFormatter.date(from: string)
    }

    /// 把教学周 + 星期 + 节次时间展开成真实上课时间。
    private static func combine(date firstDay: Date, week: Int, weekday: Int, time: String) -> Date? {
        let dayOffset = (week - 1) * 7 + (weekday - 1)
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: firstDay) else {
            return nil
        }

        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    private static func normalizeClassroom(_ value: String) -> String {
        value
            .replacingOccurrences(of: "理教楼", with: "理教")
            .replacingOccurrences(of: "文萃楼", with: "文萃")
    }

    private static func normalizeCourseTitle(_ value: String) -> String {
        if value.hasPrefix("体育/") {
            return String(value.dropFirst("体育/".count))
        }
        return value
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// 课程表小组件主体。
///
/// 同一个 widget 同时支持桌面小组件与锁屏 accessory family。
struct BIT101ScheduleWidget: Widget {
    let kind = "BIT101ScheduleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleWidgetProvider()) { entry in
            ScheduleWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "bit101://schedule/courses"))
        }
        .configurationDisplayName("课程表")
        .description("查看下一节课，支持桌面和锁屏组件。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

/// 小组件视图。
///
/// 根据 family 分发到三套布局，但都复用同一份时间线条目。
private struct ScheduleWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family

    let entry: ScheduleWidgetEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            accessoryRectangularBody
        case .accessoryInline:
            accessoryInlineBody
        case .accessoryCircular:
            accessoryCircularBody
        case .systemLarge:
            largeBody
        case .systemMedium:
            mediumBody
        default:
            smallBody
        }
    }

    /// 2x2 小号组件。
    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let first = entry.nextOccurrences.first {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(first.isCurrent ? "正在上" : "下一节")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Text(first.relativeDayText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(first.title)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    Text(first.rangeText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !first.classroom.isEmpty {
                        Text(first.classroom)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(0)
    }

    /// 锁屏长条组件。
    private var accessoryRectangularBody: some View {
        Group {
            if let first = entry.nextOccurrences.first {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(first.isCurrent ? "正在上" : "下一节")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Text(first.relativeDayText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Text(first.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(accessoryMetaText(for: first))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text(entry.message == scheduleWidgetCampusNetworkMessage ? "请先同步课表" : "暂无课程")
                    .font(.caption)
                    .lineLimit(2)
            }
        }
    }

    /// 锁屏单行组件。
    private var accessoryInlineBody: some View {
        Group {
            if let first = entry.nextOccurrences.first {
                Text("\(first.isCurrent ? "正在上" : "下一节") \(first.title)")
                    .lineLimit(1)
            } else {
                Text(entry.message == scheduleWidgetCampusNetworkMessage ? "请先同步课表" : "暂无课程")
                    .lineLimit(1)
            }
        }
    }

    /// 锁屏圆形组件。
    private var accessoryCircularBody: some View {
        ZStack {
            AccessoryWidgetBackground()

            if let first = entry.nextOccurrences.first {
                VStack(spacing: 1) {
                    Image(systemName: first.isCurrent ? "play.circle.fill" : "calendar.badge.clock")
                        .font(.caption2)
                    Text(circularCountdownText(for: first))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            } else {
                VStack(spacing: 1) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                    Text("无课")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                }
            }
        }
    }

    /// 2x4 中号组件。
    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let first = entry.nextOccurrences.first {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(first.isCurrent ? "正在上" : "下一节")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Text(first.relativeDayText)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }

                    Text(first.title)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Text("\(first.rangeText)\(first.classroom.isEmpty ? "" : " · \(first.classroom)")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !entry.nextOccurrences.dropFirst().isEmpty {
                    Text("后续")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(entry.nextOccurrences.dropFirst().prefix(1))) { occurrence in
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(occurrence.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)

                                Text(occurrence.classroom)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Text(occurrence.rangeText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(0)
    }

    /// 4x4 大号组件。
    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let first = entry.nextOccurrences.first {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(first.isCurrent ? "正在上" : "下一节")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Text(first.relativeDayText)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }

                    Text(first.title)
                        .font(.title3)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Text(first.rangeText)
                        .font(.headline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !first.classroom.isEmpty || !first.teacher.isEmpty {
                        Text(primaryMetaText(for: first))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if !entry.nextOccurrences.dropFirst().isEmpty {
                    Text("后续")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        ForEach(Array(entry.nextOccurrences.dropFirst().prefix(4))) { occurrence in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(occurrence.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.82)

                                    let meta = secondaryMetaText(for: occurrence)
                                    if !meta.isEmpty {
                                        Text(meta)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer(minLength: 0)

                                Text(occurrence.rangeText)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } else {
                emptyState
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(0)
    }

    /// 大号组件主课的地点/老师摘要。
    private func primaryMetaText(for occurrence: ScheduleWidgetOccurrence) -> String {
        if !occurrence.classroom.isEmpty && !occurrence.teacher.isEmpty {
            return "\(occurrence.classroom) · \(occurrence.teacher)"
        }
        if !occurrence.classroom.isEmpty {
            return occurrence.classroom
        }
        return occurrence.teacher
    }

    /// 后续课程的次级摘要。
    private func secondaryMetaText(for occurrence: ScheduleWidgetOccurrence) -> String {
        if !occurrence.classroom.isEmpty {
            return occurrence.classroom
        }
        return occurrence.teacher
    }

    /// 锁屏长条组件的辅助摘要。
    private func accessoryMetaText(for occurrence: ScheduleWidgetOccurrence) -> String {
        if !occurrence.classroom.isEmpty {
            return "\(occurrence.rangeText) \(occurrence.classroom)"
        }
        return occurrence.rangeText
    }

    /// 锁屏圆形组件里展示的分钟数倒计时。
    private func circularCountdownText(for occurrence: ScheduleWidgetOccurrence) -> String {
        let target = occurrence.isCurrent ? occurrence.endDate : occurrence.startDate
        let seconds = max(0, Int(target.timeIntervalSince(Date())))
        let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
        return "\(minutes)分"
    }

    /// 没有课表或后续无课时的统一空态。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.message ?? scheduleWidgetRestMessage)
                .font(.subheadline.weight(.medium))
            if entry.message == scheduleWidgetCampusNetworkMessage {
                Text("打开 App 同步课表后，这里会显示下一节课。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
