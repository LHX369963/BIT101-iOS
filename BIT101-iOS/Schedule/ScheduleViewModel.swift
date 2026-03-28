//
//  ScheduleViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

/// 日程页统一使用的提示模型。
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
    @Published var selectedSection: ScheduleSection = .courses
    @Published private(set) var cache = ScheduleCache()
    @Published private(set) var isLoadingCache = true
    @Published private(set) var isSyncingCourses = false
    @Published private(set) var isSyncingDDL = false
    @Published private(set) var isLoadingClassroomMeta = false
    @Published private(set) var isLoadingClassrooms = false
    @Published private(set) var campuses: [CampusRecord] = []
    @Published private(set) var buildings: [BuildingRecord] = []
    @Published private(set) var classroomAvailabilities: [ClassroomAvailability] = []
    @Published var selectedWeek = 1
    @Published var selectedBuildingID = ""
    @Published var notice: ScheduleNotice?

    private let service: ScheduleService
    private var hasLoaded = false
    private var classroomRecords: [ClassroomRecord] = []
    private var cacheObserver: NSObjectProtocol?

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

    /// DDL 列表默认向前展示的天数。
    var beforeDay: Int { cache.ddlBeforeDay }
    /// DDL 列表默认向后保留的天数。
    var afterDay: Int { cache.ddlAfterDay }

    /// 首周日期的展示文本。
    var firstDayDescription: String {
        guard let firstDay = cache.firstDay else {
            return "未同步"
        }
        return ScheduleDateCodec.formatDate(firstDay)
    }

    /// 当前学期最大周数，至少覆盖当前周。
    var maxWeek: Int {
        max(cache.courses.flatMap(\.weeks).max() ?? 1, resolvedCurrentWeek())
    }

    /// 是否已经同步到任何课程或考试数据。
    var hasCourseData: Bool {
        !cache.courses.isEmpty || !cache.exams.isEmpty
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
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        // 页面先读本地缓存，确保一打开就有内容，避免每次冷启动都重新同步。
        reloadFromDisk()
        isLoadingCache = false
    }

    /// 同步课程表、考试安排和首周日期。
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
    func syncDDL() async {
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
        } catch {
            notice = ScheduleNotice(title: "DDL 同步失败", message: error.localizedDescription)
        }
    }

    /// 强制重新抓取乐学日历订阅地址。
    func refreshLexueCalendarURL() async {
        isSyncingDDL = true
        defer { isSyncingDDL = false }

        do {
            cache.lexueCalendarURL = try await service.refreshLexueCalendarURL()
            persist()
        } catch {
            notice = ScheduleNotice(title: "订阅链接获取失败", message: error.localizedDescription)
        }
    }

    /// 切换某条 DDL 的完成状态。
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
    func addDDL(_ draft: DDLDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "BIT101.Schedule", code: -1, userInfo: [NSLocalizedDescriptionKey: "标题不能为空。"])
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
            throw NSError(domain: "BIT101.Schedule", code: -1, userInfo: [NSLocalizedDescriptionKey: "标题不能为空。"])
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

    func setShowDivider(_ value: Bool) {
        cache.showDivider = value
        persist()
    }

    func setShowCurrentTime(_ value: Bool) {
        cache.showCurrentTime = value
        persist()
    }

    func setShowExamInfo(_ value: Bool) {
        cache.showExamInfo = value
        persist()
    }

    func setShowCourseLiveActivityReminder(_ value: Bool) {
        cache.showCourseLiveActivityReminder = value
        persist()
    }

    func setCourseLiveActivityLeadMinutes(_ value: Int) {
        cache.courseLiveActivityLeadMinutes = min(max(value, 1), 99)
        persist()
    }

    func setTimeTable(from text: String) throws {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var timeTable: [TimeSlot] = []
        for (index, line) in lines.enumerated() {
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                throw NSError(domain: "BIT101.Schedule", code: -1, userInfo: [NSLocalizedDescriptionKey: "时间表格式错误。"])
            }

            let start = parts[0]
            let end = parts[1]
            let startMinutes = TimeSlot.parseMinutes(start)
            let endMinutes = TimeSlot.parseMinutes(end)
            guard endMinutes > startMinutes else {
                throw NSError(domain: "BIT101.Schedule", code: -1, userInfo: [NSLocalizedDescriptionKey: "时间表格式错误。"])
            }
            if let last = timeTable.last, startMinutes <= last.endMinutes {
                throw NSError(domain: "BIT101.Schedule", code: -1, userInfo: [NSLocalizedDescriptionKey: "时间表格式错误。"])
            }

            timeTable.append(TimeSlot(id: index + 1, start: start, end: end))
        }

        guard !timeTable.isEmpty else {
            throw NSError(domain: "BIT101.Schedule", code: -1, userInfo: [NSLocalizedDescriptionKey: "时间表格式错误。"])
        }

        cache.timeTable = timeTable
        persist()
    }

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

    func addCustomSchedule(_ draft: CustomScheduleDraft) throws {
        let beginMinutes = ScheduleDateCodec.minutesOfDay(from: draft.beginTime)
        let endMinutes = ScheduleDateCodec.minutesOfDay(from: draft.endTime)
        guard endMinutes > beginMinutes else {
            throw NSError(domain: "BIT101.Schedule", code: -1, userInfo: [NSLocalizedDescriptionKey: "结束时间必须晚于开始时间。"])
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

    func updateCustomSchedule(id: String, draft: CustomScheduleDraft) throws {
        let beginMinutes = ScheduleDateCodec.minutesOfDay(from: draft.beginTime)
        let endMinutes = ScheduleDateCodec.minutesOfDay(from: draft.endTime)
        guard endMinutes > beginMinutes else {
            throw NSError(domain: "BIT101.Schedule", code: -1, userInfo: [NSLocalizedDescriptionKey: "结束时间必须晚于开始时间。"])
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

    func deleteCustomSchedule(id: String) {
        cache.customSchedules.removeAll { $0.id == id }
        persist()
    }

    func prepareClassroomIfNeeded() async {
        if campuses.isEmpty || buildings.isEmpty {
            await loadClassroomMeta()
        }

        if classroomRecords.isEmpty, !selectedBuildingID.isEmpty {
            await refreshClassrooms()
        }
    }

    func selectCampus(code: String) async {
        guard code != cache.selectedCampusCode else { return }

        cache.selectedCampusCode = code
        cache.selectedCampusName = campuses.first(where: { $0.code == code })?.name ?? ""
        selectedBuildingID = ""
        buildings = []
        classroomRecords = []
        classroomAvailabilities = []
        persist()

        await loadBuildings()
        if !selectedBuildingID.isEmpty {
            await refreshClassrooms()
        }
    }

    func selectBuilding(id: String) async {
        guard id != selectedBuildingID else { return }
        selectedBuildingID = id
        classroomRecords = []
        classroomAvailabilities = []
        await refreshClassrooms()
    }

    func setSelectedClassroomSectionIDs(_ values: [Int]) {
        cache.selectedClassroomSectionIDs = normalizeSelectedClassroomSectionIDs(values)
        persist()
        refreshClassroomAvailabilities()
    }

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

    func ddlDueText(for event: DDLEventRecord) -> String {
        ScheduleDateCodec.formatRelativeDateTime(event.dueAt)
    }

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

    private func loadClassroomMeta() async {
        isLoadingClassroomMeta = true
        defer { isLoadingClassroomMeta = false }

        do {
            campuses = try await service.fetchCampuses()

            if cache.selectedCampusCode.isEmpty {
                cache.selectedCampusCode = campuses.first?.code ?? ""
                cache.selectedCampusName = campuses.first?.name ?? ""
                persist()
            }

            await loadBuildings()
        } catch {
            if isCancellation(error) { return }
            notice = ScheduleNotice(title: "空教室同步失败", message: error.localizedDescription)
        }
    }

    private func loadBuildings() async {
        do {
            buildings = try await service.fetchBuildings(campusCode: cache.selectedCampusCode)
            if selectedBuildingID.isEmpty {
                selectedBuildingID = buildings.first?.buildingCode ?? ""
            }
        } catch {
            if isCancellation(error) { return }
            notice = ScheduleNotice(title: "教学楼同步失败", message: error.localizedDescription)
        }
    }

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

    var classroomSectionFilterSummary: String {
        let selected = normalizeSelectedClassroomSectionIDs(cache.selectedClassroomSectionIDs)
        if selected.isEmpty {
            return "当前空闲"
        }
        return prettySectionsString(selected)
    }

    var isCurrentFreeClassroomMode: Bool {
        normalizeSelectedClassroomSectionIDs(cache.selectedClassroomSectionIDs).isEmpty
    }

    func classroomMatchedSectionsText(for availability: ClassroomAvailability) -> String {
        let selected = normalizeSelectedClassroomSectionIDs(cache.selectedClassroomSectionIDs)
        guard !selected.isEmpty else { return "" }
        let selectedSet = Set(selected)
        let matched = availability.freeSections.filter { selectedSet.contains($0) }
        return prettySectionsString(matched)
    }

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

    private func resolvedCurrentWeek() -> Int {
        guard let firstDay = cache.firstDay else {
            return 1
        }

        let start = Calendar.current.startOfDay(for: firstDay)
        let today = Calendar.current.startOfDay(for: Date())
        let diff = Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0
        return max(diff / 7 + 1, 1)
    }

    private func currentMinutes() -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

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

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func reloadFromDisk() {
        cache = ScheduleCacheStore.load()
        selectedWeek = min(max(resolvedCurrentWeek(), 1), maxWeek)
        if selectedBuildingID.isEmpty {
            selectedBuildingID = buildings.first?.buildingCode ?? selectedBuildingID
        }
    }

    private func persist() {
        ScheduleCacheStore.save(cache)
    }
}
