//
//  BIT101ScheduleWidgetBundle.swift
//  BIT101ScheduleWidget
//
//  Created by Codex on 2026-03-28.
//

import SwiftUI
import WidgetKit

/// 课程表小组件入口。
///
/// 当前扩展同时承载桌面 widget 和课程提醒 Live Activity，
/// 因此 bundle 里会按系统版本条件挂出两个入口。
@main
struct BIT101ScheduleWidgetBundle: WidgetBundle {
    /// 扩展内实际暴露给系统的全部 widget。
    var body: some Widget {
        BIT101ScheduleWidget()
        if #available(iOSApplicationExtension 16.2, *) {
            CourseReminderLiveActivityWidget()
        }
    }
}
