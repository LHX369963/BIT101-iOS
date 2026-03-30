import Foundation

/// 原生成绩查询的统一错误定义。
///
/// 成绩页直接面向用户展示错误，所以这里尽量把底层异常折叠成少量可理解的文案。
enum ScoreServiceError: LocalizedError {
    case missingCredentials
    case invalidResponse
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "未找到已保存的学号和密码，请先重新登录。"
        case .invalidResponse:
            return "成绩服务返回了无法识别的数据。"
        case let .queryFailed(message):
            return message
        }
    }
}

/// 成绩接口层。
///
/// 直接使用已保存的学号和统一认证密码请求 `bit_login_url`，不再依赖 WebView 自动填充。
struct ScoreService {
    /// 成绩查询接口的请求体。
    ///
    /// `detail=true` 会要求代理返回更完整的二维表，便于 iOS 端自行做筛选和详情展示。
    private struct ScoreRequest: Encodable {
        let username: String
        let password: String
        let detail: Bool
    }

    /// 成绩查询接口的响应体。
    ///
    /// 当前接口约定 `data[0]` 是表头，后续每一行对应一条课程成绩。
    private struct ScoreResponse: Decodable {
        let msg: String?
        let data: [[String]]
    }

    private let storage: LoginStorage
    private let session: URLSession
    /// 成绩代理服务基地址。
    ///
    /// 默认走线上代理；如 `Info.plist` 提供了覆写地址，则优先使用覆写值。
    private let endpointBaseURL: URL

    /// 初始化成绩服务。
    ///
    /// 这里不复用主站 fake-cookie，而是直接读取已保存的学号和统一认证密码去请求成绩代理。
    init(storage: LoginStorage = .shared) {
        self.storage = storage
        self.session = URLSession(configuration: .default)

        if
            let configured = Bundle.main.object(forInfoDictionaryKey: "BIT101BitLoginURL") as? String,
            let url = URL(string: configured.trimmingCharacters(in: .whitespacesAndNewlines)),
            !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            endpointBaseURL = url
        } else {
            endpointBaseURL = URL(string: "https://login.bit101.flwfdd.xyz")!
        }
    }

    /// 调用成绩接口并把二维表转成 `ScoreRow` 数组。
    ///
    /// 接口第一行是表头，后续每一行都是同一列顺序的成绩值。
    func fetchScores(detail: Bool) async throws -> [ScoreRow] {
        let studentID = storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = storage.currentPassword

        guard !studentID.isEmpty, !password.isEmpty else {
            throw ScoreServiceError.missingCredentials
        }

        var request = URLRequest(url: endpointBaseURL.appending(path: "api/jwb/bit101/score"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ScoreRequest(
                username: studentID,
                password: password,
                detail: detail
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ScoreServiceError.invalidResponse
        }

        if !(200 ..< 300).contains(httpResponse.statusCode) {
            throw ScoreServiceError.queryFailed(messageFromErrorResponse(data) ?? "成绩查询失败。")
        }

        let decoder = JSONDecoder()
        let payload: ScoreResponse
        do {
            payload = try decoder.decode(ScoreResponse.self, from: data)
        } catch {
            throw ScoreServiceError.invalidResponse
        }

        guard !payload.data.isEmpty else {
            throw ScoreServiceError.queryFailed(payload.msg ?? "没有查询到成绩数据。")
        }

        let headers = payload.data[0]
        let rows = payload.data.dropFirst().enumerated().map { index, row in
            ScoreRow(index: index, headers: headers, values: row)
        }
        return rows
    }

    /// 尝试从错误响应 JSON 中提取更具体的错误文案。
    ///
    /// 成绩代理失败时有时会返回纯文本，有时会返回 JSON，这里两种都兼容。
    private func messageFromErrorResponse(_ data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return String(data: data, encoding: .utf8)
        }

        if let msg = json["msg"] as? String, !msg.isEmpty {
            return msg
        }

        if let detail = json["detail"] as? String, !detail.isEmpty {
            return detail
        }

        return nil
    }
}
