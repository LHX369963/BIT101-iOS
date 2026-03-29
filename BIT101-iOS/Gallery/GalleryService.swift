//
//  GalleryService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// 话题接口层错误。
enum GalleryServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse

    /// 给 UI 直接展示的错误文案。
    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效，请重新登录后再查看话廊。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        }
    }
}

/// 机器人分栏的分页结果。
struct GalleryBotFeedBatch {
    let posters: [GalleryPoster]
    let nextSourcePage: Int
    let canLoadMore: Bool
}

/// 推荐分栏的分页结果。
///
/// 推荐流会额外跳过那些“服务端返回了内容，但本地过滤后为空”的页，避免列表错误地停在半路。
struct GalleryRecommendFeedBatch {
    let posters: [GalleryPoster]
    let nextSourcePage: Int
    let canLoadMore: Bool
}

/// 话题模块网络层。
///
/// 负责帖子流、搜索和与设置中心相关的过滤参数拼接。
struct GalleryService {
    private let baseURL = URL(string: "https://bit101.flwfdd.xyz")!
    private let session: URLSession
    private let storage: LoginStorage

    /// 发帖接口请求体。
    private struct CreatePosterRequest: Encodable {
        let title: String
        let text: String
        let imageMids: [String]
        let plugins: String
        let anonymous: Bool
        let tags: [String]
        let claimID: Int
        let `public`: Bool

        /// 对齐后端 snake_case 字段名。
        enum CodingKeys: String, CodingKey {
            case title
            case text
            case imageMids = "image_mids"
            case plugins
            case anonymous
            case tags
            case claimID = "claim_id"
            case `public`
        }
    }

    /// 发帖接口返回的最小结果。
    private struct CreatePosterResponse: Decodable {
        let id: Int
        let msg: String
    }

    /// 发评论接口请求体。
    private struct CreateCommentRequest: Encodable {
        let obj: String
        let text: String
        let replyObj: String?
        let replyUid: Int?
        let anonymous: Bool?
        let imageMids: [String]

        /// 对齐后端 snake_case 字段名。
        enum CodingKeys: String, CodingKey {
            case obj
            case text
            case replyObj = "reply_obj"
            case replyUid = "reply_uid"
            case anonymous
            case imageMids = "image_mids"
        }
    }

    /// 点赞接口请求体。
    private struct LikeRequest: Encodable {
        let obj: String
    }

    init(storage: LoginStorage = .shared) {
        self.storage = storage

        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
    }

    /// 拉取某个 feed 的帖子列表。
    func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> [GalleryPoster] {
        if kind.isBotFeed {
            let batch = try await fetchBotFeed(startPage: page ?? 0)
            return batch.posters
        }

        return try await fetchPosters(
            mode: kind.requestMode,
            order: kind.requestOrder,
            search: nil,
            uid: kind.requestUID,
            page: page,
            hideBot: true
        )
    }

    /// 推荐流在本地还会过滤机器人帖子，因此可能出现“某一页服务端有内容，但过滤后整页为空”。
    ///
    /// 这里向后多扫几页，直到拿到可展示内容或确认后端已经没有更多数据，避免推荐列表错误停止分页。
    func fetchRecommendFeed(startPage: Int) async throws -> GalleryRecommendFeedBatch {
        var sourcePage = startPage
        var collected: [GalleryPoster] = []
        var canLoadMore = true
        let maxScanCount = 6

        for _ in 0 ..< maxScanCount where canLoadMore && collected.count < 10 {
            let rawPosters = try await fetchRawPosters(
                mode: nil,
                order: nil,
                search: nil,
                uid: nil,
                page: sourcePage == 0 ? nil : sourcePage,
                hideBot: true
            )
            collected.append(contentsOf: applyBotFilterIfNeeded(rawPosters, hideBot: true))
            canLoadMore = !rawPosters.isEmpty
            sourcePage += 1
        }

        return GalleryRecommendFeedBatch(
            posters: collected,
            nextSourcePage: sourcePage,
            canLoadMore: canLoadMore
        )
    }

