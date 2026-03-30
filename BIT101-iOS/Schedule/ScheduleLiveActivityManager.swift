//
//  ScheduleLiveActivityManager.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-28.
//

import ActivityKit
import Foundation
import os

/// 课程提醒 Live Activity 的固定属性。
struct CourseReminderActivityAttributes: ActivityAttributes {
    /// 锁屏 / 灵动岛展示所需的最小动态状态。
    ///
    /// 这里故意只保留“提醒对象是谁”和“倒计时指向哪个未来时间点”，
    /// 不再把整节课时长、当前进度之类信息带进来，避免状态比较和更新链路
    /// 因为无关字段变化而变复杂。
    public struct ContentState: Codable, Hashable {
        let kindText: String
        let title: String
        let classroom: String
        let teacher: String
        let timeRangeText: String
        let countdownTargetDate: Date
    }

    let studentID: String
}

/// 内部使用的临时结构，用于逻辑计算。
private struct CourseReminderOccurrence {
    let kindText: String
    let title: String
    let classroom: String
    let teacher: String
    let startDate: Date
    let endDate: Date
}

@MainActor
final class ScheduleLiveActivityManager {
    static let shared = ScheduleLiveActivityManager()

    private let logger = Logger(subsystem: "BIT101", category: "ScheduleLiveActivity")
    private var scheduledRefreshTask: Task<Void, Never>?
    private var scheduledEndTask: Task<Void, Never>?

    private init() {}

    /// 核心刷新逻辑。
    ///
    /// 这条链路只做三件事：
    /// 1. 读取当前账号的课表缓存与提醒设置
    /// 2. 计算“此刻是否应该存在一个课前提醒”
    /// 3. 把计算结果同步给 ActivityKit
    ///
    /// 它不会在这里直接操心展示层细节；展示样式全部交给 widget extension。
    func refreshFromCurrentCache(trigger: String = "unspecified") async {
        logger.debug("refreshFromCurrentCache trigger=\(trigger, privacy: .public)")

        guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.debug("live activity unavailable or disabled by system; ending all activities")
            await endAllActivities()
            return
        }

