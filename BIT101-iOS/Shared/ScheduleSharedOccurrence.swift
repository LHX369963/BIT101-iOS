import Foundation

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
        "\(Self.timeFormatter.string(from: startDate))-\(Self.timeFormatter.string(from: endDate))"
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
            return Self.shortDateFormatter.string(from: startDate)
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

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M月d日"
        return formatter
    }()
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
        guard let firstDay = parseDate(snapshot.firstDayString) else {
            return []
        }

        let slotMap = Dictionary(uniqueKeysWithValues: snapshot.timeTable.map { ($0.id, $0) })

        let rawOccurrences = snapshot.courses
            .flatMap { course in
                course.weeks.compactMap { week -> ScheduleExternalOccurrence? in
                    guard
                        let startSlot = slotMap[course.startSection],
                        let endSlot = slotMap[course.endSection],
                        let startDate = combine(date: firstDay, week: week, weekday: course.weekday, time: startSlot.start),
                        let endDate = combine(date: firstDay, week: week, weekday: course.weekday, time: endSlot.end),
                        endDate > now
                    else {
                        return nil
                    }

                    return ScheduleExternalOccurrence(
                        id: "\(course.id)-\(week)",
                        title: normalizeCourseTitle(course.name),
                        classroom: normalizeClassroom(course.classroom),
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
        guard !string.isEmpty else { return nil }
        return dateFormatter.date(from: string)
    }

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