    /// 根据搜索关键词和排序条件查询帖子。
    func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> [GalleryPoster] {
        let settings = await MainActor.run {
            AppSettingsStore.loadSnapshotFromDefaults() ?? AppSettingsSnapshot()
        }
        return try await fetchPosters(
            mode: "search",
            order: query.order.rawValue,
            search: query.text.trimmingCharacters(in: .whitespacesAndNewlines),
            uid: -1,
            page: page,
            hideBot: settings.galleryHideBotPosterInSearch
        )
    }

    /// 机器人分栏不是服务端原生 feed，这里从“最新”帖子流里向后多抓几页，再筛出机器人帖子。
    func fetchBotFeed(startPage: Int) async throws -> GalleryBotFeedBatch {
        var sourcePage = startPage
        var collected: [GalleryPoster] = []
        var canLoadMore = true
        let maxScanCount = 5

        for _ in 0 ..< maxScanCount where canLoadMore && collected.count < 12 {
            let posters = try await fetchPosters(
                mode: "search",
                order: "new",
                search: nil,
                uid: -1,
                page: sourcePage == 0 ? nil : sourcePage,
                hideBot: false
            )
            collected.append(contentsOf: posters.filter { CommunityModeration.isBotPoster(tags: $0.tags) })
            canLoadMore = !posters.isEmpty
            sourcePage += 1
        }

        return GalleryBotFeedBatch(
            posters: collected,
            nextSourcePage: sourcePage,
            canLoadMore: canLoadMore
        )
    }

    /// 后端虽然支持 `hide_bot` 参数，但当前服务端过滤实现会漏掉机器人帖子。
    ///
    /// iOS 侧在保留服务端参数的同时，再补一层本地兜底，确保普通分栏不会混入机器人帖子。
    private func applyBotFilterIfNeeded(_ posters: [GalleryPoster], hideBot: Bool) -> [GalleryPoster] {
        guard hideBot else {
            return posters
        }

        return posters.filter { !CommunityModeration.isBotPoster(tags: $0.tags) }
    }

    /// 获取可选的帖子 claim 列表。
    func fetchClaims() async throws -> [GalleryClaim] {
        try await sendJSONRequest(path: "posters/claims")
    }