        // 退出登录或远端登录态失效后，fake-cookie 会被清掉，但账号密码和课表缓存仍可能保留。
        // 课程提醒只应服务于“当前真实已登录”的账号，因此这里把会话有效性作为前置门槛。
        guard !LoginStorage.shared.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.debug("fake-cookie missing; treating session as signed out and ending all activities")
            await endAllActivities()
            return
        }

        let cache = ScheduleCacheStore.load()
        guard cache.showCourseLiveActivityReminder else {
            logger.debug("course live activity reminder disabled in settings; ending all activities")
            await endAllActivities()
            return
        }

        let leadMinutes = cache.courseLiveActivityLeadMinutes
        let occurrences = resolveOccurrences(from: cache)
        logger.debug("resolved occurrences count=\(occurrences.count, privacy: .public) leadMinutes=\(leadMinutes, privacy: .public)")
        
        // 只在“进入提醒窗口但尚未开始”的课前阶段选择一条提醒对象。
        let now = Date()
        let currentOccurrence = occurrences.first { occ in
            let displayWindowStart = effectiveDisplayWindowStart(for: occ, among: occurrences, leadMinutes: leadMinutes)
            return now >= displayWindowStart && now < occ.startDate
        }

        if let currentOccurrence {
            logger.debug(
                "selected occurrence kind=\(currentOccurrence.kindText, privacy: .public) title=\(currentOccurrence.title, privacy: .public) start=\(Self.debugDateFormatter.string(from: currentOccurrence.startDate), privacy: .public) end=\(Self.debugDateFormatter.string(from: currentOccurrence.endDate), privacy: .public)"
            )
        } else {
            logger.debug("selected occurrence is nil for current time=\(Self.debugDateFormatter.string(from: now), privacy: .public)")
        }

        // 先安排下一次自动唤醒，再同步当前状态。
        // 这样即便 app 后续一直留在后台，也能在“进入提醒窗口”或“提醒该结束了”
        // 这两个边界点主动重新计算一次。
        scheduleNextRefresh(for: occurrences, leadMinutes: leadMinutes)
        scheduleEndForDisplayedOccurrence(currentOccurrence)

        await syncActivity(with: currentOccurrence)
    }

    /// 将当前计算出的提醒对象同步到 ActivityKit。
    ///
    /// 规则很明确：
    /// - 没有提醒对象：结束现有 activity
    /// - 有提醒对象且内容没变：什么都不做
    /// - 有提醒对象且内容变了：更新现有 activity
    /// - 当前没有 activity：新建一个 activity
    ///
    /// 另外，activity 还带有 `studentID`，这是为了避免切号后复用到上一个账号的提醒。
    private func syncActivity(with occurrence: CourseReminderOccurrence?) async {
        let studentID = LoginStorage.shared.currentStudentID
        let activities = Activity<CourseReminderActivityAttributes>.activities
        let activeActivity = activities.first
        logger.debug("syncActivity activeCount=\(activities.count, privacy: .public) currentStudentID=\(studentID, privacy: .public)")

        // 1. 如果当前没有课要上，直接关掉现有的活动
        guard let occ = occurrence else {
            if let activity = activeActivity {
                logger.debug("ending activity id=\(activity.id, privacy: .public) because occurrence is nil")
                await activity.end(nil, dismissalPolicy: .immediate)
            } else {
                logger.debug("no occurrence and no active activity; nothing to end")
            }
            return
        }

        let newState = CourseReminderActivityAttributes.ContentState(
            kindText: occ.kindText,
            title: occ.title,
            classroom: occ.classroom,
            teacher: occ.teacher,
            timeRangeText: Self.timeRangeText(start: occ.startDate, end: occ.endDate),
            countdownTargetDate: occ.startDate
        )
        
        let content = ActivityContent(state: newState, staleDate: occ.startDate)
        let attributes = CourseReminderActivityAttributes(studentID: studentID)

        if let activity = activeActivity {
            logger.debug(
                "active activity id=\(activity.id, privacy: .public) state=\(Self.describe(activity.content.state), privacy: .public) next=\(Self.describe(newState), privacy: .public)"
            )
            // 情况 A：账号换了，必须重开
            if activity.attributes.studentID != studentID {
                logger.debug("student changed old=\(activity.attributes.studentID, privacy: .public) new=\(studentID, privacy: .public); ending and requesting new activity")
                await activity.end(nil, dismissalPolicy: .immediate)
                await requestActivity(attributes: attributes, content: content, reason: "student_changed")
                return
            }
            
            // 情况 B：内容已经是一样的了，不要去捅系统，防止 UI 闪烁
            if activity.content.state == newState {
                logger.debug("skipping update because content state is unchanged")
                return
            }

            // 情况 C：核心改进点。使用 update 保证灵动岛不会因为“重连”而乱跳
            logger.debug("updating activity id=\(activity.id, privacy: .public)")
            await activity.update(content)
        } else {
            // 情况 D：当前没活动，新开一个
            await requestActivity(attributes: attributes, content: content, reason: "no_active_activity")
        }
    }

    /// 预排期下一次刷新。
    ///
    /// 这里不做高频轮询，只盯两个边界：
    /// - 某条课/日程进入提醒窗口
    /// - 某条课/日程正式开始，提醒应当消失
    private func scheduleNextRefresh(for occurrences: [CourseReminderOccurrence], leadMinutes: Int) {
        scheduledRefreshTask?.cancel()
        
        let now = Date()
        // 只需要关注两个时间点：1. 该显示新提醒了；2. 课程开始了（该消失了）。
        let refreshPoints = occurrences.flatMap { occurrence in
            [
                effectiveDisplayWindowStart(for: occurrence, among: occurrences, leadMinutes: leadMinutes),
                occurrence.startDate,
            ]
        }.filter { $0 > now.addingTimeInterval(1) }.sorted()

        guard let nextDate = refreshPoints.first else {
            logger.debug("scheduleNextRefresh: no future refresh point")
            return
        }

        logger.debug("scheduleNextRefresh nextDate=\(Self.debugDateFormatter.string(from: nextDate), privacy: .public)")

        scheduledRefreshTask = Task {
            try? await Task.sleep(for: .seconds(nextDate.timeIntervalSince(now)))
            if !Task.isCancelled {
                await refreshFromCurrentCache(trigger: "scheduled_refresh")
            }
        }
    }

    /// 为当前展示的提醒额外安排一个“到点立即结束”的任务。
    ///
    /// 这层任务和常规 refresh 并存，目的是尽量避免用户看到倒计时过零后还挂着旧提醒。
    private func scheduleEndForDisplayedOccurrence(_ occurrence: CourseReminderOccurrence?) {
        scheduledEndTask?.cancel()
        scheduledEndTask = nil

        guard let occurrence else { return }

        let now = Date()
        guard occurrence.startDate > now.addingTimeInterval(0.5) else { return }

        let expectedTarget = occurrence.startDate
        let expectedStudentID = LoginStorage.shared.currentStudentID

        scheduledEndTask = Task {
            try? await Task.sleep(for: .seconds(expectedTarget.timeIntervalSince(now)))
            guard !Task.isCancelled else { return }
            await endActivityIfStillMatching(expectedTarget: expectedTarget, expectedStudentID: expectedStudentID)
        }
    }

    /// 仅当当前 activity 仍然对应同一条提醒时，才在到点时结束它。
    private func endActivityIfStillMatching(expectedTarget: Date, expectedStudentID: String) async {
        guard #available(iOS 16.2, *) else { return }
        guard let activity = Activity<CourseReminderActivityAttributes>.activities.first else { return }
        guard activity.attributes.studentID == expectedStudentID else { return }
        guard activity.content.state.countdownTargetDate == expectedTarget else { return }

        logger.debug("ending activity id=\(activity.id, privacy: .public) because countdown target reached")
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    /// 清理所有活动。
    func endAllActivities() async {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        scheduledEndTask?.cancel()
        scheduledEndTask = nil
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<CourseReminderActivityAttributes>.activities {
            logger.debug("endAllActivities ending id=\(activity.id, privacy: .public)")
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: - 数据解析逻辑

    /// 把课表缓存解析成未来仍然有效的提醒候选。
    ///
    /// 这里同时覆盖：
    /// - 常规课程
    /// - 自定义日程
    ///
    /// 并且只保留“结束时间仍晚于现在”的实例，避免过期数据继续参与提醒筛选。
    private func resolveOccurrences(from cache: ScheduleCache) -> [CourseReminderOccurrence] {
        let now = Date()
        let slotMap = Dictionary(uniqueKeysWithValues: cache.timeTable.map { ($0.id, $0) })
        
        var results: [CourseReminderOccurrence] = []

        // 处理常规课程
        if let firstDay = cache.firstDay {
            for course in cache.courses {
                for week in course.weeks {
                    guard let startSlot = slotMap[course.startSection],
                          let endSlot = slotMap[course.endSection],
                          let start = combine(firstDay: firstDay, week: week, weekday: course.weekday, time: startSlot.start),
                          let end = combine(firstDay: firstDay, week: week, weekday: course.weekday, time: endSlot.end),
                          end > now else { continue }
                    
                    results.append(CourseReminderOccurrence(
                        kindText: "上课",
                        title: normalizeCourseTitle(course.name),
                        classroom: normalizeClassroom(course.classroom),
                        teacher: course.teacher,
                        startDate: start,
                        endDate: end
                    ))
                }
            }
        }

        // 处理自定义日程
        for schedule in cache.customSchedules {
            guard let date = ScheduleDateCodec.parseDate(schedule.dateString),
                  let start = combine(date: date, time: schedule.beginTime),
                  let end = combine(date: date, time: schedule.endTime),
                  end > now else { continue }
            
            results.append(CourseReminderOccurrence(
                kindText: "日程",
                title: schedule.title,
                classroom: schedule.subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
                teacher: "",
                startDate: start,
                endDate: end
            ))
        }

        return results.sorted { $0.startDate < $1.startDate }
    }

    /// 把“首周日期 + 教学周 + 星期 + 节次时间”换算成真实日期时间。
    private func combine(firstDay: Date, week: Int, weekday: Int, time: String) -> Date? {
        let offset = (week - 1) * 7 + (weekday - 1)
        guard let day = Calendar.current.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
        return combine(date: day, time: time)
    }

    /// 把某一天和 `HH:mm` 形式的时间文本合成一个绝对时间点。
    private func combine(date: Date, time: String) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = parts[0]
        components.minute = parts[1]
        components.second = 0
        return Calendar.current.date(from: components)
    }

    private func normalizeClassroom(_ value: String) -> String {
        value.replacingOccurrences(of: "理教楼", with: "理教").replacingOccurrences(of: "文萃楼", with: "文萃")
    }

    private func normalizeCourseTitle(_ value: String) -> String {
        value.hasPrefix("体育/") ? String(value.dropFirst(3)) : value
    }

    /// 计算某条提醒的实际显示起点。
    ///
    /// 默认规则是“开课前 `leadMinutes` 分钟开始提醒”。但如果上一条课/日程尚未结束，
    /// 并且下一条已经落入提醒窗口，则会把起点后移到“上一条结束前 5 分钟”，避免
    /// 在还在上上一节课时过早弹出下一节提醒。
    private func effectiveDisplayWindowStart(
        for occurrence: CourseReminderOccurrence,
        among occurrences: [CourseReminderOccurrence],
        leadMinutes: Int
    ) -> Date {
        let naturalStart = occurrence.startDate.addingTimeInterval(Double(-leadMinutes * 60))
        let reminderLeadOutFromPrevious: TimeInterval = 5 * 60

        guard let previous = occurrences.last(where: { candidate in
            candidate.startDate < occurrence.startDate && candidate.endDate > naturalStart
        }) else {
            return naturalStart
        }

        let adjustedStart = previous.endDate.addingTimeInterval(-reminderLeadOutFromPrevious)
        return max(naturalStart, adjustedStart)
    }

    /// 统一创建 activity，避免多个分支重复写同一套 request + logging。
    private func requestActivity(
        attributes: CourseReminderActivityAttributes,
        content: ActivityContent<CourseReminderActivityAttributes.ContentState>,
        reason: StaticString
    ) async {
        logger.debug(
            "requesting new activity reason=\(reason) state=\(Self.describe(content.state), privacy: .public)"
        )
        _ = try? Activity.request(attributes: attributes, content: content)
    }

    private static func describe(_ state: CourseReminderActivityAttributes.ContentState) -> String {
        "\(state.kindText) | \(state.title) | \(state.classroom) | \(state.timeRangeText) | target=\(debugDateFormatter.string(from: state.countdownTargetDate))"
    }

    private static func timeRangeText(start: Date, end: Date) -> String {
        "\(displayTimeFormatter.string(from: start))-\(displayTimeFormatter.string(from: end))"
    }

    private static let displayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
