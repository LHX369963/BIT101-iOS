//
//  SettingsServices.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// 设置中心网络层的统一错误。
enum SettingsServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse
    case uploadFailed

    /// 给设置页直接展示的错误文案。
    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .uploadFailed:
            return "图片上传失败。"
        }
    }
}

/// 设置中心会复用到的网络请求集合。
///
/// 账号信息、头像上传、登录状态检查和版本检查都集中在这里，避免页面层直接拼请求。
struct SettingsNetworkService {
    private let baseURL = URL(string: "https://bit101.flwfdd.xyz")!
    private let session: URLSession
    private let storage: LoginStorage

    /// 初始化设置中心网络层。
    ///
    /// 头像上传和资料修改都依赖 fake-cookie，因此这里与主 app 共用登录态存储。
    init(storage: LoginStorage = .shared) {
        self.storage = storage
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
    }

    /// 拉取当前登录用户自己的资料。
    ///
    /// 账号设置页、隐藏用户列表恢复展示等场景都会复用这条接口。
    func fetchMyInfo() async throws -> MineUserInfo {
        try await sendAuthedJSONRequest(path: "user/info/0")
    }

    /// 拉取指定用户的公开资料。
    func fetchUserInfo(id: Int) async throws -> MineUserInfo {
        try await sendAuthedJSONRequest(path: "user/info/\(id)")
    }

    /// 更新昵称、签名和头像。
    ///
    /// 接口要求整份资料一起提交，因此调用方需要自行传入“未改动但仍需保留”的旧值。
    func updateUser(nickname: String?, motto: String?, avatarMid: String?) async throws {
        let fakeCookie = storage.fakeCookie
        guard !fakeCookie.isEmpty else { throw SettingsServiceError.notLoggedIn }

        let body = try JSONEncoder().encode([
            "nickname": nickname,
            "motto": motto,
            "avatar_mid": avatarMid,
        ])
        var request = URLRequest(url: baseURL.appending(path: "user/info"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")
        request.httpBody = body

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SettingsServiceError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "BIT101.Settings", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "请求失败，HTTP 状态码 \(httpResponse.statusCode)。"])
        }
    }

    /// 上传头像图片，返回服务端生成的图片资源对象。
    ///
    /// 上传成功后还需要再调用一次 `updateUser`，把返回的 `mid` 绑定到用户资料里。
    func uploadAvatar(data: Data, filename: String = "avatar.jpg") async throws -> GalleryImage {
        let fakeCookie = storage.fakeCookie
        guard !fakeCookie.isEmpty else { throw SettingsServiceError.notLoggedIn }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: "upload/image"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")
        request.httpBody = multipartBody(boundary: boundary, data: data, filename: filename)

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SettingsServiceError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw SettingsServiceError.uploadFailed
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GalleryImage.self, from: responseData)
    }

    /// 检查当前登录状态是否仍然有效。
    ///
    /// 这里直接复用登录模块的后台校验逻辑，不额外复制一套登录判断链路。
    func checkLogin() async throws -> Bool {
        try await LoginService().checkLogin() != nil
    }

    /// 发送带 fake-cookie 的通用 GET JSON 请求。
    private func sendAuthedJSONRequest<Response: Decodable>(path: String) async throws -> Response {
        let fakeCookie = storage.fakeCookie
        guard !fakeCookie.isEmpty else { throw SettingsServiceError.notLoggedIn }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "GET"
        request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SettingsServiceError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "BIT101.Settings", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "请求失败，HTTP 状态码 \(httpResponse.statusCode)。"])
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }

    /// 手工拼装头像上传接口需要的 multipart body。
    ///
    /// 服务端字段名沿用 Android 端历史实现，因此这里保持 `file` 这一表单字段名不变。
    private func multipartBody(boundary: String, data: Data, filename: String) -> Data {
        // 服务端沿用 Android 端的上传接口，这里直接构造 multipart/form-data。
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
