//
//  ScheduleService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

// MARK: - Redirect Helpers

/// 学校接口偶发回跳 HTTP，这里统一升级为 HTTPS，避免 ATS 拦截。
private final class HTTPSUpgradingRedirectDelegate: NSObject, URLSessionTaskDelegate {
    /// 截获学校侧的 HTTP 降级跳转，并在继续请求前强制升级回 HTTPS。
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(request)
            return
        }

        if let upgradedURL = ScheduleURLUpgrade.upgradedURL(from: url), upgradedURL != url {
            var secureRequest = request
            secureRequest.url = upgradedURL
            completionHandler(secureRequest)
            return
        }

        completionHandler(request)
    }
}

/// 日程同步链路里所有 URL 的升级工具。
private enum ScheduleURLUpgrade {
    /// 尝试把单个 URL 升级成 HTTPS。
    static func upgradedURL(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http" else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url
    }

    /// 把 URL 字符串升级成 HTTPS 文本。
    static func upgradedURLString(from string: String) -> String {
        guard
            let url = URL(string: string),
            let upgraded = upgradedURL(from: url)
        else {
            return string
        }

        return upgraded.absoluteString
    }
}

/// 日程同步过程中的统一错误。
enum ScheduleServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse
    case invalidLexuePage
    case invalidCalendarURL
    case invalidCalendarData

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效，请重新登录后再同步日程。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .invalidLexuePage:
            return "无法从乐学页面提取日历订阅信息。"
        case .invalidCalendarURL:
            return "乐学日历订阅链接无效。"
        case .invalidCalendarData:
            return "乐学日历数据解析失败。"
        }
    }
}

/// 同步课程表和考试后的组合结果。
struct CourseSyncPayload {
    let term: String
    let firstDayString: String
    let courses: [CourseRecord]
    let exams: [ExamRecord]
}

/// 同步 DDL 后的组合结果。
struct DDLSyncPayload {
    let url: String
    let events: [DDLEventRecord]
}

/// 日程模块网络层。
///
/// 负责三类事情：
/// 1. 教务课表 / 考试 / 空教室
/// 2. 乐学日历订阅地址解析与 ICS 下载
/// 3. ATS 相关的 HTTP -> HTTPS 升级
struct ScheduleService {
    private let schoolBaseURL = URL(string: "https://jxzxehallapp.bit.edu.cn")!
    private let lexueBaseURL = URL(string: "https://lexue.bit.edu.cn")!
    private let session: URLSession
    private let redirectDelegate = HTTPSUpgradingRedirectDelegate()

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    /// 同步课表、考试和首周日期。
    func syncCourses() async throws -> CourseSyncPayload {
        try await ensureSchoolSession()
        try await prepareJXZX()

        let term = try await fetchCurrentTerm()
        let courses = try await fetchCourses(term: term)
        let exams = try await fetchExams(term: term)
        let firstDayString = try await fetchFirstDayString(term: term)

        return CourseSyncPayload(
            term: term,
            firstDayString: firstDayString,
            courses: courses,
            exams: exams
        )
    }

    /// 只查询当前学期，不拉完整课表。
    func fetchCurrentTermOnly() async throws -> String {
        try await ensureSchoolSession()
        try await prepareJXZX()
        return try await fetchCurrentTerm()
    }

