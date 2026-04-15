import Foundation

/// 日程相关跨 target 共用的展示规范化工具。
///
/// 当前主要收口两类“看起来一样、但之前散落在多处”的规则：
/// - 教室名称缩写
/// - 课程标题压缩
///
/// 这样主 App、widget、watch、Live Activity 后续只需要维护这一份展示约定。
enum ScheduleDisplayNormalizer {
    /// 压缩教室名称里的冗长楼名，提升小屏与卡片场景下的可读性。
    static func normalizeClassroom(_ value: String) -> String {
        value
            .replacingOccurrences(of: "理教楼", with: "理教")
            .replacingOccurrences(of: "文萃楼", with: "文萃")
    }

    /// 对课程标题做本地展示优化。
    ///
    /// 目前主要把 `体育/xx` 压缩成 `xx`。
    static func normalizeCourseTitle(_ value: String) -> String {
        if value.hasPrefix("体育/") {
            return String(value.dropFirst("体育/".count))
        }
        return value
    }
}

/// 日程相关跨 target 共用的日期编解码与时间组合工具。
///
/// 共享层、小组件、watch、Live Activity 都依赖同一套“日期字符串 / 节次时间 -> 绝对时间”
/// 的规则，因此把重叠部分统一收口到这里，避免多个模块各自维护一份。
enum ScheduleSharedDateCodec {
    /// 固定使用公历，避免系统日历设置影响周数计算。
    static let calendar: Calendar = {
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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        return dateFormatter.date(from: string)
    }

    static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func formatShortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    static func combine(firstDay: Date, week: Int, weekday: Int, time: String) -> Date? {
        let dayOffset = (week - 1) * 7 + (weekday - 1)
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: firstDay) else {
            return nil
        }
        return combine(date: day, time: time)
    }

    static func combine(date: Date, time: String) -> Date? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }
}

/// 跨外部展示层共用的课程实例。
///
/// 它是把“周次 + 星期 + 节次”展开后的最终结果：
/// 拿到它之后，widget / watch / Live Activity 都可以直接做排序、展示和倒计时。
struct ScheduleExternalOccurrence: Identifiable, Hashable {
    let id: String
    let title: String
    let classroom: String
    let teacher: String
    let startDate: Date
    let endDate: Date
    let displayUntilDate: Date

    func isCurrent(at date: Date = Date()) -> Bool {
        startDate <= date && date < displayUntilDate
    }

    func countdownTargetDate(at date: Date = Date()) -> Date {
        isCurrent(at: date) ? displayUntilDate : startDate
    }

    var rangeText: String {
        "\(ScheduleSharedDateCodec.formatTime(startDate))-\(ScheduleSharedDateCodec.formatTime(endDate))"
    }

    func relativeDayText(referenceDate: Date = Date()) -> String {
        let startOfToday = Self.calendar.startOfDay(for: referenceDate)
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
            return ScheduleSharedDateCodec.formatShortDate(startDate)
        }
    }

    private static let calendar = ScheduleSharedDateCodec.calendar
}

/// 外部展示层使用的“快照 + 未来课程”解析结果。
///
/// watch app、watch widget 等消费方经常会重复做三件事：
/// 1. 读取共享快照
/// 2. 推导未来课程
/// 3. 取出第一节作为“当前 / 下一节”
///
/// 这里把这套胶水逻辑收成一个轻量结果，避免各端各写一遍。
struct ScheduleExternalResolvedSnapshot {
    let snapshot: ScheduleExternalSnapshot?
    let upcomingOccurrences: [ScheduleExternalOccurrence]

    var nextOccurrence: ScheduleExternalOccurrence? {
        upcomingOccurrences.first
    }
}

/// 共享快照到课程 occurrence 的统一解析器。
///
/// 当前 widget 与未来 watch 端都应该复用它，避免各自维护一套“首周 + 周次 + 节次 -> 实际上课时间”的推导逻辑。
enum ScheduleOccurrenceResolver {
    static let defaultCurrentCourseDisplayDuration: TimeInterval = 5 * 60

