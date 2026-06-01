//
//  CourseService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-02.
//

import Foundation

/// 课程模块接口错误。
enum CourseServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效，请重新登录后再查看课程。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        }
    }
}

/// 课程模块网络层。
///
/// 课程列表和详情走 `courses` 资源，评论和点赞仍然复用社区 reaction 接口。
struct CourseService {
    /// 课程页当前不再暴露排序切换，列表固定按“最新”请求。
    private static let defaultCourseOrder = "new"

    private struct CreateCommentRequest: Encodable {
        let obj: String
        let text: String
        let replyObj: String?
        let replyUid: Int?
        let anonymous: Bool?
        let rate: Int?
        let imageMids: [String]

        enum CodingKeys: String, CodingKey {
            case obj
            case text
            case replyObj = "reply_obj"
            case replyUid = "reply_uid"
            case anonymous
            case rate
            case imageMids = "image_mids"
        }
    }

    private struct LikeRequest: Encodable {
        let obj: String
    }

    private let baseURL = URL(string: "https://bit101.flwfdd.xyz")!
    private let session: URLSession
    private let storage: LoginStorage

    init(storage: LoginStorage = .shared) {
        self.storage = storage

        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
    }

    /// 拉取课程列表。
    func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
        var queryItems = [
            URLQueryItem(name: "order", value: Self.defaultCourseOrder),
            URLQueryItem(name: "page", value: String(page)),
        ]

        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            queryItems.insert(URLQueryItem(name: "search", value: keyword), at: 0)
        }

        return try await sendJSONRequest(path: "courses", queryItems: queryItems)
    }

    /// 拉取单门课程详情。
    func fetchCourse(id: Int) async throws -> CourseDetail {
        try await sendJSONRequest(path: "courses/\(id)")
    }

    /// 拉取单门课程按学期聚合的历史成绩统计。
    func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade] {
        try await sendJSONRequest(path: "courses/histories/\(number)")
    }

    /// 拉取课程评论。
    ///
    /// 课程页当前评论量较小，不再提供排序切换，因此固定拉取“最新”顺序。
    func fetchComments(courseID: Int, page: Int?) async throws -> [GalleryComment] {
        var queryItems = [
            URLQueryItem(name: "obj", value: "course\(courseID)"),
            URLQueryItem(name: "order", value: GalleryCommentOrder.newest.rawValue),
        ]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }
        return try await sendJSONRequest(path: "reaction/comments", queryItems: queryItems)
    }

    /// 对课程评论执行点赞或取消点赞。
    func like(objectID: String) async throws -> GalleryLikeResult {
        try await sendJSONRequest(
            path: "reaction/like",
            method: "POST",
            body: try JSONEncoder().encode(LikeRequest(obj: objectID))
        )
    }

    /// 创建课程评论或回复。
    func createComment(
        objectID: String,
        text: String,
        replyObjectID: String? = nil,
        replyUID: Int? = nil,
        anonymous: Bool = false,
        rate: Int? = nil
    ) async throws -> GalleryComment {
        try await sendJSONRequest(
            path: "reaction/comments",
            method: "POST",
            body: try JSONEncoder().encode(
                CreateCommentRequest(
                    obj: objectID,
                    text: text,
                    replyObj: replyObjectID,
                    replyUid: replyUID,
                    anonymous: anonymous,
                    rate: rate,
                    imageMids: []
                )
            )
        )
    }

    private func sendJSONRequest<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Response {
        let fakeCookie = try requireFakeCookie()

        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components?.url else {
            throw CourseServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CourseServiceError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200 ..< 300:
            break
        case 401:
            throw CourseServiceError.notLoggedIn
        default:
            throw NSError(
                domain: "BIT101.Course",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "请求失败，HTTP 状态码 \(httpResponse.statusCode)。"]
            )
        }

        do {
            return try makeSnakeCaseDecoder().decode(Response.self, from: data)
        } catch {
            throw CourseServiceError.invalidResponse
        }
    }

    private func requireFakeCookie() throws -> String {
        let fakeCookie = storage.fakeCookie
        guard !fakeCookie.isEmpty else {
            throw CourseServiceError.notLoggedIn
        }
        return fakeCookie
    }

    private func makeSnakeCaseDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
