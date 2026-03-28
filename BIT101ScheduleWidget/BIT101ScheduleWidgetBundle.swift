//
//  BIT101ScheduleWidgetBundle.swift
//  BIT101ScheduleWidget
//
//  Created by Codex on 2026-03-28.
//

import SwiftUI
import WidgetKit

/// 课程表小组件入口。
@main
struct BIT101ScheduleWidgetBundle: WidgetBundle {
    var body: some Widget {
        BIT101ScheduleWidget()
        if #available(iOSApplicationExtension 16.2, *) {
            CourseReminderLiveActivityWidget()
        }
    }
}
