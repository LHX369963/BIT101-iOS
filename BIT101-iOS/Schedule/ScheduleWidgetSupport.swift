//
//  ScheduleWidgetSupport.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-28.
//

import Foundation
import WidgetKit

/// 把当前账号课表缓存导出给外部展示层的桥接器。
///
/// 当前桌面/锁屏 widget 会直接使用这份快照；
/// 后续接入 watch 时，也应优先沿用这里，而不是重新从主 app 内部状态机抠字段。
enum ScheduleWidgetExporter {
    /// 重新读取当前账号缓存，并同步到共享容器。
    ///
    /// 这个入口给应用生命周期、登录切换等“没有直接拿到最新缓存对象”的场景使用。
    static func syncFromCurrentCache() {
        sync(cache: ScheduleCacheStore.load())
    }

    /// 把指定缓存同步给外部展示层，并主动刷新 widget 时间线。
    ///
    /// 这里刻意只导出课表、小节次和首周信息，不把主 app 内部复杂状态直接暴露出去，
    /// 保持共享层最小化，方便后续继续扩展到 watch 等新 target。
    static func sync(cache: ScheduleCache) {
        let studentID = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLoggedIn = !LoginStorage.shared.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let snapshot = ScheduleExternalSnapshot(
            isLoggedIn: isLoggedIn,
            studentID: studentID,
            firstDayString: cache.firstDayString,
            timeTable: cache.timeTable.map {
                ScheduleExternalTimeSlotSnapshot(id: $0.id, start: $0.start, end: $0.end)
            },
            courses: cache.courses.map {
                ScheduleExternalCourseSnapshot(
                    id: $0.id,
                    name: $0.name,
                    classroom: $0.classroom,
                    teacher: $0.teacher,
                    weeks: $0.weeks,
                    weekday: $0.weekday,
                    startSection: $0.startSection,
                    endSection: $0.endSection
                )
            }
        )
        ScheduleExternalSnapshotStore.save(snapshot)
        WatchScheduleSyncManager.shared.push(snapshot: snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
