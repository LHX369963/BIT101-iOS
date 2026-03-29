//
//  ScheduleModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// 本地缓存发生变化时发出的通知。
extension Notification.Name {
    static let scheduleCacheDidChange = Notification.Name("BIT101.ScheduleCacheDidChange")
}

/// 日程页的一级分栏。
enum ScheduleSection: String, CaseIterable, Identifiable {
    case courses
    case ddl
    case classroom

    /// 供分段控件和手势切换使用的稳定标识。
    var id: String { rawValue }

    /// 顶部分段控件展示的标题。
    var title: String {
        switch self {
        case .courses:
            return "课表"
        case .ddl:
            return "DDL"
        case .classroom:
            return "空教室"
        }
    }
}

/// 节次与时间段的映射。
struct TimeSlot: Codable, Hashable, Identifiable {
    let id: Int
    let start: String
    let end: String

    /// 节次开始时间对应的分钟数，便于当前时间线比较。
    var startMinutes: Int {
        TimeSlot.parseMinutes(start)
    }

    /// 节次结束时间对应的分钟数。
    var endMinutes: Int {
        TimeSlot.parseMinutes(end)
    }

    /// 节次区间的可读文本。
    var rangeText: String {
        "\(start)-\(end)"
    }

    static let `default`: [TimeSlot] = [
        TimeSlot(id: 1, start: "08:00", end: "08:45"),
        TimeSlot(id: 2, start: "08:50", end: "09:35"),
        TimeSlot(id: 3, start: "09:55", end: "10:40"),
        TimeSlot(id: 4, start: "10:45", end: "11:30"),
        TimeSlot(id: 5, start: "11:35", end: "12:20"),
        TimeSlot(id: 6, start: "13:20", end: "14:05"),
        TimeSlot(id: 7, start: "14:10", end: "14:55"),
        TimeSlot(id: 8, start: "15:15", end: "16:00"),
        TimeSlot(id: 9, start: "16:05", end: "16:50"),
        TimeSlot(id: 10, start: "16:55", end: "17:40"),
        TimeSlot(id: 11, start: "18:30", end: "19:15"),
        TimeSlot(id: 12, start: "19:20", end: "20:05"),
        TimeSlot(id: 13, start: "20:10", end: "20:55"),
    ]

    /// 把 `HH:mm` 字符串解析成分钟数。
    static func parseMinutes(_ string: String) -> Int {
        let parts = string.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return 0
        }
        return hour * 60 + minute
    }

    /// 把分钟数格式化回 `HH:mm` 文本。
    static func formatMinutes(_ minutes: Int) -> String {
        let clamped = max(minutes, 0)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}

/// 课表课程记录。
struct CourseRecord: Codable, Identifiable, Hashable {
    let id: String
    let term: String
    let name: String
    let teacher: String
    let classroom: String
    let description: String
    let weeks: [Int]
    let weekday: Int
    let startSection: Int
    let endSection: Int
    let campus: String
    let number: String
    let credit: Int
    let hour: Int
    let type: String
    let category: String
    let department: String

    /// 课程占用的节次文本。
    var sectionText: String {
        "第\(startSection)-\(endSection)节"
    }

    /// 根据当前时间表配置，把节次映射成具体的起止时间。
    func timeText(using timeTable: [TimeSlot]) -> String {
        guard
            let start = timeTable.first(where: { $0.id == startSection }),
            let end = timeTable.first(where: { $0.id == endSection })
        else {
            return sectionText
        }

        return "\(start.start)-\(end.end)"
    }
}

/// 考试记录。
struct ExamRecord: Codable, Identifiable, Hashable {
    let id: String
    let term: String
    let name: String
    let courseID: String
    let teacher: String
    let classroom: String
    let dateString: String
    let beginTime: String
    let endTime: String
    let examMode: String
    let seatID: String
}

/// DDL 列表项。
///
/// 乐学同步数据和手动新建数据都落成这一种本地记录。
struct DDLEventRecord: Codable, Identifiable, Hashable {
    let id: String
    var group: String
    var title: String
    var text: String
    var dueAt: Date
    var done: Bool
}

