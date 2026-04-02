//
//  ScheduleViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

private extension Int {
    func modulo(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remainder = self % count
        return remainder >= 0 ? remainder : remainder + count
    }
}

/// 日程页统一使用的提示模型。
///
/// 日程模块内部的同步、保存、空教室查询等动作都会通过这个统一提示模型把错误抛给视图层。
struct ScheduleNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
/// 日程模块状态机。
///
/// 负责：
/// 1. 本地缓存恢复
/// 2. 课表 / DDL / 空教室同步
/// 3. 自定义日程和自定义 DDL 的本地 CRUD
/// 4. 与设置中心共享缓存后的自动刷新
final class ScheduleViewModel: ObservableObject {
    /// 课表页当前正在显示的课表分身。
    ///
    /// 主课表仍然来自当前账号缓存；导入的课表则作为只读分身挂在后面，供上下滑循环切换。
    struct CourseScheduleVariant: Identifiable, Equatable {
        let id: String
        let title: String
        let isPrimary: Bool
        let currentTerm: String
        let firstDayString: String
        let timeTable: [TimeSlot]
        let courses: [CourseRecord]
        let exams: [ExamRecord]
        let customSchedules: [CustomScheduleRecord]

        var firstDay: Date? {
            ScheduleDateCodec.parseDate(firstDayString)
        }

        var hasCourseData: Bool {
            !courses.isEmpty || !exams.isEmpty
        }
    }

    /// 当前选中的一级分栏。
    @Published var selectedSection: ScheduleSection = .courses
    /// 当前账号的日程缓存快照。
    @Published private(set) var cache = ScheduleCache()
    /// 是否正在做首次本地缓存恢复。
    @Published private(set) var isLoadingCache = true
    /// 是否正在同步课表/考试。
    @Published private(set) var isSyncingCourses = false
    /// 是否正在同步乐学 DDL。
    @Published private(set) var isSyncingDDL = false
    /// 是否正在加载空教室元数据（校区/教学楼）。
    @Published private(set) var isLoadingClassroomMeta = false
    /// 是否正在加载空教室结果。
    @Published private(set) var isLoadingClassrooms = false
    @Published private(set) var campuses: [CampusRecord] = []
    @Published private(set) var buildings: [BuildingRecord] = []
    @Published private(set) var classroomAvailabilities: [ClassroomAvailability] = []
    @Published var selectedWeek = 1
    @Published var selectedCourseScheduleIndex = 0
    @Published var selectedBuildingID = ""
    @Published var notice: ScheduleNotice?

    private let service: ScheduleService
    private var hasLoaded = false
    /// 当前教学楼最近一次拉下来的原始空教室记录。
    private var classroomRecords: [ClassroomRecord] = []
    /// 监听设置和缓存变化，用于跨页面同步。
    private var cacheObserver: NSObjectProtocol?

