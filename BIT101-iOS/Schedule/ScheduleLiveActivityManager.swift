//
//  ScheduleLiveActivityManager.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-28.
//

import ActivityKit
import Foundation

/// 课程提醒 Live Activity 的固定属性。
///
/// 当前只有 `studentID` 这一项静态属性，因为它足够区分“当前活动属于哪个账号”。
/// 其余会随课程变化的字段都放进 `ContentState`，便于实时更新。
struct CourseReminderActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 当前展示的是“上课”还是“日程”。
        let kindText: String
        /// 课程名或自定义日程标题。
        let title: String
        /// 教室或自定义日程副标题。
        let classroom: String
        /// 教师名；自定义日程通常为空。
        let teacher: String
        /// 当前项开始时间。
        let startDate: Date
        /// 当前项结束时间。
        let endDate: Date
    }

    let studentID: String
}

/// 根据当前课表或自定义日程挑出来的“当前项 / 下一项”。
///
/// 这是一份只在 Live Activity 选择阶段使用的临时结构，不落盘，也不暴露给视图层。
private struct CourseReminderOccurrence {
    let kindText: String
    let title: String
    let classroom: String
    let teacher: String
    let startDate: Date
    let endDate: Date
}

/// 课程提醒的 Live Activity 管理器。
///
/// 这是一个基础版实现：当课表缓存更新、账号切换或 App 回到前台时刷新一次，
/// 让灵动岛/锁屏展示当前课程、自定义日程或下一项。若用户长时间不打开 App，
/// 它不会自动跨项目切换。
@MainActor
final class ScheduleLiveActivityManager {
    static let shared = ScheduleLiveActivityManager()

    private init() {}

    /// 从当前账号的课表缓存中刷新灵动岛提醒。
    ///
    /// 刷新策略非常保守：
    /// 1. 先确认系统支持并且用户允许 Live Activities。
    /// 2. 再检查本地开关是否开启。
    /// 3. 最后才从缓存里推导“当前项/下一项”。
    func refreshFromCurrentCache() async {
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAllActivities()
            return
        }

        let cache = ScheduleCacheStore.load()
        guard cache.showCourseLiveActivityReminder else {
            await endAllActivities()
            return
        }

        guard let occurrence = nextRelevantOccurrence(
            from: cache,
            firstDay: cache.firstDay,
            leadMinutes: cache.courseLiveActivityLeadMinutes
        ) else {
            await endAllActivities()
            return
        }

        let attributes = CourseReminderActivityAttributes(studentID: LoginStorage.shared.currentStudentID)
        let state = CourseReminderActivityAttributes.ContentState(
            kindText: occurrence.kindText,
            title: occurrence.title,
            classroom: occurrence.classroom,
            teacher: occurrence.teacher,
            startDate: occurrence.startDate,
            endDate: occurrence.endDate
        )
        let staleDate = occurrence.endDate.addingTimeInterval(60)
        let content = ActivityContent(state: state, staleDate: staleDate)

        if let activity = Activity<CourseReminderActivityAttributes>.activities.first {
            // 如果账号已经切换，则旧活动必须立刻结束，避免上一账号的课程继续挂在岛上。
            if activity.attributes.studentID != attributes.studentID {
                await activity.end(nil, dismissalPolicy: .immediate)
                _ = try? Activity.request(attributes: attributes, content: content)
                return
            }
            await activity.update(content)
        } else {
            _ = try? Activity.request(attributes: attributes, content: content)
        }
    }

    /// 主动关闭所有课程提醒。
    func endAllActivities() async {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<CourseReminderActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// 从课表缓存和自定义日程中挑出“当前最值得展示”的一项。
    ///
    /// 规则是：
    /// 1. 先收集所有未来仍未结束的正式课程和自定义日程。
    /// 2. 按开始时间排序。
    /// 3. 优先选择“正在进行中”的项；否则选择落在提前提醒阈值内的下一项。
    private func nextRelevantOccurrence(from cache: ScheduleCache, firstDay: Date?, leadMinutes: Int) -> CourseReminderOccurrence? {
        let slotMap = Dictionary(uniqueKeysWithValues: cache.timeTable.map { ($0.id, $0) })
        let now = Date()

        let courseOccurrences: [CourseReminderOccurrence]
        if let firstDay {
            courseOccurrences = cache.courses.compactMap { course -> CourseReminderOccurrence? in
                guard
                    let week = course.weeks.first(where: { week in
                        guard
                            let endSlot = slotMap[course.endSection],
                            let endDate = combine(firstDay: firstDay, week: week, weekday: course.weekday, time: endSlot.end)
                        else {
                            return false
                        }
                        return endDate > now
                    }),
                    let startSlot = slotMap[course.startSection],
                    let endSlot = slotMap[course.endSection],
                    let startDate = combine(firstDay: firstDay, week: week, weekday: course.weekday, time: startSlot.start),
                    let endDate = combine(firstDay: firstDay, week: week, weekday: course.weekday, time: endSlot.end)
                else {
                    return nil
                }

                return CourseReminderOccurrence(
                    kindText: "上课",
                    title: normalizeCourseTitle(course.name),
                    classroom: normalizeClassroom(course.classroom),
                    teacher: course.teacher,
                    startDate: startDate,
                    endDate: endDate
                )
            }
        } else {
            courseOccurrences = []
        }

        let customOccurrences = cache.customSchedules.compactMap { schedule -> CourseReminderOccurrence? in
            guard
                let date = ScheduleDateCodec.parseDate(schedule.dateString),
                let startDate = combine(date: date, time: schedule.beginTime),
                let endDate = combine(date: date, time: schedule.endTime),
                endDate > now
            else {
                return nil
            }

            return CourseReminderOccurrence(
                kindText: "日程",
                title: schedule.title,
                classroom: schedule.subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
                teacher: "",
                startDate: startDate,
                endDate: endDate
            )
        }

        let occurrences = courseOccurrences + customOccurrences

        return occurrences.sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate {
                return lhs.startDate < rhs.startDate
            }
            return lhs.title < rhs.title
        }
        .first { occurrence in
            if occurrence.startDate <= now && now < occurrence.endDate {
                return true
            }
            let thresholdDate = now.addingTimeInterval(TimeInterval(max(leadMinutes, 0) * 60))
            return occurrence.startDate <= thresholdDate
        }
    }

    /// 把某一天和 `HH:mm` 文本拼成精确时间点。
    private func combine(date: Date, time: String) -> Date? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }

        var components = ScheduleDateCodec.calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return ScheduleDateCodec.calendar.date(from: components)
    }

    /// 把“首周 + 教学周 + 星期几 + 节次时间”拼成真实上课时间。
    private func combine(firstDay: Date, week: Int, weekday: Int, time: String) -> Date? {
        let dayOffset = (week - 1) * 7 + (weekday - 1)
        guard let day = ScheduleDateCodec.calendar.date(byAdding: .day, value: dayOffset, to: firstDay) else {
            return nil
        }

        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }

        var components = ScheduleDateCodec.calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return ScheduleDateCodec.calendar.date(from: components)
    }

    /// 对教室名称做轻量缩写，尽量压缩灵动岛和锁屏组件的展示宽度。
    private func normalizeClassroom(_ value: String) -> String {
        value
            .replacingOccurrences(of: "理教楼", with: "理教")
            .replacingOccurrences(of: "文萃楼", with: "文萃")
    }

    /// 对课程名做轻量归一化，去掉不必要的前缀噪音。
    private func normalizeCourseTitle(_ value: String) -> String {
        if value.hasPrefix("体育/") {
            return String(value.dropFirst("体育/".count))
        }
        return value
    }
}