/// 手动新增 / 编辑 DDL 时使用的草稿模型。
struct DDLDraft: Equatable {
    var title = ""
    var dueAt = Date()
    var text = ""
}

/// 自定义课程块记录。
struct CustomScheduleRecord: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var subtitle: String
    var description: String
    var dateString: String
    var beginTime: String
    var endTime: String
}

/// 自定义课程块编辑草稿。
struct CustomScheduleDraft: Equatable {
    var title = ""
    var subtitle = ""
    var description = ""
    var date = Date()
    var beginTime = Date()
    var endTime = Date()
}

/// 空教室查询使用的校区记录。
struct CampusRecord: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let code: String
}

/// 空教室查询使用的教学楼记录。
struct BuildingRecord: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let buildingCode: String
    let campusName: String
    let campusCode: String
}

/// 空教室接口原始教室记录。
struct ClassroomRecord: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let busyTimeCodes: [Int]
}

/// 供界面展示的教室空闲状态。
struct ClassroomAvailability: Identifiable, Hashable {
    let id: String
    let name: String
    let prettyFreeTimes: String
    let statusText: String
    let detailText: String
    let isFreeNow: Bool
    let freeSections: [Int]
}

/// 日程模块本地缓存。
struct ScheduleCache: Codable {
    var currentTerm: String = ""
    var firstDayString: String = ""
    var lexueCalendarURL: String = ""
    var courses: [CourseRecord] = []
    var exams: [ExamRecord] = []
    var customSchedules: [CustomScheduleRecord] = []
    var ddlEvents: [DDLEventRecord] = []
    var ddlBeforeDay = 7
    var ddlAfterDay = 3
    var selectedCampusName: String = ""
    var selectedCampusCode: String = ""
    var selectedClassroomSectionIDs: [Int] = []
    var showSaturday = true
    var showSunday = true
    var showBorder = true
    var showHighlightToday = true
    var showDivider = true
    var showCurrentTime = true
    var showExamInfo = true
    var showCourseLiveActivityReminder = false
    var courseLiveActivityLeadMinutes = 20
    var timeTable: [TimeSlot] = TimeSlot.default

    /// 首周日期的解码结果，便于课表直接计算当前周数。
    var firstDay: Date? {
        ScheduleDateCodec.parseDate(firstDayString)
    }

    private enum CodingKeys: String, CodingKey {
        case currentTerm
        case firstDayString
        case lexueCalendarURL
        case courses
        case exams
        case customSchedules
        case ddlEvents
        case ddlBeforeDay
        case ddlAfterDay
        case selectedCampusName
        case selectedCampusCode
        case selectedClassroomSectionIDs
        case showSaturday
        case showSunday
        case showBorder
        case showHighlightToday
        case showDivider
        case showCurrentTime
        case showExamInfo
        case showCourseLiveActivityReminder
        case courseLiveActivityLeadMinutes
        case timeTable
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        currentTerm = try container.decodeIfPresent(String.self, forKey: .currentTerm) ?? ""
        firstDayString = try container.decodeIfPresent(String.self, forKey: .firstDayString) ?? ""
        lexueCalendarURL = try container.decodeIfPresent(String.self, forKey: .lexueCalendarURL) ?? ""
        courses = try container.decodeIfPresent([CourseRecord].self, forKey: .courses) ?? []
        exams = try container.decodeIfPresent([ExamRecord].self, forKey: .exams) ?? []
        customSchedules = try container.decodeIfPresent([CustomScheduleRecord].self, forKey: .customSchedules) ?? []
        ddlEvents = try container.decodeIfPresent([DDLEventRecord].self, forKey: .ddlEvents) ?? []
        ddlBeforeDay = try container.decodeIfPresent(Int.self, forKey: .ddlBeforeDay) ?? 7
        ddlAfterDay = try container.decodeIfPresent(Int.self, forKey: .ddlAfterDay) ?? 3
        selectedCampusName = try container.decodeIfPresent(String.self, forKey: .selectedCampusName) ?? ""
        selectedCampusCode = try container.decodeIfPresent(String.self, forKey: .selectedCampusCode) ?? ""
        selectedClassroomSectionIDs = try container.decodeIfPresent([Int].self, forKey: .selectedClassroomSectionIDs) ?? []
        showSaturday = try container.decodeIfPresent(Bool.self, forKey: .showSaturday) ?? true
        showSunday = try container.decodeIfPresent(Bool.self, forKey: .showSunday) ?? true
        showBorder = try container.decodeIfPresent(Bool.self, forKey: .showBorder) ?? true
        showHighlightToday = try container.decodeIfPresent(Bool.self, forKey: .showHighlightToday) ?? true
        showDivider = try container.decodeIfPresent(Bool.self, forKey: .showDivider) ?? true
        showCurrentTime = try container.decodeIfPresent(Bool.self, forKey: .showCurrentTime) ?? true
        showExamInfo = try container.decodeIfPresent(Bool.self, forKey: .showExamInfo) ?? true
        showCourseLiveActivityReminder = try container.decodeIfPresent(Bool.self, forKey: .showCourseLiveActivityReminder) ?? false
        courseLiveActivityLeadMinutes = try container.decodeIfPresent(Int.self, forKey: .courseLiveActivityLeadMinutes) ?? 20
        timeTable = try container.decodeIfPresent([TimeSlot].self, forKey: .timeTable) ?? TimeSlot.default
    }
}

