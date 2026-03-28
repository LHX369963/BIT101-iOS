//
//  LoginService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import CommonCrypto
import CryptoKit
import Foundation
import Security

// MARK: - URL Upgrade

/// 学校 SSO 存在从 HTTPS 跳回 HTTP 的历史问题。
///
/// iOS 的 ATS 不允许这类明文跳转，所以这里统一在客户端把目标地址升级回 HTTPS。
private enum LoginURLUpgrade {
    /// 把学校偶发返回的 HTTP 跳转地址升级成 HTTPS。
    nonisolated static func upgradedURL(from url: URL) -> URL {
        guard url.scheme?.lowercased() == "http" else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }

    /// 根据响应头里的 `Location` 字段解析下一跳地址，并补做 HTTPS 升级。
    nonisolated static func resolvedURL(from location: String, relativeTo baseURL: URL) -> URL? {
        if let absolute = URL(string: location) {
            return upgradedURL(from: absolute)
        }

        return URL(string: location, relativeTo: baseURL).map(upgradedURL(from:))
    }
}

/// 本地保存的登录凭据。
struct StoredCredentials {
    let studentID: String
    let password: String
}

/// 从学校登录页里解析出来的必要上下文。
struct SchoolLoginContext {
    let salt: String?
    let execution: String?
    let isLoggedIn: Bool
}

/// 登录链路中的统一错误定义。
enum LoginServiceError: LocalizedError {
    case invalidSchoolLoginPage
    case schoolLoginFailed
    case invalidServerResponse
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidSchoolLoginPage:
            return "学校登录页结构发生变化，暂时无法完成登录。"
        case .schoolLoginFailed:
            return "学校统一身份认证登录失败，请检查学号和密码。"
        case .invalidServerResponse:
            return "服务器返回了无法识别的数据。"
        case let .keychainWriteFailed(status):
            return "无法保存登录信息（Keychain 状态码: \(status)）。"
        case let .keychainReadFailed(status):
            return "无法读取登录信息（Keychain 状态码: \(status)）。"
        }
    }
}

/// 登录状态存储。
///
/// 学号和密码进 Keychain，fake-cookie 和登录标记进 `UserDefaults`，学校 cookie 放系统 `HTTPCookieStorage`。
final class LoginStorage {
    static let shared = LoginStorage()

    private enum DefaultsKey {
        static let fakeCookie = "login.fakeCookie"
    }

    private enum KeychainAccount {
        static let studentID = "login.sid"
        static let password = "login.password"
    }

    private let keychainService = "harrybit.BIT101-iOS.login"
    private let defaults = UserDefaults.standard
    private let cookieStorage = HTTPCookieStorage.shared

    private func notifyAccountChanged() {
        NotificationCenter.default.post(name: .loginStorageDidChange, object: nil)
    }

    var fakeCookie: String {
        defaults.string(forKey: DefaultsKey.fakeCookie) ?? ""
    }

    var currentStudentID: String {
        (try? readKeychainValue(account: KeychainAccount.studentID)) ?? ""
    }

    var currentPassword: String {
        (try? readKeychainValue(account: KeychainAccount.password)) ?? ""
    }

    /// 读取本地保存的完整学号和密码组合。
    func loadCredentials() throws -> StoredCredentials? {
        let studentID = try readKeychainValue(account: KeychainAccount.studentID)
        let password = try readKeychainValue(account: KeychainAccount.password)

        guard !studentID.isEmpty, !password.isEmpty else {
            return nil
        }

        return StoredCredentials(studentID: studentID, password: password)
    }

    /// 保存登录成功后的本地会话。
    func saveLoginState(studentID: String, password: String, fakeCookie: String) throws {
        try saveKeychainValue(studentID, account: KeychainAccount.studentID)
        try saveKeychainValue(password, account: KeychainAccount.password)
        defaults.set(fakeCookie, forKey: DefaultsKey.fakeCookie)
        notifyAccountChanged()
    }

    /// 清理当前会话，但保留账号密码，方便下次乐观进入主界面。
    func clearSession() {
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)