    /// 发送帖子创建请求。
    func createPoster(
        title: String,
        text: String,
        anonymous: Bool,
        tags: [String],
        claimID: Int,
        isPublic: Bool
    ) async throws -> Int {
        let fakeCookie = storage.fakeCookie
        guard !fakeCookie.isEmpty else {
            throw GalleryServiceError.notLoggedIn
        }

        let url = baseURL.appending(path: "posters")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CreatePosterRequest(
                title: title,
                text: text,
                imageMids: [],
                plugins: "[]",
                anonymous: anonymous,
                tags: tags,
                claimID: claimID,
                public: isPublic
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GalleryServiceError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200 ..< 300:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(CreatePosterResponse.self, from: data).id
        case 401:
            throw GalleryServiceError.notLoggedIn
        default:
            let message = String(data: data, encoding: .utf8) ?? "发布失败"
            throw NSError(
                domain: "BIT101.Gallery",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    /// 拉取单个帖子的详情。
    func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
        try await sendJSONRequest(path: "posters/\(id)")
    }

    /// 删除一条帖子。
    func deletePoster(id: Int) async throws {
        let fakeCookie = storage.fakeCookie
        guard !fakeCookie.isEmpty else {
            throw GalleryServiceError.notLoggedIn
        }

        var request = URLRequest(url: baseURL.appending(path: "posters/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GalleryServiceError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200 ..< 300:
            return
        case 401:
            throw GalleryServiceError.notLoggedIn
        default:
            let message = String(data: data, encoding: .utf8) ?? "删除失败"
            throw NSError(
                domain: "BIT101.Gallery",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    /// 拉取帖子或评论对象下的评论列表。
    func fetchComments(
        objectID: String,
        order: GalleryCommentOrder,
        page: Int?
    ) async throws -> [GalleryComment] {
        var queryItems = [
            URLQueryItem(name: "obj", value: objectID),
            URLQueryItem(name: "order", value: order.rawValue),
        ]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }
        return try await sendJSONRequest(path: "reaction/comments", queryItems: queryItems)
    }

    /// 对帖子或评论执行点赞操作。
    func like(objectID: String) async throws -> GalleryLikeResult {
        try await sendJSONRequest(
            path: "reaction/like",
            method: "POST",
            body: try JSONEncoder().encode(LikeRequest(obj: objectID))
        )
    }

    /// 创建一条评论或回复。
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

    /// 获取消息中心各分类的未读数。
    func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts {
        try await sendJSONRequest(path: "messages/unread_nums")
    }

    /// 拉取某个消息分类的列表。
    ///
    /// 后端使用 `last_id` 做历史分页；首次传空会顺手把该分类未读数清零。
    func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
        var queryItems = [URLQueryItem(name: "type", value: type.rawValue)]
        if let lastID {
            queryItems.append(URLQueryItem(name: "last_id", value: String(lastID)))
        }
        return try await sendJSONRequest(path: "messages", queryItems: queryItems)
    }

    /// 统一拼装帖子流接口参数。
    private func fetchPosters(
        mode: String?,
        order: String?,
        search: String?,
        uid: Int?,
        page: Int?,
        hideBot: Bool
    ) async throws -> [GalleryPoster] {
        let posters = try await fetchRawPosters(
            mode: mode,
            order: order,
            search: search,
            uid: uid,
            page: page,
            hideBot: hideBot
        )
        return applyBotFilterIfNeeded(posters, hideBot: hideBot)
    }

    /// 发起原始帖子流请求，不做客户端过滤，供更高层组合推荐/机器人等特殊分页语义。
    private func fetchRawPosters(
        mode: String?,
        order: String?,
        search: String?,
        uid: Int?,
        page: Int?,
        hideBot: Bool
    ) async throws -> [GalleryPoster] {
        let fakeCookie = storage.fakeCookie
        guard !fakeCookie.isEmpty else {
            throw GalleryServiceError.notLoggedIn
        }
        var components = URLComponents(url: baseURL.appending(path: "posters"), resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = []

        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }

        if let mode, !mode.isEmpty {
            queryItems.append(URLQueryItem(name: "mode", value: mode))
        }

        if let order, !order.isEmpty {
            queryItems.append(URLQueryItem(name: "order", value: order))
        }

        if let search, !search.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: search))
        }

        if let uid {
            queryItems.append(URLQueryItem(name: "uid", value: String(uid)))
        }

        if hideBot {
            queryItems.append(URLQueryItem(name: "hide_bot", value: "true"))
        }

        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw GalleryServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GalleryServiceError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200 ..< 300:
            break
        case 401:
            throw GalleryServiceError.notLoggedIn
        default:
            throw NSError(
                domain: "BIT101.Gallery",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "请求失败，HTTP 状态码 \(httpResponse.statusCode)。"]
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try decoder.decode([GalleryPoster].self, from: data)
        } catch {
            throw GalleryServiceError.invalidResponse
        }
    }

    private func sendJSONRequest<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Response {
        let fakeCookie = storage.fakeCookie
        guard !fakeCookie.isEmpty else {
            throw GalleryServiceError.notLoggedIn
        }

        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components?.url else {
            throw GalleryServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GalleryServiceError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200 ..< 300:
            break
        case 401:
            throw GalleryServiceError.notLoggedIn
        default:
            let message = String(data: data, encoding: .utf8)
            throw NSError(
                domain: "BIT101.Gallery",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "请求失败"]
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw GalleryServiceError.invalidResponse
        }
    }
}
