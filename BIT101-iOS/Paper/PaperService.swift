//
//  PaperService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-01.
//

import Foundation

/// 文章模块网络层错误。
enum PaperServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效，请重新登录后再查看文章。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        }
    }
}

/// 文章模块网络层。
///
/// 文章列表和详情接口独立于话廊，但点赞、评论仍然沿用同一套 reaction 接口。
struct PaperService {
    private let baseURL = URL(string: "https://bit101.flwfdd.xyz")!
    private let session: URLSession
    private let storage: LoginStorage

    private struct LikeRequest: Encodable {
        let obj: String
    }

    private struct CreateCommentRequest: Encodable {
        let obj: String
        let text: String
        let replyObj: String?
        let replyUid: Int?
        let anonymous: Bool?
        let imageMids: [String]

        enum CodingKeys: String, CodingKey {
            case obj
            case text
            case replyObj = "reply_obj"
            case replyUid = "reply_uid"
            case anonymous
            case imageMids = "image_mids"
        }
    }

    private struct CreatePaperRequest: Encodable {
        let title: String
        let intro: String
        let content: String
        let anonymous: Bool
        let publicEdit: Bool

        enum CodingKeys: String, CodingKey {
            case title
            case intro
            case content
            case anonymous
            case publicEdit = "public_edit"
        }
    }

    private struct CreatePaperResponse: Decodable {
        let id: Int
    }

    init(storage: LoginStorage = .shared) {
        self.storage = storage
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
    }

    /// 拉取文章列表。
    func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
        var queryItems = [URLQueryItem(name: "page", value: String(page))]
        if let search, !search.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: search))
        }
        if let orderValue = order.requestValue {
            queryItems.append(URLQueryItem(name: "order", value: orderValue))
        }
        return try await sendJSONRequest(path: "papers", queryItems: queryItems, requiresAuthentication: false)
    }

    /// 拉取单篇文章详情。
    func fetchPaper(id: Int) async throws -> PaperDetail {
        try await sendJSONRequest(path: "papers/\(id)", requiresAuthentication: false)
    }

    /// 拉取文章评论。
    func fetchComments(paperID: Int, order: GalleryCommentOrder, page: Int?) async throws -> [GalleryComment] {
        var queryItems = [
            URLQueryItem(name: "obj", value: "paper\(paperID)"),
            URLQueryItem(name: "order", value: order.rawValue),
        ]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }
        return try await sendJSONRequest(path: "reaction/comments", queryItems: queryItems, requiresAuthentication: false)
    }

    /// 点赞或取消点赞文章。
    func likePaper(id: Int) async throws -> GalleryLikeResult {
        try await sendLike(objectID: "paper\(id)")
    }

    /// 点赞或取消点赞评论。
    ///
    /// 文章详情里的评论同样通过 reaction 接口处理，所以这里开放一个最小通用入口。
    func sendLike(objectID: String) async throws -> GalleryLikeResult {
        try await sendJSONRequest(
            path: "reaction/like",
            method: "POST",
            body: try JSONEncoder().encode(LikeRequest(obj: objectID))
        )
    }

    /// 发送文章评论或回复。
    func createComment(
        objectID: String,
        text: String,
        replyObjectID: String? = nil,
        replyUID: Int? = nil,
        anonymous: Bool = false
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
                    imageMids: []
                )
            )
        )
    }

    /// 新建文章。
    func createPaper(
        title: String,
        intro: String,
        content: String,
        anonymous: Bool,
        publicEdit: Bool = true
    ) async throws -> Int {
        let response: CreatePaperResponse = try await sendJSONRequest(
            path: "papers",
            method: "POST",
            body: try JSONEncoder().encode(
                CreatePaperRequest(
                    title: title,
                    intro: intro,
                    content: content,
                    anonymous: anonymous,
                    publicEdit: publicEdit
                )
            )
        )
        return response.id
    }

    private func sendJSONRequest<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        requiresAuthentication: Bool = true
    ) async throws -> Response {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components?.url else {
            throw PaperServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if requiresAuthentication {
            request.setValue(try requireFakeCookie(), forHTTPHeaderField: "fake-cookie")
        } else if !storage.fakeCookie.isEmpty {
            request.setValue(storage.fakeCookie, forHTTPHeaderField: "fake-cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PaperServiceError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200 ..< 300:
            break
        case 401:
            throw PaperServiceError.notLoggedIn
        default:
            let message = String(data: data, encoding: .utf8)
            throw NSError(
                domain: "BIT101.Paper",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "请求失败"]
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw PaperServiceError.invalidResponse
        }
    }

    private func requireFakeCookie() throws -> String {
        let fakeCookie = storage.fakeCookie
        guard !fakeCookie.isEmpty else {
            throw PaperServiceError.notLoggedIn
        }
        return fakeCookie
    }
}
