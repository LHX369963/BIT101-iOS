//
//  MineService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// “我的”页接口层错误。
///
/// 这里故意只保留少量、面向 UI 的错误分类；更底层的 HTTP 状态码会在必要时转成通用 NSError。
enum MineServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效，请重新登录后再查看个人主页。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        }
    }
}

/// “我的”页网络层。
///
/// 这层只负责“我的”和“他人主页”会共用到的资料卡、关注关系和帖子列表请求，
/// 不承载任何页面状态，也不做分页拼接。
struct MineService {
    /// 个人主页相关接口根地址。
    private let baseURL = URL(string: "https://bit101.flwfdd.xyz")!
    private let session: URLSession
    private let storage: LoginStorage

    /// 初始化带 fake-cookie 的会话。
    ///
    /// “我的”页和话题页共用同一份登录存储，因此这里沿用系统 cookie 容器。
    init(storage: LoginStorage = .shared) {
        self.storage = storage

        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
    }

    /// 获取当前登录用户自己的资料卡信息。
    ///
    /// 服务端以 `0` 作为“当前用户”的占位 ID，所以“我的主页”和“他人主页”需要分别走不同接口路径。
    func fetchMyInfo() async throws -> MineUserInfo {
        try await sendJSONRequest(path: "user/info/0")
    }

    /// 获取指定用户的公开资料卡信息。
    func fetchUserInfo(id: Int) async throws -> MineUserInfo {
        try await sendJSONRequest(path: "user/info/\(id)")
    }

    /// 获取我关注的用户列表。
    ///
    /// 关注/粉丝接口都使用页码分页，第一页从 0 开始。
    func fetchFollowings(page: Int) async throws -> [GalleryUser] {
        try await sendJSONRequest(path: "user/followings", queryItems: [URLQueryItem(name: "page", value: String(page))])
    }

    /// 获取我的粉丝列表。
    func fetchFollowers(page: Int) async throws -> [GalleryUser] {
        try await sendJSONRequest(path: "user/followers", queryItems: [URLQueryItem(name: "page", value: String(page))])
    }

    /// 获取“我的帖子”列表。
    ///
    /// 服务端通过 `uid=0` 约定当前登录用户。
    func fetchMyPosters(page: Int) async throws -> [GalleryPoster] {
        try await sendJSONRequest(
            path: "posters",
            queryItems: [
                URLQueryItem(name: "mode", value: "search"),
                URLQueryItem(name: "uid", value: "0"),
                URLQueryItem(name: "page", value: String(page)),
            ]
        )
    }

    /// 获取指定用户的帖子列表。
    ///
    /// 这里沿用帖子搜索接口的 `uid` 语义，而不是单独的“用户帖子”接口。
    func fetchUserPosters(userID: Int, page: Int) async throws -> [GalleryPoster] {
        try await sendJSONRequest(
            path: "posters",
            queryItems: [
                URLQueryItem(name: "mode", value: "search"),
                URLQueryItem(name: "uid", value: String(userID)),
                URLQueryItem(name: "page", value: String(page)),
            ]
        )
    }

    /// 发送带 fake-cookie 的通用 GET JSON 请求。
    ///
    /// “我的”相关接口目前都是简单的 GET JSON，这里集中处理鉴权、状态码和解码错误。
    private func sendJSONRequest<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        let fakeCookie = storage.fakeCookie
        guard !fakeCookie.isEmpty else {
            throw MineServiceError.notLoggedIn
        }

        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components?.url else {
            throw MineServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MineServiceError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200 ..< 300:
            break
        case 401:
            throw MineServiceError.notLoggedIn
        default:
            throw NSError(
                domain: "BIT101.Mine",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "请求失败，HTTP 状态码 \(httpResponse.statusCode)。"]
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw MineServiceError.invalidResponse
        }
    }
}