    /// 同步乐学 DDL，并尽量复用已缓存的订阅地址。
    func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String) async throws -> DDLSyncPayload {
        try await ensureSchoolSession()

        // 乐学同步允许复用已缓存的订阅链接，只有没有链接时才回到网页里重新抓取。
        let finalURL = try await resolveLexueCalendarURL(storedURL: storedURL)
        let remoteEvents = try await fetchLexueEvents(urlString: finalURL)

        let existingDoneMap = Dictionary(uniqueKeysWithValues: existingEvents.map { ($0.id, $0.done) })
        let merged = remoteEvents.map { event in
            return DDLEventRecord(
                id: event.id,
                group: event.group,
                title: event.title,
                text: event.text,
                dueAt: event.dueAt,
                done: existingDoneMap[event.id] ?? event.done
            )
        }

        return DDLSyncPayload(url: finalURL, events: merged)
    }

    /// 强制重新抓取乐学订阅地址。
    func refreshLexueCalendarURL() async throws -> String {
        try await ensureSchoolSession()
        return try await resolveLexueCalendarURL(storedURL: "")
    }

    /// 查询空教室页可选校区列表。
    func fetchCampuses() async throws -> [CampusRecord] {
        try await ensureSchoolSession()
        try await prepareJXZX()

        let response: CampusListResponse = try await sendJSONRequest(
            path: "/jwapp/sys/kxjasbyMobile/modules/jxllb/ggzdpx.do?dicCode=48682&SFSY=1&order=%2BDM"
        )

        return response.datas.ggzdpx.rows.map {
            CampusRecord(id: $0.code, name: $0.displayName, code: $0.code)
        }
    }

    /// 查询某个校区下的教学楼列表。
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] {
        try await ensureSchoolSession()
        try await prepareJXZX()

        let query: String
        if let campusCode, !campusCode.isEmpty {
            query = "?XXXQDM=\(urlEncode(campusCode))"
        } else {
            query = ""
        }

        let response: BuildingListResponse = try await sendJSONRequest(
            path: "/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do\(query)"
        )

        return response.datas.cxjxl.rows.map {
            BuildingRecord(
                id: $0.buildingCode,
                name: $0.buildingName,
                buildingCode: $0.buildingCode,
                campusName: $0.campusName,
                campusCode: $0.campusCode
            )
        }
    }

    /// 查询某个教学楼当天的教室占用情况。
    func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord] {
        try await ensureSchoolSession()
        try await prepareJXZX()

        let termParts = term.split(separator: "-")
        let termID = termParts.last.map(String.init) ?? ""
        let termYearCode = termParts.dropLast().joined(separator: "-")
        let dateString = ScheduleDateCodec.formatDate(Date())

        let response: ClassroomListResponse = try await sendJSONRequest(
            path: "/jwapp/sys/kxjasbyMobile/kxjasbyController/cxkxjasqk.do",
            method: "POST",
            body: [
                ("XQDM", String(termID)),
                ("JXLDM", buildingID),
                ("RQ", dateString),
                ("XNXQDM", term),
                ("XNDM", String(termYearCode)),
            ]
        )

        return response.datas.cxkxjasqk.rows.map {
            ClassroomRecord(
                id: $0.classroomName,
                name: $0.classroomName,
                busyTimeCodes: $0.busyTimeString?
                    .split(separator: ",")
                    .compactMap { Int($0) }
                    .sorted() ?? []
            )
        }
    }

    /// 确保学校侧登录态仍然有效。
    private func ensureSchoolSession() async throws {
        guard try await LoginService().checkLogin() != nil else {
            throw ScheduleServiceError.notLoggedIn
        }
    }

    /// 教务系统接口请求前的预热步骤。
    private func prepareJXZX() async throws {
        // 学校教务接口依赖若干预热请求，否则后续接口会直接返回未初始化状态。
        _ = try await sendStringRequest(path: "/jwapp/sys/funauthapp/api/getAppConfig/wdkbby-5959167891382285.do")
        _ = try await sendStringRequest(path: "/jwapp/i18n.do?appName=wdkbby&EMAP_LANG=zh")
    }

    /// 获取当前学期编码。
    private func fetchCurrentTerm() async throws -> String {
        let response: CurrentTermResponse = try await sendJSONRequest(
            path: "/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do"
        )

        guard let term = response.datas.dqxnxq.rows.first?.code, !term.isEmpty else {
            throw ScheduleServiceError.invalidResponse
        }

        return term
    }

    /// 拉取当前学期课程表。
    private func fetchCourses(term: String) async throws -> [CourseRecord] {
        let response: CourseResponse = try await sendJSONRequest(
            path: "/jwapp/sys/wdkbby/modules/xskcb/cxxszhxqkb.do",
            method: "POST",
            body: [("XNXQDM", term)]
        )

        return response.datas.cxxszhxqkb.rows.map { row in
            let weeks = (row.rawWeeks ?? "").enumerated().compactMap { index, flag in
                flag == "1" ? index + 1 : nil
            }

            return CourseRecord(
                id: "\(row.term ?? "")-\(row.courseNumber ?? "")-\(row.weekday ?? 0)-\(row.startSection ?? 0)-\(row.endSection ?? 0)-\(row.classroom ?? "")",
                term: row.term ?? "",
                name: row.name ?? "",
                teacher: row.teacher ?? "",
                classroom: row.classroom ?? "",
                description: row.scheduleDescription ?? "",
                weeks: weeks,
                weekday: row.weekday ?? 0,
                startSection: row.startSection ?? 0,
                endSection: row.endSection ?? 0,
                campus: row.campus ?? "",
                number: row.courseNumber ?? "",
                credit: row.credit ?? 0,
                hour: row.hour ?? 0,
                type: row.type ?? "",
                category: row.category ?? "",
                department: row.department ?? ""
            )
        }
    }

    private func fetchExams(term: String) async throws -> [ExamRecord] {
        let response: ExamResponse = try await sendJSONRequest(
            path: "/jwapp/sys/wdksapMobile/modules/ksap/cxxsksap.do",
            method: "POST",
            body: [("XNXQDM", term), ("*order", "-KSRQ")]
        )

        return response.datas.cxxsksap.rows.map { row in
            let rawCourseName = row.courseName ?? ""
            let name = rawCourseName
                .split(separator: "]")
                .first?
                .split(separator: "[")
                .last
                .map(String.init) ?? rawCourseName

            let times = row.timeDescription.captureGroups(pattern: #"(\d{2}:\d{2})-(\d{2}:\d{2})"#)
            let beginTime = times.first ?? ""
            let endTime = times.dropFirst().first ?? ""

            return ExamRecord(
                id: "\(row.termCode ?? "")-\(row.courseID ?? "")-\(row.dateString ?? "")-\(row.timeDescription)",
                term: row.termCode ?? "",
                name: name,
                courseID: row.courseID ?? "",
                teacher: row.teacherName ?? "",
                classroom: row.location ?? "",
                dateString: (row.dateString ?? "").split(separator: " ").first.map(String.init) ?? (row.dateString ?? ""),
                beginTime: beginTime,
                endTime: endTime,
                examMode: row.examMode ?? "",
                seatID: row.seatID ?? ""
            )
        }
    }

    private func fetchFirstDayString(term: String) async throws -> String {
        let requestParam = #"{"XNXQDM":"\#(term)","ZC":"1"}"#
        let response: WeekDateResponse = try await sendJSONRequest(
            path: "/jwapp/sys/wdkbby/wdkbByController/cxzkbrq.do",
            method: "POST",
            body: [("requestParamStr", requestParam)]
        )

        guard let firstDay = response.data.first(where: { $0.week == 1 })?.date else {
            throw ScheduleServiceError.invalidResponse
        }

        return firstDay
    }

    private func resolveLexueCalendarURL(storedURL: String) async throws -> String {
        if !storedURL.isEmpty {
            return storedURL
        }

        let indexHTML = try await sendStringRequest(baseURL: lexueBaseURL, path: "/")
        guard
            let sesskey = indexHTML.captureGroups(pattern: #"[\"']sesskey[\"']:[\"']([^\"']+)[\"']"#).first,
            !sesskey.isEmpty
        else {
            throw ScheduleServiceError.invalidLexuePage
        }

        let calendarHTML = try await sendStringRequest(
            baseURL: lexueBaseURL,
            path: "/calendar/export.php",
            method: "POST",
            body: [
                ("sesskey", sesskey),
                ("_qf__core_calendar_export_form", "1"),
                ("events[exportevents]", "all"),
                ("period[timeperiod]", "recentupcoming"),
                ("generateurl", "获取日历网址"),
            ]
        )

        let fullURL =
            extractCalendarURL(from: calendarHTML, pattern: #"class=["'][^"']*calendarurl[^"']*["'][^>]*>[\s\S]*?(https?://[^<"'\s]+)"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"class=["'][^"']*calendarurl[^"']*["'][^>]*>[\s\S]*?(webcal://[^<"'\s]+)"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"value=["'](https?://[^"']+)["']"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"value=["'](webcal://[^"']+)["']"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"href=["'](https?://[^"']+)["']"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"href=["'](webcal://[^"']+)["']"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"https?://[^\s"'<]+"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"webcal://[^\s"'<]+"#)

        guard let fullURL else {
            throw ScheduleServiceError.invalidCalendarURL
        }

        return ScheduleURLUpgrade.upgradedURLString(from: fullURL)
    }

    private func fetchLexueEvents(urlString: String) async throws -> [DDLEventRecord] {
        // 订阅链接可能以 webcal:// 或 http:// 返回，这里统一标准化后再拉取 ICS。
        let secureURLString = ScheduleURLUpgrade.upgradedURLString(from: urlString)

        guard let url = URL(string: secureURLString) else {
            throw ScheduleServiceError.invalidCalendarURL
        }

        let request = URLRequest(url: url)
        let ics = try await sendStringRequest(request)
        return try parseICS(ics)
    }

    private func parseICS(_ ics: String) throws -> [DDLEventRecord] {
        // iCalendar 允许折行，这里先展开，再逐个 VEVENT 解析。
        let unfolded = ics
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")

        let blocks = unfolded.components(separatedBy: "BEGIN:VEVENT")
        var events: [DDLEventRecord] = []

        for block in blocks.dropFirst() {
            guard let content = block.components(separatedBy: "END:VEVENT").first else {
                continue
            }

            var values: [String: String] = [:]
            for line in content.split(separator: "\n") {
                guard let separatorIndex = line.firstIndex(of: ":") else { continue }
                let keyPart = String(line[..<separatorIndex])
                let valuePart = String(line[line.index(after: separatorIndex)...])
                let key = keyPart.split(separator: ";").first.map(String.init) ?? keyPart
                values[key] = decodeICSValue(valuePart)
            }

            guard
                let uid = values["UID"],
                let summary = values["SUMMARY"],
                let dtStart = values["DTSTART"],
                let dueAt = parseICSDate(dtStart)
            else {
                continue
            }

            let description = values["DESCRIPTION"] ?? ""
            let course = values["CATEGORIES"] ?? ""
            let text = [course, description]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            events.append(
                DDLEventRecord(
                    id: uid,
                    group: "lexue",
                    title: summary,
                    text: text,
                    dueAt: dueAt,
                    done: false
                )
            )
        }

        guard !events.isEmpty else {
            throw ScheduleServiceError.invalidCalendarData
        }

        return events.sorted { $0.dueAt < $1.dueAt }
    }

    private func parseICSDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if string.hasSuffix("Z") {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.date(from: string)
        }

        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"

        if let date = formatter.date(from: string) {
            return date
        }

        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: string)
    }

    private func decodeICSValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\\,"#, with: ",", options: .regularExpression)
            .replacingOccurrences(of: #"\\;"#, with: ";", options: .regularExpression)
            .replacingOccurrences(of: #"\\\\"#, with: "\\", options: .regularExpression)
    }

    private func sendJSONRequest<Response: Decodable>(
        baseURL: URL? = nil,
        path: String,
        method: String = "GET",
        body: [(String, String)] = []
    ) async throws -> Response {
        var request = URLRequest(url: buildURL(baseURL: baseURL ?? schoolBaseURL, path: path))
        request.httpMethod = method

        if method == "POST" {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(body)
        }

        let (data, response) = try await sendRequest(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw httpError(response.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ScheduleServiceError.invalidResponse
        }
    }

    private func sendStringRequest(
        baseURL: URL? = nil,
        path: String,
        method: String = "GET",
        body: [(String, String)] = []
    ) async throws -> String {
        var request = URLRequest(url: buildURL(baseURL: baseURL ?? schoolBaseURL, path: path))
        request.httpMethod = method

        if method == "POST" {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(body)
        }

        return try await sendStringRequest(request)
    }

    private func sendStringRequest(_ request: URLRequest) async throws -> String {
        let (data, response) = try await sendRequest(request)
        guard (200 ..< 400).contains(response.statusCode) else {
            throw httpError(response.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func sendRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let secureRequest: URLRequest
        if let url = request.url, let upgradedURL = ScheduleURLUpgrade.upgradedURL(from: url), upgradedURL != url {
            var upgradedRequest = request
            upgradedRequest.url = upgradedURL
            secureRequest = upgradedRequest
        } else {
            secureRequest = request
        }
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: secureRequest)
        } catch {
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ScheduleServiceError.invalidResponse
        }
        return (data, httpResponse)
    }

    private func buildURL(baseURL: URL, path: String) -> URL {
        URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL.appending(path: path)
    }

    private func extractCalendarURL(from html: String, pattern: String) -> String? {
        html.captureGroups(pattern: pattern, options: [.dotMatchesLineSeparators]).first
            .map { rawURLString in
                // 乐学页面可能把参数里的 & 转义成 &amp;，不先还原就会打成 404。
                let urlString = decodeHTML(urlString: rawURLString)

                if urlString.lowercased().hasPrefix("webcal://") {
                    return "https://" + urlString.dropFirst("webcal://".count)
                }
                return ScheduleURLUpgrade.upgradedURLString(from: urlString)
            }
    }

    private func decodeHTML(urlString: String) -> String {
        urlString
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private func formBody(_ fields: [(String, String)]) -> Data {
        let encoded = fields.map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }
        .joined(separator: "&")

        return Data(encoded.utf8)
    }

    private func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func httpError(_ statusCode: Int) -> NSError {
        NSError(
            domain: "BIT101.Schedule",
            code: statusCode,
            userInfo: [NSLocalizedDescriptionKey: "请求失败，HTTP 状态码 \(statusCode)。"]
        )
    }
}

/// 当前学期接口响应体。
private struct CurrentTermResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [TermRow]
        }

        let dqxnxq: Rows
    }

    struct TermRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case code = "DM"
        }

        let code: String
    }

    let datas: Datas
}

