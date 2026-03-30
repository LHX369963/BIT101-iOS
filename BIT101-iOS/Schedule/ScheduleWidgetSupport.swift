//
//  ScheduleWidgetSupport.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-28.
//

import Foundation
import WidgetKit

/// 课表小组件与主 App 共享的 App Group 标识。
///
/// 小组件无法直接读取主 App 沙盒内的缓存，因此需要通过共享容器同步一份精简课表快照。
enum ScheduleWidgetSharedContainer {
    static let identifier = "group.BIT101-dev.BIT101-iOS.shared"
}

/// 写入小组件共享容器的精简节次模型。
///
/// 只保留 widget 时间线真正需要的时段字段，避免把整个 `TimeSlot` 连同其它上下文都带进共享快照。
struct ScheduleWidgetTimeSlotSnapshot: Codable {
    let id: Int
    let start: String
    let end: String
}

/// 写入小组件共享容器的精简课程模型。
///
/// 小组件目前只展示“下一节/后续几节课”，所以只导出排课、标题和地点相关字段。
struct ScheduleWidgetCourseSnapshot: Codable {
    let id: String
    let name: String
    let classroom: String
    let teacher: String
    let weeks: [Int]
    let weekday: Int
    let startSection: Int
    let endSection: Int
}

/// 提供给小组件时间线使用的共享课表快照。
///
/// 这是主 App 与 widget extension 之间的数据契约。只要它稳定，两侧就可以独立演进视图实现。
struct ScheduleWidgetSnapshot: Codable {
    let firstDayString: String
    let timeTable: [ScheduleWidgetTimeSlotSnapshot]
    let courses: [ScheduleWidgetCourseSnapshot]
}

/// 小组件共享快照的磁盘仓库。
///
/// 主 App 负责写入，小组件负责读取。
enum ScheduleWidgetSnapshotStore {
    private static let fileName = "schedule-widget-snapshot.json"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// 把共享快照写入 App Group 容器。
    static func save(_ snapshot: ScheduleWidgetSnapshot) {
        guard let fileURL else { return }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("Failed to save schedule widget snapshot: \(error)")
        }
    }

    /// 清空共享快照文件。
    static func clear() {
        guard let fileURL else { return }

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            print("Failed to clear schedule widget snapshot: \(error)")
        }
    }

    /// App Group 中用于保存 widget 快照的文件路径。
    private static var fileURL: URL? {
        guard
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ScheduleWidgetSharedContainer.identifier
            )
        else {
            return nil
        }

        return containerURL
            .appending(path: "Widgets", directoryHint: .isDirectory)
            .appending(path: fileName)
    }
}

/// 把当前账号课表缓存导出给小组件的桥接器。
enum ScheduleWidgetExporter {
    /// 重新读取当前账号缓存，并同步到共享容器。
    static func syncFromCurrentCache() {
        sync(cache: ScheduleCacheStore.load())
    }

    /// 把指定缓存同步给小组件，并主动刷新时间线。
    ///
    /// 这里故意只导出课表、小节次和首周信息，不把 DDL / 自定义日程 /
    /// 其它界面设置一起带进 widget，保持共享快照最小化。
    static func sync(cache: ScheduleCache) {
        let snapshot = ScheduleWidgetSnapshot(
            firstDayString: cache.firstDayString,
            timeTable: cache.timeTable.map {
                ScheduleWidgetTimeSlotSnapshot(id: $0.id, start: $0.start, end: $0.end)
            },
            courses: cache.courses.map {
                ScheduleWidgetCourseSnapshot(
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
        ScheduleWidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 清空共享快照，并通知小组件更新空态。
    static func clear() {
        ScheduleWidgetSnapshotStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