        // 学校侧登录态完全依赖 cookie，退出时必须一起清理，否则后续会误判为仍然在学校侧已登录。
        cookieStorage.cookies?.forEach { cookieStorage.deleteCookie($0) }
        notifyAccountChanged()
    }

    /// 删除客户端本地保存的所有登录相关数据。
    func clearAllLocalData() {
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        cookieStorage.cookies?.forEach { cookieStorage.deleteCookie($0) }
        deleteKeychainValue(account: KeychainAccount.studentID)
        deleteKeychainValue(account: KeychainAccount.password)
        notifyAccountChanged()
    }

    private func saveKeychainValue(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw LoginServiceError.keychainWriteFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw LoginServiceError.keychainWriteFailed(addStatus)
        }
    }

    private func readKeychainValue(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return ""
        }

        guard status == errSecSuccess else {
            throw LoginServiceError.keychainReadFailed(status)
        }

        guard
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw LoginServiceError.invalidServerResponse
        }

        return value
    }

    private func deleteKeychainValue(account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Android 端登录流程依赖的加密算法。
enum LoginCrypto {
    /// 复刻 Android 端的 AES 加密逻辑，用于学校登录表单和 WebVPN 校验。
    static func encryptPassword(_ password: String, saltBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: saltBase64) else {
            throw LoginServiceError.invalidSchoolLoginPage
        }

        let inputData = Data(password.utf8)
        var outputData = Data(count: inputData.count + kCCBlockSizeAES128)
        let outputBufferSize = outputData.count
        var outputLength: size_t = 0

        let status = outputData.withUnsafeMutableBytes { outputBytes in
            inputData.withUnsafeBytes { inputBytes in
                keyData.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        keyData.count,
                        nil,
                        inputBytes.baseAddress,
                        inputData.count,
                        outputBytes.baseAddress,
                        outputBufferSize,
                        &outputLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw LoginServiceError.invalidSchoolLoginPage
        }

        outputData.count = outputLength
        return outputData.base64EncodedString()
    }

    /// 登录模式注册接口要求密码先转成 MD5 十六进制字符串。
    static func md5Hex(_ value: String) -> String {
        Insecure.MD5
            .hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// 从学校 CAS 登录页 HTML 中抽取 salt 和 execution。
enum SchoolLoginHTMLParser {
    /// 从学校 CAS 登录页 HTML 中提取 salt、execution 和“是否已登录”状态。
    static func parse(html: String) -> SchoolLoginContext {
        SchoolLoginContext(
            salt: value(in: html, pattern: #"id=["']login-croypto["'][^>]*>\s*([^<\s]+)\s*<"#),
            execution: value(in: html, pattern: #"id=["']login-page-flowkey["'][^>]*>\s*([^<\s]+)\s*<"#),
            isLoggedIn: !html.contains("用户名密码")
        )
    }

    /// 使用正则从 HTML 中提取单个字段值。
    private static func value(in html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(html.startIndex..., in: html)
        guard
            let match = regex.firstMatch(in: html, options: [], range: range),
            let captureRange = Range(match.range(at: 1), in: html)
        else {
            return nil
        }

        return String(html[captureRange])
    }
}

fileprivate struct WebVPNVerifyInitRequest: Encodable {
    let sid: String
}

fileprivate struct WebVPNVerifyInitResponse: Decodable {
    let captcha: String
    let cookie: String
    let execution: String
    let salt: String
}

fileprivate struct WebVPNVerifyRequest: Encodable {
    let sid: String
    let password: String
    let execution: String
    let cookie: String
    let salt: String
    let captcha: String
}

fileprivate struct WebVPNVerifyResponse: Decodable {
    let token: String
    let code: String
}

fileprivate struct RegisterRequest: Encodable {
    let password: String
    let token: String
    let code: String
    let loginMode: Bool
}

fileprivate struct RegisterResponse: Decodable {
    let fakeCookie: String
}

/// 禁止自动重定向的 `URLSession` delegate。
///
/// 学校登录的第一跳需要手动截获 302，才能继续补走整条 SSO 链路。
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// 允许正常跳转，但在发生 HTTP 降级时强制改回 HTTPS。
private final class HTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate {
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

        let upgradedURL = LoginURLUpgrade.upgradedURL(from: url)
        if upgradedURL != url {
            var secureRequest = request
            secureRequest.url = upgradedURL
            completionHandler(secureRequest)
            return
        }

        completionHandler(request)
    }
}

/// 登录相关的网络客户端。
///
/// 既负责学校 CAS，也负责 BIT101 自己的 `webvpn_verify` / `register` 接口。
struct BIT101APIClient {
    private let schoolBaseURL = URL(string: "https://sso.bit.edu.cn")!
    private let bit101BaseURL = URL(string: "https://bit101.flwfdd.xyz")!

    private let session: URLSession
    private let noRedirectSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let noRedirectDelegate = NoRedirectDelegate()
    private let redirectDelegate = HTTPSRedirectDelegate()

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
        noRedirectSession = URLSession(
            configuration: configuration,
            delegate: noRedirectDelegate,
            delegateQueue: nil
        )

        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    /// 拉取学校登录页并解析出后续登录所需上下文。
    func fetchSchoolLoginContext() async throws -> SchoolLoginContext {
        var request = URLRequest(url: schoolBaseURL.appending(path: "cas/login"))
        request.httpMethod = "GET"

        let html = try await sendStringRequest(request)
        return SchoolLoginHTMLParser.parse(html: html)
    }

    /// 提交学校 CAS 登录表单。
    ///
    /// 返回值只表示学校侧认证是否成功，不代表 BIT101 自己已经完成注册或登录。
    func loginSchool(studentID: String, password: String, salt: String, execution: String) async throws -> Bool {
        let encryptedPassword = try LoginCrypto.encryptPassword(password, saltBase64: salt)
        let encryptedCaptchaPayload = try LoginCrypto.encryptPassword("{}", saltBase64: salt)

        var request = URLRequest(url: schoolBaseURL.appending(path: "cas/login"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(
            [
                ("username", studentID),
                ("password", encryptedPassword),
                ("execution", execution),
                ("croypto", salt),
                ("captcha_payload", encryptedCaptchaPayload),
                ("type", "UsernamePassword"),
                ("geolocation", ""),
                ("captcha_code", ""),
                ("_eventId", "submit"),
            ]
        )

        let (data, response) = try await sendRequest(request, followRedirects: false)

        if (300 ..< 400).contains(response.statusCode) {
            // 正确密码时学校会进入一串 SSO 成功跳转；如果这里不补走，后续教务和乐学接口仍然拿不到学校 cookie。
            if let location = response.value(forHTTPHeaderField: "Location") {
                try await finishSchoolLoginRedirectChain(from: location, relativeTo: request.url!)
            }
            return true
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            throw errorForStatusCode(response.statusCode)
        }

        let html = String(decoding: data, as: UTF8.self)
        return !html.contains("用户名密码")
    }

    /// 手动补走学校侧 SSO 的 302 链路，确保相关学校 cookie 真正落盘。
    private func finishSchoolLoginRedirectChain(from location: String, relativeTo baseURL: URL) async throws {
        guard var nextURL = LoginURLUpgrade.resolvedURL(from: location, relativeTo: baseURL) else {
            return
        }

        // 学校成功页通常会经历多次 302，这里手动接管，避免被 ATS 卡在中间的 HTTP 地址上。
        for _ in 0 ..< 8 {
            var request = URLRequest(url: nextURL)
            request.httpMethod = "GET"

            let (data, response) = try await sendRequest(request, followRedirects: false)

            if (300 ..< 400).contains(response.statusCode),
               let nextLocation = response.value(forHTTPHeaderField: "Location"),
               let resolved = LoginURLUpgrade.resolvedURL(from: nextLocation, relativeTo: nextURL) {
                nextURL = resolved
                continue
            }

            if (200 ..< 300).contains(response.statusCode) {
                return
            }

            if (200 ..< 400).contains(response.statusCode) {
                return
            }

            let html = String(decoding: data, as: UTF8.self)
            print("School redirect chain unexpected response: \(response.statusCode) \(nextURL.absoluteString) \(html.prefix(120))")
            throw errorForStatusCode(response.statusCode)
        }
    }

    fileprivate func webVPNVerifyInit(studentID: String) async throws -> WebVPNVerifyInitResponse {
        try await sendJSONRequest(
            url: bit101BaseURL.appending(path: "user/webvpn_verify_init"),
            method: "POST",
            body: WebVPNVerifyInitRequest(sid: studentID)
        )
    }

    fileprivate func webVPNVerify(studentID: String, password: String, execution: String, cookie: String, salt: String) async throws -> WebVPNVerifyResponse {
        try await sendJSONRequest(
            url: bit101BaseURL.appending(path: "user/webvpn_verify"),
            method: "POST",
            body: WebVPNVerifyRequest(
                sid: studentID,
                password: password,
                execution: execution,
                cookie: cookie,
                salt: salt,
                captcha: ""
            )
        )
    }

    fileprivate func register(password: String, token: String, code: String) async throws -> RegisterResponse {
        try await sendJSONRequest(
            url: bit101BaseURL.appending(path: "user/register"),
            method: "POST",
            body: RegisterRequest(
                password: password,
                token: token,
                code: code,
                loginMode: true
            )
        )
    }

    /// 检查 BIT101 自己的 fake-cookie 是否仍然有效。
    func checkBIT101Login(fakeCookie: String) async throws -> Bool {
        guard !fakeCookie.isEmpty else {
            return false
        }

        var request = URLRequest(url: bit101BaseURL.appending(path: "user/check"))
        request.httpMethod = "GET"
        request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")

        let (_, response) = try await sendRequest(request, followRedirects: true)
        switch response.statusCode {
        case 200 ..< 300:
            return true
        case 401:
            return false
        default:
            throw errorForStatusCode(response.statusCode)
        }
    }

    /// 发送普通字符串请求，主要用于学校 HTML 页面。
    private func sendStringRequest(_ request: URLRequest) async throws -> String {
        let (data, response) = try await sendRequest(request, followRedirects: true)

        guard (200 ..< 400).contains(response.statusCode) else {
            throw errorForStatusCode(response.statusCode)
        }

        return String(decoding: data, as: UTF8.self)
    }

    /// 发送 JSON 请求并自动解码响应体。
    private func sendJSONRequest<Body: Encodable, Response: Decodable>(
        url: URL,
        method: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await sendRequest(request, followRedirects: true)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw errorForStatusCode(response.statusCode)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw LoginServiceError.invalidServerResponse
        }
    }

    /// 根据是否允许跟随重定向，选择合适的 `URLSession` 并统一做 HTTPS 升级。
    private func sendRequest(_ request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        let activeSession = followRedirects ? session : noRedirectSession
        let finalRequest: URLRequest

        if let url = request.url {
            var upgradedRequest = request
            upgradedRequest.url = LoginURLUpgrade.upgradedURL(from: url)
            finalRequest = upgradedRequest
        } else {
            finalRequest = request
        }

        do {
            (data, response) = try await activeSession.data(for: finalRequest)
        } catch {
            throw describeNetworkError(error, request: finalRequest)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LoginServiceError.invalidServerResponse
        }

        return (data, httpResponse)
    }

    /// 把表单字段编码成 `application/x-www-form-urlencoded` 数据。
    private func formBody(_ fields: [(String, String)]) -> Data {
        let encoded = fields
            .map { key, value in
                "\(urlEncode(key))=\(urlEncode(value))"
            }
            .joined(separator: "&")

        return Data(encoded.utf8)
    }

    /// 表单字段专用的 URL 编码。
    private func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 把 HTTP 状态码转成统一错误对象。
    private func errorForStatusCode(_ statusCode: Int) -> NSError {
        NSError(
            domain: "BIT101.Login",
            code: statusCode,
            userInfo: [NSLocalizedDescriptionKey: "请求失败，HTTP 状态码 \(statusCode)。"]
        )
    }

    /// 为网络错误附带更具体的 URL 与诊断信息。
    private func describeNetworkError(_ error: Error, request: URLRequest) -> NSError {
        let nsError = error as NSError
        let failingURL =
            (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ??
            request.url

        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            let message = """
            网络请求被 ATS 拦截。
            URL: \(failingURL?.absoluteString ?? "未知")
            code: \(nsError.code)
            \(nsError.localizedDescription)
            """

            print(message)
            return NSError(
                domain: nsError.domain,
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let message = """
        网络请求失败。
        URL: \(failingURL?.absoluteString ?? "未知")
        code: \(nsError.code)
        \(nsError.localizedDescription)
        """

        print(message)
        return NSError(
            domain: nsError.domain,
            code: nsError.code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

/// 登录业务门面。
///
/// ViewModel 不直接关心学校 CAS、BIT101 注册和本地持久化细节，统一通过这里调度。
struct LoginService {
    private let storage: LoginStorage
    private let apiClient: BIT101APIClient

    init(storage: LoginStorage = .shared, apiClient: BIT101APIClient = BIT101APIClient()) {
        self.storage = storage
        self.apiClient = apiClient
    }

    /// 当前本地保存的学号。
    var savedStudentID: String {
        storage.currentStudentID
    }

    /// 当前本地保存的密码。
    var savedPassword: String {
        storage.currentPassword
    }

    /// 是否存在足以支撑“乐观进入主界面”的本地会话。
    ///
    /// 这里只做本地判断，不代表远端一定仍然有效；真正校验仍然放到后台异步完成。
    var hasCachedSession: Bool {
        !storage.fakeCookie.isEmpty && !savedStudentID.isEmpty
    }

    /// 校验当前本地会话是否仍然有效。
    ///
    /// 如有必要，会尝试使用已保存的账号密码静默重登学校 SSO。
    func checkLogin() async throws -> String? {
        let fakeCookie = storage.fakeCookie
        guard !fakeCookie.isEmpty else {
            return nil
        }

        // 先检查 BIT101 自己的登录态，再检查学校侧 cookie 是否还有效，两边都有效才算真正“已登录”。
        let bit101LoggedIn = try await apiClient.checkBIT101Login(fakeCookie: fakeCookie)
        guard bit101LoggedIn else {
            storage.clearSession()
            return nil
        }

        let schoolContext = try await apiClient.fetchSchoolLoginContext()
        if schoolContext.isLoggedIn {
            let studentID = storage.currentStudentID
            if studentID.isEmpty {
                storage.clearSession()
                return nil
            }
            return studentID
        }

        guard
            let credentials = try storage.loadCredentials(),
            let salt = schoolContext.salt,
            let execution = schoolContext.execution
        else {
            storage.clearSession()
            return nil
        }

        let reloginSucceeded = try await apiClient.loginSchool(
            studentID: credentials.studentID,
            password: credentials.password,
            salt: salt,
            execution: execution
        )

        if reloginSucceeded {
            return credentials.studentID
        }

        storage.clearSession()
        return nil
    }

    /// 执行完整登录流程：学校 CAS -> BIT101 WebVPN 校验 -> 登录模式注册。
    func login(studentID: String, password: String) async throws -> String {
        storage.clearSession()

        let schoolContext = try await apiClient.fetchSchoolLoginContext()
        guard
            let salt = schoolContext.salt,
            let execution = schoolContext.execution
        else {
            throw LoginServiceError.invalidSchoolLoginPage
        }

        let schoolLoginSucceeded = try await apiClient.loginSchool(
            studentID: studentID,
            password: password,
            salt: salt,
            execution: execution
        )

        guard schoolLoginSucceeded else {
            throw LoginServiceError.schoolLoginFailed
        }

        // 下面三步与 Android 保持一致：初始化验证码上下文 -> 校验 WebVPN -> 登录模式注册。
        let initResponse = try await apiClient.webVPNVerifyInit(studentID: studentID)
        let encryptedPassword = try LoginCrypto.encryptPassword(password, saltBase64: initResponse.salt)
        let verifyResponse = try await apiClient.webVPNVerify(
            studentID: studentID,
            password: encryptedPassword,
            execution: initResponse.execution,
            cookie: initResponse.cookie,
            salt: initResponse.salt
        )
        let md5Password = LoginCrypto.md5Hex(password)
        let registerResponse = try await apiClient.register(
            password: md5Password,
            token: verifyResponse.token,
            code: verifyResponse.code
        )

        try storage.saveLoginState(
            studentID: studentID,
            password: password,
            fakeCookie: registerResponse.fakeCookie
        )

        return studentID
    }

    /// 退出登录并清掉当前会话。
    func logout() {
        storage.clearSession()
    }
}