/// 课程表接口响应体。
private struct CourseResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [CourseRow]
        }

        let cxxszhxqkb: Rows
    }

    struct CourseRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case term = "XNXQDM"
            case name = "KCM"
            case teacher = "SKJS"
            case classroom = "JASMC"
            case scheduleDescription = "YPSJDD"
            case rawWeeks = "SKZC"
            case weekday = "SKXQ"
            case startSection = "KSJC"
            case endSection = "JSJC"
            case campus = "XXXQMC"
            case courseNumber = "KCH"
            case credit = "XF"
            case hour = "XS"
            case type = "KCXZDM_DISPLAY"
            case category = "KCLBDM_DISPLAY"
            case department = "KKDWDM_DISPLAY"
        }

        let term: String?
        let name: String?
        let teacher: String?
        let classroom: String?
        let scheduleDescription: String?
        let rawWeeks: String?
        let weekday: Int?
        let startSection: Int?
        let endSection: Int?
        let campus: String?
        let courseNumber: String?
        let credit: Int?
        let hour: Int?
        let type: String?
        let category: String?
        let department: String?
    }

    let datas: Datas
}

/// 考试安排接口响应体。
private struct ExamResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [ExamRow]
        }

        let cxxsksap: Rows
    }

    struct ExamRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case location = "JASMC"
            case timeDescription = "KSSJMS"
            case dateString = "KSRQ"
            case seatID = "ZWH"
            case examMode = "KSMC"
            case termCode = "XNXQDM_DISPLAY"
            case courseName = "KCM"
            case teacherName = "ZJJSXM"
            case courseID = "KCH"
        }

        let location: String?
        let timeDescription: String
        let dateString: String?
        let seatID: String?
        let examMode: String?
        let termCode: String?
        let courseName: String?
        let teacherName: String?
        let courseID: String?
    }

    let datas: Datas
}