    static func upcomingOccurrences(
        from snapshot: ScheduleExternalSnapshot,
        now: Date = Date(),
        currentCourseDisplayDuration: TimeInterval = defaultCurrentCourseDisplayDuration
    ) -> [ScheduleExternalOccurrence] {
        guard let firstDay = ScheduleSharedDateCodec.parseDate(snapshot.firstDayString) else {
            return []
        }

        let slotMap = Dictionary(uniqueKeysWithValues: snapshot.timeTable.map { ($0.id, $0) })

        let rawOccurrences = snapshot.courses
            .flatMap { course in
                course.weeks.compactMap { week -> ScheduleExternalOccurrence? in
                    guard
                        let startSlot = slotMap[course.startSection],
                        let endSlot = slotMap[course.endSection],
                        let startDate = ScheduleSharedDateCodec.combine(firstDay: firstDay, week: week, weekday: course.weekday, time: startSlot.start),
                        let endDate = ScheduleSharedDateCodec.combine(firstDay: firstDay, week: week, weekday: course.weekday, time: endSlot.end),
                        endDate > now
                    else {
                        return nil
                    }

                    return ScheduleExternalOccurrence(
                        id: "\(course.id)-\(week)",
                        title: ScheduleDisplayNormalizer.normalizeCourseTitle(course.name),
                        classroom: ScheduleDisplayNormalizer.normalizeClassroom(course.classroom),
                        teacher: course.teacher,
                        startDate: startDate,
                        endDate: endDate,
                        displayUntilDate: endDate
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                return lhs.title < rhs.title
            }

        return rawOccurrences.enumerated().compactMap { index, occurrence in
            let hasLaterOccurrence = rawOccurrences.indices.contains(index + 1)
            let displayUntilDate: Date

            if hasLaterOccurrence {
                displayUntilDate = min(
                    occurrence.endDate,
                    occurrence.startDate.addingTimeInterval(currentCourseDisplayDuration)
                )
            } else {
                displayUntilDate = occurrence.endDate
            }

            guard displayUntilDate > now else {
                return nil
            }

            return ScheduleExternalOccurrence(
                id: occurrence.id,
                title: occurrence.title,
                classroom: occurrence.classroom,
                teacher: occurrence.teacher,
                startDate: occurrence.startDate,
                endDate: occurrence.endDate,
                displayUntilDate: displayUntilDate
            )
        }
    }

    static func parseDate(_ string: String) -> Date? {
        ScheduleSharedDateCodec.parseDate(string)
    }

    /// 从一份共享快照解析外部展示层真正关心的最小状态。
    ///
    /// `limit` 允许 watch 这类小屏设备只保留前若干节候选，
    /// 从而在不改变 UI 的前提下减少重复切片与状态分发逻辑。
    static func resolvedSnapshot(
        from snapshot: ScheduleExternalSnapshot?,
        now: Date = Date(),
        currentCourseDisplayDuration: TimeInterval = defaultCurrentCourseDisplayDuration,
        limit: Int? = nil
    ) -> ScheduleExternalResolvedSnapshot {
        guard let snapshot else {
            return ScheduleExternalResolvedSnapshot(snapshot: nil, upcomingOccurrences: [])
        }

        let occurrences = upcomingOccurrences(
            from: snapshot,
            now: now,
            currentCourseDisplayDuration: currentCourseDisplayDuration
        )
        let trimmedOccurrences: [ScheduleExternalOccurrence]
        if let limit, limit >= 0 {
            trimmedOccurrences = Array(occurrences.prefix(limit))
        } else {
            trimmedOccurrences = occurrences
        }

        return ScheduleExternalResolvedSnapshot(
            snapshot: snapshot,
            upcomingOccurrences: trimmedOccurrences
        )
    }

    /// 直接从共享仓库读取并解析。
    static func loadResolvedSnapshot(
        now: Date = Date(),
        currentCourseDisplayDuration: TimeInterval = defaultCurrentCourseDisplayDuration,
        limit: Int? = nil
    ) -> ScheduleExternalResolvedSnapshot {
        resolvedSnapshot(
            from: ScheduleExternalSnapshotStore.load(),
            now: now,
            currentCourseDisplayDuration: currentCourseDisplayDuration,
            limit: limit
        )
    }
}