/// 课程表和 DDL 共用的日期编解码工具。
enum ScheduleDateCodec {
    /// 固定使用公历，避免系统日历设置影响周数计算。
    static let calendar = Calendar(identifier: .gregorian)

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd"
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

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
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

    private static let relativeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    static func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        return dateFormatter.date(from: string)
    }

    static func parseTime(_ string: String) -> Date? {
        timeFormatter.date(from: string)
    }

    static func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func formatShortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    static func formatDateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    static func formatRelativeDateTime(_ date: Date) -> String {
        relativeFormatter.string(from: date)
    }

    static func minutesOfDay(from string: String) -> Int {
        TimeSlot.parseMinutes(string)
    }

    static func weekdayIndex(from date: Date) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return ((weekday + 5) % 7) + 1
    }

    static func minutesOfDay(from date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

/// 日程模块本地缓存仓库。
///
/// 统一负责 `ScheduleCache` 的磁盘读写和变更通知发送。
enum ScheduleCacheStore {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = root
            .appending(path: "BIT101-iOS", directoryHint: .isDirectory)
            .appending(path: currentAccountIdentifier(), directoryHint: .isDirectory)
        return directory.appending(path: "schedule-cache.json")
    }

    private static func currentAccountIdentifier() -> String {
        let raw = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return "__default__"
        }

        let invalid = CharacterSet.alphanumerics.inverted
        return raw.components(separatedBy: invalid).joined(separator: "_")
    }

    static func load() -> ScheduleCache {
        guard
            let data = try? Data(contentsOf: fileURL),
            let cache = try? decoder.decode(ScheduleCache.self, from: data)
        else {
            return ScheduleCache()
        }

        return cache
    }

    static func save(_ cache: ScheduleCache) {
        let url = fileURL
        let directory = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(cache)
            try data.write(to: url, options: [.atomic])
            ScheduleWidgetExporter.sync(cache: cache)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .scheduleCacheDidChange, object: nil)
            }
        } catch {
            print("Failed to save schedule cache: \(error)")
        }
    }

    static func clear() {
        let url = fileURL
        let directory = url.deletingLastPathComponent()

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }

            if FileManager.default.fileExists(atPath: directory.path),
               (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try FileManager.default.removeItem(at: directory)
            }

            ScheduleWidgetExporter.syncFromCurrentCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .scheduleCacheDidChange, object: nil)
            }
        } catch {
            print("Failed to clear schedule cache: \(error)")
        }
    }
}