    /// 初始化日程状态机，并监听缓存变化通知。
    init(service: ScheduleService) {
        self.service = service
        cacheObserver = NotificationCenter.default.addObserver(
            forName: .scheduleCacheDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                // 设置中心修改课表显示项后，这里直接从磁盘重载，避免页面和设置页双向手搓同步。
                self.reloadFromDisk()
            }
        }
    }

    convenience init() {
        self.init(service: ScheduleService())
    }

    deinit {
        if let cacheObserver {
            NotificationCenter.default.removeObserver(cacheObserver)
        }
    }

    /// 构造日程模块统一使用的本地校验错误。
    ///
    /// 这类错误都属于“用户输入不合法”或“本地配置格式不正确”，
    /// 不需要为每个分支再重复写一遍相同的 domain / code。
    private func scheduleValidationError(_ message: String) -> NSError {
        NSError(
            domain: "BIT101.Schedule",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// DDL 列表默认向前展示的天数。
    var beforeDay: Int { cache.ddlBeforeDay }
    /// DDL 列表默认向后保留的天数。
    var afterDay: Int { cache.ddlAfterDay }

    /// 首周日期的展示文本。
    var firstDayDescription: String {
        guard let firstDay = activeCourseSchedule.firstDay else {
            return "未同步"
        }
        return ScheduleDateCodec.formatDate(firstDay)
    }

    /// 当前显示课表的标题。
    var activeCourseScheduleTitle: String {
        activeCourseSchedule.title
    }

    /// 当前学期最大周数，至少覆盖当前周。
    var maxWeek: Int {
        max(activeCourseSchedule.courses.flatMap(\.weeks).max() ?? 1, resolvedCurrentWeek())
    }

    /// 是否已经同步到任何课程或考试数据。
    var hasCourseData: Bool {
        activeCourseSchedule.hasCourseData
    }

    /// 所有可切换的课表列表。
    ///
    /// 顺序固定为：我的课表在前，导入的分享课表依次排在后面。
    var courseSchedules: [CourseScheduleVariant] {
        let primary = CourseScheduleVariant(
            id: "__primary__",
            title: cache.primaryScheduleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "课表" : cache.primaryScheduleTitle,
            isPrimary: true,
            currentTerm: cache.currentTerm,
            firstDayString: cache.firstDayString,
            timeTable: cache.timeTable,
            courses: cache.courses,
            exams: cache.exams,
            customSchedules: cache.customSchedules
        )

        let shared = cache.sharedSchedules.map { record in
            CourseScheduleVariant(
                id: record.id,
                title: record.title,
                isPrimary: false,
                currentTerm: record.currentTerm,
                firstDayString: record.firstDayString,
                timeTable: record.timeTable,
                courses: record.courses,
                exams: [],
                customSchedules: []
            )
        }

        return [primary] + shared
    }

    /// 当前正在展示的那一份课表。
    var activeCourseSchedule: CourseScheduleVariant {
        let variants = courseSchedules
        guard !variants.isEmpty else {
            return CourseScheduleVariant(
                id: "__primary__",
                title: "我的课表",
                isPrimary: true,
                currentTerm: "",
                firstDayString: "",
                timeTable: cache.timeTable,
                courses: [],
                exams: [],
                customSchedules: []
            )
        }

        let normalizedIndex = min(max(selectedCourseScheduleIndex, 0), variants.count - 1)
        return variants[normalizedIndex]
    }

    /// 是否已经拿到乐学订阅地址。
    var hasLexueCalendarURL: Bool {
        !cache.lexueCalendarURL.isEmpty
    }

    /// 经过时间窗口裁剪后的 DDL 列表。
    var visibleDDLEvents: [DDLEventRecord] {
        let threshold = Date().addingTimeInterval(TimeInterval(-afterDay * 24 * 3600))
        return cache.ddlEvents
            .filter { $0.dueAt >= threshold }
            .sorted { lhs, rhs in
                if lhs.done != rhs.done {
                    return !lhs.done
                }
                return lhs.dueAt < rhs.dueAt
            }
    }

    /// 首次进入日程页时从本地磁盘恢复缓存。
    ///
    /// 日程页优先展示本地缓存，而不是一上来就强制联网同步；这样冷启动更快，也更稳定。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        // 页面先读本地缓存，确保一打开就有内容，避免每次冷启动都重新同步。
        reloadFromDisk()
        isLoadingCache = false
    }

    /// 同步课程表、考试安排和首周日期。
    ///
    /// 同步成功后会立刻更新本地缓存，从而驱动课表页、小组件和灵动岛一起刷新。
    func syncCourses() async {
        isSyncingCourses = true
        defer { isSyncingCourses = false }

        do {
            let payload = try await service.syncCourses()
            cache.currentTerm = payload.term
            cache.firstDayString = payload.firstDayString
            cache.courses = payload.courses
            cache.exams = payload.exams
            selectedWeek = min(max(resolvedCurrentWeek(), 1), maxWeek)
            persist()
        } catch {
            notice = ScheduleNotice(title: "课表同步失败", message: error.localizedDescription)
        }
    }

    /// 同步乐学 DDL，并保留本地手动项目和完成状态。
    func syncDDL(showSuccessNotice: Bool = true) async {
        isSyncingDDL = true
        defer { isSyncingDDL = false }

        do {
            // 手动创建的 DDL 与乐学同步内容并存；同步时要保留手动项目和 done 状态。
            let manualEvents = cache.ddlEvents.filter { $0.group != "lexue" }
            let payload = try await service.syncDDLEvents(
                existingEvents: cache.ddlEvents,
                storedURL: cache.lexueCalendarURL
            )
            cache.lexueCalendarURL = payload.url
            cache.ddlEvents = (manualEvents + payload.events).sorted { $0.dueAt < $1.dueAt }
            persist()
            if showSuccessNotice {
                notice = ScheduleNotice(
                    title: "DDL 同步成功",
                    message: payload.events.isEmpty ? "已更新成功，当前没有乐学日程。" : "已更新成功，共同步 \(payload.events.count) 条乐学日程。"
                )
            }
        } catch {
            notice = ScheduleNotice(title: "DDL 同步失败", message: error.localizedDescription)
        }
    }

    /// 强制重新抓取乐学日历订阅地址。
    ///
    /// 主要用在订阅链接失效或用户主动要求重置时。
    func refreshLexueCalendarURL(showSuccessNotice: Bool = true) async {
        isSyncingDDL = true
        defer { isSyncingDDL = false }

        do {
            cache.lexueCalendarURL = try await service.refreshLexueCalendarURL()
            persist()
            if showSuccessNotice {
                notice = ScheduleNotice(title: "订阅链接更新成功", message: "已重新获取乐学订阅链接。")
            }
        } catch {
            notice = ScheduleNotice(title: "订阅链接获取失败", message: error.localizedDescription)
        }
    }

    /// 切换某条 DDL 的完成状态。
    ///
    /// `done` 是纯本地状态，不会回写乐学网页端。
    func toggleDDLDone(_ event: DDLEventRecord) {
        guard let index = cache.ddlEvents.firstIndex(where: { $0.id == event.id }) else {
            return
        }

        cache.ddlEvents[index].done.toggle()
        persist()
    }

    /// 把已有 DDL 记录转成编辑草稿。
    func ddlDraft(for event: DDLEventRecord?) -> DDLDraft {
        guard let event else { return DDLDraft() }
        return DDLDraft(title: event.title, dueAt: event.dueAt, text: event.text)
    }

    /// 新增一条本地 DDL。
    ///
    /// 手动 DDL 与乐学同步项并存，但会用 `group` 字段区分来源。
    func addDDL(_ draft: DDLDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw scheduleValidationError("标题不能为空。")
        }

        cache.ddlEvents.append(
            DDLEventRecord(
                id: UUID().uuidString,
                group: "main",
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                text: draft.text,
                dueAt: draft.dueAt,
                done: false
            )
        )
        cache.ddlEvents.sort { $0.dueAt < $1.dueAt }
        persist()
    }

    /// 更新一条已有的本地 DDL。
    func updateDDL(id: String, draft: DDLDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw scheduleValidationError("标题不能为空。")
        }
        guard let index = cache.ddlEvents.firstIndex(where: { $0.id == id }) else { return }

        cache.ddlEvents[index].title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        cache.ddlEvents[index].text = draft.text
        cache.ddlEvents[index].dueAt = draft.dueAt
        persist()
    }

    /// 删除指定 DDL。
    func deleteDDL(id: String) {
        cache.ddlEvents.removeAll { $0.id == id }
        persist()
    }

    /// 修改 DDL 提前提醒窗口。
    func setDDLBeforeDay(_ value: Int) {
        cache.ddlBeforeDay = max(value, 0)
        persist()
    }

    /// 修改 DDL 过期后仍保留显示的窗口。
    func setDDLAfterDay(_ value: Int) {
        cache.ddlAfterDay = max(value, 0)
        persist()
    }

    /// 课表周次左移一周。
    func previousWeek() {
        selectedWeek = max(1, selectedWeek - 1)
    }

    /// 课表周次右移一周。
    func nextWeek() {
        selectedWeek = min(maxWeek, selectedWeek + 1)
    }

    /// 把周次快速重置到当前周。
    func resetToCurrentWeek() {
        selectedWeek = min(max(resolvedCurrentWeek(), 1), maxWeek)
    }

    /// 在“我的课表”和导入课表之间循环切换。
    ///
    /// 这里故意做成 loop 语义：无论向上还是向下滑，到边界后都回卷。
    func cycleCourseSchedule(step: Int) {
        let variants = courseSchedules
        guard variants.count > 1 else { return }

        let count = variants.count
        let nextIndex = (selectedCourseScheduleIndex + step).modulo(count)
        selectedCourseScheduleIndex = nextIndex
        selectedWeek = min(max(selectedWeek, 1), maxWeek)
    }

    /// 重命名当前账号自己的课表。
    func renamePrimarySchedule(to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw scheduleValidationError("课表名称不能为空。")
        }
        guard trimmed.count <= scheduleNameCharacterLimit else {
            throw scheduleValidationError("课表名称最多 8 个字符。")
        }
        cache.primaryScheduleTitle = trimmed
        persist()
    }

    /// 重命名一份导入的分享课表。
    func renameSharedSchedule(id: String, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw scheduleValidationError("课表名称不能为空。")
        }
        guard trimmed.count <= scheduleNameCharacterLimit else {
            throw scheduleValidationError("课表名称最多 8 个字符。")
        }
        guard let index = cache.sharedSchedules.firstIndex(where: { $0.id == id }) else { return }
        cache.sharedSchedules[index].title = trimmed
        persist()
    }

    /// 删除一份导入的分享课表。
    func deleteSharedSchedule(id: String) {
        cache.sharedSchedules.removeAll { $0.id == id }
        selectedCourseScheduleIndex = min(selectedCourseScheduleIndex, max(courseSchedules.count - 1, 0))
        persist()
    }

    /// 设置是否显示周六课程。
    func setShowSaturday(_ value: Bool) {
        cache.showSaturday = value
        persist()
    }

    /// 设置是否显示周日课程。
    func setShowSunday(_ value: Bool) {
        cache.showSunday = value
        persist()
    }

    /// 设置课程块边框显示。
    func setShowBorder(_ value: Bool) {
        cache.showBorder = value
        persist()
    }

    /// 设置是否高亮今天对应的课程列。
    func setShowHighlightToday(_ value: Bool) {
        cache.showHighlightToday = value
        persist()
    }

    /// 设置是否显示课表网格分割线。
    func setShowDivider(_ value: Bool) {
        cache.showDivider = value
        persist()
    }

    /// 设置是否显示当前时间线。
    func setShowCurrentTime(_ value: Bool) {
        cache.showCurrentTime = value
        persist()
    }

    /// 设置是否在课表网格中显示考试块。
    func setShowExamInfo(_ value: Bool) {
        cache.showExamInfo = value
        persist()
    }

    /// 设置是否启用课程提醒 Live Activity。
    func setShowCourseLiveActivityReminder(_ value: Bool) {
        cache.showCourseLiveActivityReminder = value
        persist()

        if value {
            Task { [weak self] in
                let granted = await ScheduleLiveActivityManager.shared.requestNotificationAuthorizationIfNeeded()
                if !granted {
                    self?.notice = ScheduleNotice(
                        title: "通知未开启",
                        message: "灵动岛需要应用常驻前台；应用未能自动启动时，会使用本地通知，以避免您错过上课。请在系统设置中允许 BIT101 发送通知。"
                    )
                }
                await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(trigger: "reminder_toggle_enabled")
            }
        }
    }

    /// 设置灵动岛/锁屏提醒的提前显示阈值。
    func setCourseLiveActivityLeadMinutes(_ value: Int) {
        cache.courseLiveActivityLeadMinutes = min(max(value, 1), 60)
        persist()
    }

    /// 从多行文本解析并替换整份时间表。
    ///
    /// 每行格式固定为 `开始时间,结束时间`；这里会同时校验顺序和重叠。
    func setTimeTable(from text: String) throws {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var timeTable: [TimeSlot] = []
        for (index, line) in lines.enumerated() {
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                throw scheduleValidationError("时间表格式错误。")
            }

            let start = parts[0]
            let end = parts[1]
            let startMinutes = TimeSlot.parseMinutes(start)
            let endMinutes = TimeSlot.parseMinutes(end)
            guard endMinutes > startMinutes else {
                throw scheduleValidationError("时间表格式错误。")
            }
            if let last = timeTable.last, startMinutes <= last.endMinutes {
                throw scheduleValidationError("时间表格式错误。")
            }

            timeTable.append(TimeSlot(id: index + 1, start: start, end: end))
        }

        guard !timeTable.isEmpty else {
            throw scheduleValidationError("时间表格式错误。")
        }

        cache.timeTable = timeTable
        persist()
    }

    /// 生成新增课程用的默认草稿。
    ///
    /// 周次默认留空，避免把“当前周”误当成用户真正想填的周次范围。
    /// 节次则给一个最常见的双节课起点。
    func courseDraft(for week: Int) -> CourseDraft {
        CourseDraft(
            weekday: 1,
            startSection: 1,
            endSection: min(2, max(cache.timeTable.count, 1)),
            weeksText: ""
        )
    }

    /// 新增一条本地课程。
    ///
    /// 这里不会回写学校接口，而是只修改本地缓存，用于补录临时课程或手动修正。
    func addCourse(_ draft: CourseDraft) throws {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw scheduleValidationError("课程名称不能为空。")
        }

        let weeks = try parseWeeksText(draft.weeksText)
        guard draft.startSection > 0, draft.endSection >= draft.startSection else {
            throw scheduleValidationError("节次范围不合法。")
        }

        cache.courses.append(
            CourseRecord(
                id: UUID().uuidString,
                term: cache.currentTerm,
                name: title,
                teacher: draft.teacher.trimmingCharacters(in: .whitespacesAndNewlines),
                classroom: draft.classroom.trimmingCharacters(in: .whitespacesAndNewlines),
                description: "",
                weeks: weeks,
                weekday: draft.weekday,
                startSection: draft.startSection,
                endSection: draft.endSection,
                campus: "",
                number: "",
                credit: 0,
                hour: 0,
                type: "",
                category: "",
                department: ""
            )
        )
        persist()
    }

    /// 删除课程在当前周的这一节显示。
    ///
    /// 如果删完后课程已不再覆盖任何周次，则直接移除整门课。
    func deleteCourseOccurrence(id: String, week: Int) {
        guard let index = cache.courses.firstIndex(where: { $0.id == id }) else { return }

        let course = cache.courses[index]
        let remainingWeeks = course.weeks.filter { $0 != week }

        if remainingWeeks.isEmpty {
            cache.courses.remove(at: index)
        } else {
            cache.courses[index] = CourseRecord(
                id: course.id,
                term: course.term,
                name: course.name,
                teacher: course.teacher,
                classroom: course.classroom,
                description: course.description,
                weeks: remainingWeeks,
                weekday: course.weekday,
                startSection: course.startSection,
                endSection: course.endSection,
                campus: course.campus,
                number: course.number,
                credit: course.credit,
                hour: course.hour,
                type: course.type,
                category: course.category,
                department: course.department
            )
        }
        persist()
    }

    /// 删除整门课程。
    func deleteCourse(id: String) {
        cache.courses.removeAll { $0.id == id }
        persist()
    }

    /// 导入一份分享的课表载荷。
    ///
    /// 导入后的课表会作为一份“只读分身”追加到当前账号本地缓存中，
    /// 不覆盖我自己的课表、DDL、自定义日程和显示设置。
    func importSharedSchedule(_ payload: ScheduleExportPayload) throws {
        guard !payload.timeTable.isEmpty else {
            throw scheduleValidationError("分享的课表缺少时间表。")
        }

        let titleBase = payload.currentTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String((titleBase.isEmpty ? "分享课表" : "\(titleBase)课表").prefix(scheduleNameCharacterLimit))
        cache.sharedSchedules.append(
            SharedScheduleRecord(
                title: title,
                payload: payload
            )
        )
        persist()
        selectedCourseScheduleIndex = courseSchedules.count - 1
        selectedWeek = min(max(resolvedCurrentWeek(), 1), maxWeek)
    }

    /// 把已有自定义日程转成编辑草稿；如果为空则生成一份默认草稿。
    func customScheduleDraft(for record: CustomScheduleRecord?) -> CustomScheduleDraft {
        guard let record else {
            let now = Date()
            let end = Calendar.current.date(byAdding: .minute, value: 60, to: now) ?? now
            return CustomScheduleDraft(date: now, beginTime: now, endTime: end)
        }

        return CustomScheduleDraft(
            title: record.title,
            subtitle: record.subtitle,
            description: record.description,
            date: ScheduleDateCodec.parseDate(record.dateString) ?? Date(),
            beginTime: ScheduleDateCodec.parseTime(record.beginTime) ?? Date(),
            endTime: ScheduleDateCodec.parseTime(record.endTime) ?? Date()
        )
    }

    /// 新增一条自定义日程。
    func addCustomSchedule(_ draft: CustomScheduleDraft) throws {
        let beginMinutes = ScheduleDateCodec.minutesOfDay(from: draft.beginTime)
        let endMinutes = ScheduleDateCodec.minutesOfDay(from: draft.endTime)
        guard endMinutes > beginMinutes else {
            throw scheduleValidationError("结束时间必须晚于开始时间。")
        }

        cache.customSchedules.append(
            CustomScheduleRecord(
                id: UUID().uuidString,
                title: draft.title,
                subtitle: draft.subtitle,
                description: draft.description,
                dateString: ScheduleDateCodec.formatDate(draft.date),
                beginTime: ScheduleDateCodec.formatTime(draft.beginTime),
                endTime: ScheduleDateCodec.formatTime(draft.endTime)
            )
        )
        persist()
    }

    /// 更新指定自定义日程。
    func updateCustomSchedule(id: String, draft: CustomScheduleDraft) throws {
        let beginMinutes = ScheduleDateCodec.minutesOfDay(from: draft.beginTime)
        let endMinutes = ScheduleDateCodec.minutesOfDay(from: draft.endTime)
        guard endMinutes > beginMinutes else {
            throw scheduleValidationError("结束时间必须晚于开始时间。")
        }

        guard let index = cache.customSchedules.firstIndex(where: { $0.id == id }) else { return }
        cache.customSchedules[index].title = draft.title
        cache.customSchedules[index].subtitle = draft.subtitle
        cache.customSchedules[index].description = draft.description
        cache.customSchedules[index].dateString = ScheduleDateCodec.formatDate(draft.date)
        cache.customSchedules[index].beginTime = ScheduleDateCodec.formatTime(draft.beginTime)
        cache.customSchedules[index].endTime = ScheduleDateCodec.formatTime(draft.endTime)
        persist()
    }

    /// 删除指定自定义日程。
    func deleteCustomSchedule(id: String) {
        cache.customSchedules.removeAll { $0.id == id }
        persist()
    }

    /// 进入空教室页前的统一预热入口。
    ///
    /// 这里会做三件事：
    /// 1. 按当前时间块重设节次筛选。
    /// 2. 加载校区/教学楼元数据。
    /// 3. 必要时刷新当前楼栋的空教室结果。
    func prepareClassroomIfNeeded() async {
        applyCurrentClassroomSectionBlock()

        if campuses.isEmpty || buildings.isEmpty {
            await loadClassroomMeta()
        }

        if selectedBuildingID.isEmpty {
            selectedBuildingID = cache.selectedBuildingID
        }

        if classroomRecords.isEmpty, !selectedBuildingID.isEmpty {
            await refreshClassrooms()
        }
    }

    /// 切换空教室查询校区。
    func selectCampus(code: String) async {
        guard code != cache.selectedCampusCode else { return }

        cache.selectedCampusCode = code
        cache.selectedCampusName = campuses.first(where: { $0.code == code })?.name ?? ""
        selectedBuildingID = ""
        cache.selectedBuildingID = ""
        buildings = []
        classroomRecords = []
        classroomAvailabilities = []
        persist()

        await loadBuildings()
        if !selectedBuildingID.isEmpty {
            await refreshClassrooms()
        }
    }

    /// 切换当前教学楼并刷新空教室结果。
    func selectBuilding(id: String) async {
        guard id != selectedBuildingID else { return }
        selectedBuildingID = id
        cache.selectedBuildingID = id
        classroomRecords = []
        classroomAvailabilities = []
        persist()
        await refreshClassrooms()
    }

    /// 更新空教室节次筛选结果。
    func setSelectedClassroomSectionIDs(_ values: [Int]) {
        cache.selectedClassroomSectionIDs = normalizeSelectedClassroomSectionIDs(values)
        persist()
        refreshClassroomAvailabilities()
    }

    /// 刷新当前教学楼的空教室状态。
    ///
    /// 如果当前学期编码还未知，会先补查学期，再请求教室占用。
    func refreshClassrooms() async {
        if cache.currentTerm.isEmpty {
            do {
                cache.currentTerm = try await service.fetchCurrentTermOnly()
                persist()
            } catch {
                if isCancellation(error) { return }
                notice = ScheduleNotice(title: "空教室同步失败", message: error.localizedDescription)
                return
            }
        }

        guard !selectedBuildingID.isEmpty else { return }

        isLoadingClassrooms = true
        defer { isLoadingClassrooms = false }

        do {
            classroomRecords = try await service.fetchClassrooms(buildingID: selectedBuildingID, term: cache.currentTerm)
            refreshClassroomAvailabilities()
        } catch {
            if isCancellation(error) { return }
            notice = ScheduleNotice(title: "空教室同步失败", message: error.localizedDescription)
        }
    }

    /// 供页面下拉刷新使用的统一入口。
    ///
    /// 会先补齐校区/教学楼元数据，再刷新当前楼栋的空教室数据。
    func refreshClassroomPage() async {
        if campuses.isEmpty || buildings.isEmpty {
            await loadClassroomMeta()
        }

        guard !selectedBuildingID.isEmpty else { return }
        await refreshClassrooms()
    }

    /// DDL 到期时间文案。
    func ddlDueText(for event: DDLEventRecord) -> String {
        ScheduleDateCodec.formatRelativeDateTime(event.dueAt)
    }

    /// DDL 剩余/超时文案。
    func ddlRemainingText(for event: DDLEventRecord) -> String {
        let minutes = Int(event.dueAt.timeIntervalSinceNow / 60)
        let absolute = abs(minutes)
        let day = absolute / 1440
        let hour = (absolute % 1440) / 60
        let minute = absolute % 60

        let body: String
        if day > 0 {
            body = "\(day)天 \(hour)小时 \(minute)分钟"
        } else if hour > 0 {
            body = "\(hour)小时 \(minute)分钟"
        } else {
            body = "\(minute)分钟"
        }

        return minutes < 0 ? "已过 \(body)" : "剩余 \(body)"
    }

    /// DDL 颜色语义。
    ///
    /// 这里返回字符串而不是 `Color`，是为了让 View 层自己决定具体颜色映射。
    func ddlTint(for event: DDLEventRecord) -> String {
        if event.done {
            return "gray"
        }

        let interval = event.dueAt.timeIntervalSinceNow
        if interval <= 0 {
            return "red"
        }

        if interval <= Double(beforeDay * 24 * 3600) {
            return "orange"
        }

        return "green"
    }

    /// 加载空教室所需的校区和教学楼元数据。
    private func loadClassroomMeta() async {
        isLoadingClassroomMeta = true
        defer { isLoadingClassroomMeta = false }

        do {
            campuses = try await service.fetchCampuses()

            if cache.selectedCampusCode.isEmpty {
                if let preferredCampus = preferredCampus(from: campuses) {
                    cache.selectedCampusCode = preferredCampus.code
                    cache.selectedCampusName = preferredCampus.name
                } else {
                    cache.selectedCampusCode = campuses.first?.code ?? ""
                    cache.selectedCampusName = campuses.first?.name ?? ""
                }
                persist()
            }

            await loadBuildings()
        } catch {
            if isCancellation(error) { return }
            notice = ScheduleNotice(title: "空教室同步失败", message: error.localizedDescription)
        }
    }

    /// 根据当前校区加载教学楼，并优先精确匹配“最近下一节课”的楼宇。
    private func loadBuildings() async {
        do {
            buildings = try await service.fetchBuildings(campusCode: cache.selectedCampusCode)
            let validBuildingIDs = Set(buildings.map(\.buildingCode))
            let cachedBuildingID = cache.selectedBuildingID
            let preferredBuildingID = preferredBuildingID(from: buildings)

            if let preferredBuildingID, validBuildingIDs.contains(preferredBuildingID) {
                selectedBuildingID = preferredBuildingID
            } else if validBuildingIDs.contains(cachedBuildingID) {
                selectedBuildingID = cachedBuildingID
            } else {
                selectedBuildingID = buildings.first?.buildingCode ?? ""
            }
            cache.selectedBuildingID = selectedBuildingID
            persist()
        } catch {
            if isCancellation(error) { return }
            notice = ScheduleNotice(title: "教学楼同步失败", message: error.localizedDescription)
        }
    }

    /// 把“1-4,6,8-10”之类的周次文本解析成有序周次数组。
    private func parseWeeksText(_ text: String) throws -> [Int] {
        let cleaned = text.replacingOccurrences(of: "，", with: ",")
        let segments = cleaned
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !segments.isEmpty else {
            throw scheduleValidationError("周次不能为空。")
        }

        var weeks = Set<Int>()

        for segment in segments {
            if segment.contains("-") {
                let bounds = segment.split(separator: "-").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard bounds.count == 2, let lower = Int(bounds[0]), let upper = Int(bounds[1]), lower > 0, upper >= lower else {
                    throw scheduleValidationError("周次格式不正确，请使用如 1-16,18 的写法。")
                }
                for week in lower ... upper {
                    weeks.insert(week)
                }
            } else {
                guard let week = Int(segment), week > 0 else {
                    throw scheduleValidationError("周次格式不正确，请使用如 1-16,18 的写法。")
                }
                weeks.insert(week)
            }
        }

        return weeks.sorted()
    }

    /// 把原始教室占用记录格式化成可直接展示的空教室列表。
    private func refreshClassroomAvailabilities() {
        let nowMinutes = currentMinutes()
        let selectedSections = normalizeSelectedClassroomSectionIDs(cache.selectedClassroomSectionIDs)
        let currentFreeOnly = selectedSections.isEmpty
        let selectedSet = Set(selectedSections)

        let mapped = classroomRecords.map { record in
            buildClassroomAvailability(
                record: record,
                nowMinutes: nowMinutes
            )
        }

        classroomAvailabilities = mapped
            .filter { availability in
                if currentFreeOnly {
                    return availability.isFreeNow
                }
                return !selectedSet.intersection(availability.freeSections).isEmpty
            }
            .sorted { lhs, rhs in
                if currentFreeOnly, lhs.isFreeNow != rhs.isFreeNow {
                    return lhs.isFreeNow
                }
                if !currentFreeOnly {
                    let lhsMatches = selectedSet.intersection(lhs.freeSections).count
                    let rhsMatches = selectedSet.intersection(rhs.freeSections).count
                    if lhsMatches != rhsMatches {
                        return lhsMatches > rhsMatches
                    }
                }
                return lhs.name < rhs.name
            }
    }

    /// 构造单间教室的当前空闲状态描述。
    private func buildClassroomAvailability(
        record: ClassroomRecord,
        nowMinutes: Int
    ) -> ClassroomAvailability {
        let busySet = Set(record.busyTimeCodes)
        let freeSections = cache.timeTable
            .map(\.id)
            .filter { !busySet.contains($0) }

        let prettyFreeTimes = prettySectionsString(freeSections)
        let nextBusyStart = cache.timeTable
            .filter { busySet.contains($0.id) && $0.startMinutes >= nowMinutes }
            .map(\.startMinutes)
            .min()

        let currentBusySlot = cache.timeTable.first { slot in
            busySet.contains(slot.id) && slot.startMinutes <= nowMinutes && nowMinutes < slot.endMinutes
        }

        let isFreeNow: Bool
        let statusText: String
        let detailText: String

        if currentBusySlot == nil, let nextBusyStart {
            let remaining = nextBusyStart - nowMinutes
            isFreeNow = true
            statusText = "还会空闲 \(formatDuration(seconds: remaining))"
            detailText = "直到 \(TimeSlot.formatMinutes(nextBusyStart))"
        } else if currentBusySlot == nil {
            isFreeNow = true
            statusText = "空闲到明天"
            detailText = ""
        } else {
            isFreeNow = false
            if let nextFreeStart = nextFreeStartMinutes(from: record, after: nowMinutes) {
                statusText = "\(formatDuration(seconds: nextFreeStart - nowMinutes)) 后空闲"
                detailText = TimeSlot.formatMinutes(nextFreeStart)
            } else {
                statusText = "使用中"
                detailText = ""
            }
        }

        return ClassroomAvailability(
            id: record.id,
            name: record.name,
            prettyFreeTimes: prettyFreeTimes,
            statusText: statusText,
            detailText: detailText,
            isFreeNow: isFreeNow,
            freeSections: freeSections
        )
    }

    /// 节次筛选摘要文本。
    var classroomSectionFilterSummary: String {
        let selected = normalizeSelectedClassroomSectionIDs(cache.selectedClassroomSectionIDs)
        if selected.isEmpty {
            return "当前空闲"
        }
        return prettySectionsString(selected)
    }

    /// 当前是否处于“当前空闲”模式。
    var isCurrentFreeClassroomMode: Bool {
        normalizeSelectedClassroomSectionIDs(cache.selectedClassroomSectionIDs).isEmpty
    }

    /// 计算某间教室与当前筛选节次的命中摘要。
    func classroomMatchedSectionsText(for availability: ClassroomAvailability) -> String {
        let selected = normalizeSelectedClassroomSectionIDs(cache.selectedClassroomSectionIDs)
        guard !selected.isEmpty else { return "" }
        let selectedSet = Set(selected)
        let matched = availability.freeSections.filter { selectedSet.contains($0) }
        return prettySectionsString(matched)
    }

    /// 查询某间教室在指定时刻之后的最近空闲起点。
    private func nextFreeStartMinutes(from record: ClassroomRecord, after minutes: Int) -> Int? {
        let busySet = Set(record.busyTimeCodes)

        for slot in cache.timeTable {
            let slotStart = slot.startMinutes
            let slotEnd = slot.endMinutes

            if slotEnd <= minutes || busySet.contains(slot.id) {
                continue
            }

            return max(minutes, slotStart)
        }

        return nil
    }

    /// 把一组节次压缩成更适合展示的区间文本。
    private func prettySectionsString(_ sections: [Int]) -> String {
        guard !sections.isEmpty else {
            return "无"
        }

        var groups: [[Int]] = []
        for section in sections {
            if var last = groups.last, last.last == section - 1 {
                last.append(section)
                groups[groups.count - 1] = last
            } else {
                groups.append([section])
            }
        }

        return groups.map { group in
            if group.count == 1 {
                return "\(group[0])"
            }
            return "\(group.first!)~\(group.last!)"
        }
        .joined(separator: ", ")
    }

    /// 把时长秒数格式化成中文短文案。
    private func formatDuration(seconds: Int) -> String {
        let positive = max(seconds, 0)
        if positive < 60 {
            return "< 1 分钟"
        }

        let totalMinutes = positive / 60
        if totalMinutes < 60 {
            return "\(totalMinutes) 分钟"
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 {
            return "\(hours) 小时"
        }
        return "\(hours) 小时 \(minutes) 分钟"
    }

    /// 根据首周日期推导当前周次。
    private func resolvedCurrentWeek() -> Int {
        guard let firstDay = cache.firstDay else {
            return 1
        }

        let start = Calendar.current.startOfDay(for: firstDay)
        let today = Calendar.current.startOfDay(for: Date())
        let diff = Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0
        return max(diff / 7 + 1, 1)
    }

    /// 当前时间在一天中的分钟偏移。
    private func currentMinutes() -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// 去重并裁剪节次筛选结果，只保留合法节次。
    private func normalizeSelectedClassroomSectionIDs(_ values: [Int]) -> [Int] {
        let validSectionIDs = Set(cache.timeTable.map(\.id))
        var unique: [Int] = []

        for value in values {
            if validSectionIDs.contains(value) {
                if !unique.contains(value) {
                    unique.append(value)
                }
            }
        }

        return unique.sorted()
    }

    /// 统一兼容任务取消错误。
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// 从磁盘重新加载缓存，并同步周次与当前教学楼。
    private func reloadFromDisk() {
        let previousScheduleIndex = selectedCourseScheduleIndex
        cache = ScheduleCacheStore.load()
        selectedCourseScheduleIndex = min(max(previousScheduleIndex, 0), max(courseSchedules.count - 1, 0))
        selectedWeek = min(max(resolvedCurrentWeek(), 1), maxWeek)
        selectedBuildingID = cache.selectedBuildingID
    }

    /// 写回缓存。
    private func persist() {
        ScheduleCacheStore.save(cache)
    }

    /// 从“最近下一节课”的教室名推导最匹配的教学楼。
    ///
    /// 规则是：永远先做精确匹配，精确失败后才退回前缀匹配，再不行才回退缓存。
    private func preferredBuildingID(from buildings: [BuildingRecord]) -> String? {
        guard let course = nextUpcomingCourse() else { return nil }
        let candidates = buildingMatchCandidates(from: course.classroom)
        guard !candidates.isEmpty else { return nil }

        let normalizedBuildings = buildings.map { ($0, normalizeBuildingMatchText($0.name)) }

        if let exact = normalizedBuildings.first(where: { pair in
            candidates.contains(pair.1)
        }) {
            return exact.0.buildingCode
        }

        return normalizedBuildings.first { pair in
            let buildingName = pair.1
            guard !buildingName.isEmpty else { return false }
            return candidates.contains { candidate in
                candidate.hasPrefix(buildingName) || buildingName.hasPrefix(candidate)
            }
        }?.0.buildingCode
    }

    /// 从“最近下一节课”的校区信息推导默认校区。
    private func preferredCampus(from campuses: [CampusRecord]) -> CampusRecord? {
        guard let course = nextUpcomingCourse() else { return nil }
        let normalizedCampus = normalizeBuildingMatchText(course.campus)
        guard !normalizedCampus.isEmpty else { return nil }

        return campuses.first { campus in
            let campusName = normalizeBuildingMatchText(campus.name)
            let campusCode = normalizeBuildingMatchText(campus.code)
            return normalizedCampus.contains(campusName) || campusName.contains(normalizedCampus) || normalizedCampus == campusCode
        }
    }

    /// 找出当前时间之后最近开始的一节正式课程。
    private func nextUpcomingCourse() -> CourseRecord? {
        guard let firstDay = cache.firstDay else { return nil }
        let slotMap = Dictionary(uniqueKeysWithValues: cache.timeTable.map { ($0.id, $0) })
        let now = Date()

        return cache.courses
            .compactMap { course -> (CourseRecord, Date)? in
                let nextStart = course.weeks.compactMap { week -> Date? in
                    guard
                        let slot = slotMap[course.startSection],
                        let startDate = combineCourseDate(
                            firstDay: firstDay,
                            week: week,
                            weekday: course.weekday,
                            time: slot.start
                        )
                    else {
                        return nil
                    }
                    return startDate >= now ? startDate : nil
                }.min()

                guard let nextStart else { return nil }
                return (course, nextStart)
            }
            .min { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    /// 把课程的教学周/星期/节次时间拼成真实日期时间。
    private func combineCourseDate(firstDay: Date, week: Int, weekday: Int, time: String) -> Date? {
        let dayOffset = (week - 1) * 7 + (weekday - 1)
        guard let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: firstDay) else {
            return nil
        }

        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }

        var components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.current.date(from: components)
    }

    /// 归一化楼宇名称，提升“综教A101 -> 综教A”这类匹配成功率。
    private func normalizeBuildingMatchText(_ value: String) -> String {
        let compact = value
            .uppercased()
            .replacingOccurrences(of: "理教楼", with: "理教")
            .replacingOccurrences(of: "文萃楼", with: "文萃")
            .replacingOccurrences(of: "教学楼", with: "")
            .replacingOccurrences(of: "楼", with: "")
            .unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.punctuationCharacters.contains(scalar) &&
                !CharacterSet.symbols.contains(scalar)
            }

        return String(String.UnicodeScalarView(compact))
    }

    /// 从完整教室名中推导一组可能的楼宇候选值。
    private func buildingMatchCandidates(from classroom: String) -> [String] {
        let normalized = normalizeBuildingMatchText(classroom)
        guard !normalized.isEmpty else { return [] }

        var candidates: [String] = [normalized]

        if let firstDigitIndex = normalized.firstIndex(where: { $0.isNumber }) {
            let prefix = String(normalized[..<firstDigitIndex])
            if !prefix.isEmpty {
                candidates.append(prefix)
            }
        }

        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    /// 按当前时间自动切换到对应的节次块筛选。
    ///
    /// 不是首次才做，而是每次进入空教室页都会重新计算。
    private func applyCurrentClassroomSectionBlock() {
        let sectionIDs = currentClassroomSectionBlockIDs()
        guard !sectionIDs.isEmpty else { return }

        let normalized = normalizeSelectedClassroomSectionIDs(sectionIDs)
        guard cache.selectedClassroomSectionIDs != normalized else { return }
        cache.selectedClassroomSectionIDs = normalized
        persist()
        if !classroomRecords.isEmpty {
            refreshClassroomAvailabilities()
        }
    }

    /// 计算当前时间所在的学校节次块：
    /// 1-2 / 3-5 / 6-7 / 8-10 / 11-13。
    private func currentClassroomSectionBlockIDs() -> [Int] {
        let now = currentMinutes()

        let activeSlotID = cache.timeTable.first(where: { slot in
            slot.startMinutes <= now && now < slot.endMinutes
        })?.id ?? cache.timeTable.first(where: { $0.startMinutes > now })?.id

        guard let activeSlotID else { return [] }

        switch activeSlotID {
        case 1, 2:
            return [1, 2]
        case 3, 4, 5:
            return [3, 4, 5]
        case 6, 7:
            return [6, 7]
        case 8, 9, 10:
            return [8, 9, 10]
        case 11, 12, 13:
            return [11, 12, 13]
        default:
            return [activeSlotID]
        }
    }
}