/// 周起始日期接口响应体。
private struct WeekDateResponse: Decodable {
    struct WeekDateRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case week = "XQ"
            case date = "RQ"
        }

        let week: Int
        let date: String
    }

    let data: [WeekDateRow]
}

/// 校区列表接口响应体。
private struct CampusListResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [CampusRow]
        }

        let ggzdpx: Rows
    }

    struct CampusRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case displayName = "MC"
            case code = "DM"
        }

        let displayName: String
        let code: String
    }

    let datas: Datas
}

/// 教学楼列表接口响应体。
private struct BuildingListResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [BuildingRow]
        }

        let cxjxl: Rows
    }

    struct BuildingRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case buildingName = "JXLMC"
            case buildingCode = "JXLDM"
            case campusName = "XXXQDM_DISPLAY"
            case campusCode = "XXXQDM"
        }

        let buildingName: String
        let buildingCode: String
        let campusName: String
        let campusCode: String
    }

    let datas: Datas
}

/// 空教室接口响应体。
private struct ClassroomListResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [ClassroomRow]
        }

        let cxkxjasqk: Rows
    }

    struct ClassroomRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case classroomName = "JASMC"
            case busyTimeString = "ZYJC"
        }

        let classroomName: String
        let busyTimeString: String?
    }

    let datas: Datas
}

/// 正则捕获工具。
///
/// 这里只提供最小能力：返回首个命中的捕获组数组，供乐学和学校页面解析复用。
private extension String {
    func captureGroups(pattern: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }

        let range = NSRange(startIndex..., in: self)
        guard let match = regex.firstMatch(in: self, options: [], range: range) else {
            return []
        }

        guard match.numberOfRanges > 1 else {
            return [String(self[Range(match.range, in: self)!])]
        }

        return (1 ..< match.numberOfRanges).compactMap { index in
            guard let captureRange = Range(match.range(at: index), in: self) else {
                return nil
            }
            return String(self[captureRange])
        }
    }
}
