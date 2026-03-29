import Foundation

/// 举报类型与后端初始化数据保持一致，避免依赖当前失效的 `report_types` 接口。
struct CommunityReportType: Identifiable, Hashable {
    let id: Int
    let title: String
}

/// 举报动作类型。
enum CommunityReportAction: String, Identifiable, Hashable {
    case hidePoster
    case blockUser

    /// 供列表绑定使用的稳定标识。
    var id: String { rawValue }

    /// 在举报菜单中直接展示给用户的动作标题。
    var title: String {
        switch self {
        case .hidePoster:
            return "举报并隐藏该帖子"
        case .blockUser:
            return "举报并屏蔽该用户"
        }
    }
}

/// 社区治理页用到的公开联系信息。
enum CommunitySupport {
    /// 社区治理文案里统一展示的联系邮箱。
    ///
    /// 允许通过 `Info.plist` 覆盖，未配置时回退到默认邮箱。
    static var email: String {
        let fallback = "systemd@linux.do"
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "BIT101SupportEmail") as? String,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return fallback
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 社区本地治理工具。
enum CommunityModeration {
    private static let botTagKeywords = [
        "bot",
        "机器人",
        "通知",
        "新闻"
    ]

    static let reportTypes: [CommunityReportType] = [
        CommunityReportType(id: 1, title: "政治敏感"),
        CommunityReportType(id: 2, title: "色情低俗"),
        CommunityReportType(id: 3, title: "人身攻击"),
        CommunityReportType(id: 4, title: "侵犯隐私"),
        CommunityReportType(id: 5, title: "散布谣言"),
        CommunityReportType(id: 6, title: "滥用产品"),
        CommunityReportType(id: 7, title: "其他")
    ]

    private static let fallbackLiteralKeywords = [
        "傻逼",
        "傻b",
        "煞笔",
        "操你妈",
        "草你妈",
        "滚你妈",
        "去死",
        "杀了你",
        "约炮",
        "嫖娼",
        "强奸",
        "轮奸",
        "迷奸",
        "冰毒",
        "海洛因",
        "毒品交易",
        "色情图片",
        "成人视频",
        "支那",
        "暴支",
        "nmsl",
        "cnm"
    ]

    private nonisolated static let englishAllowlist: Set<String> = [
        "abuse",
        "aroused"
    ]

    private static let vendoredChineseWords = loadVendoredWords(fileName: "zh")
    private static let vendoredEnglishWords = loadVendoredWords(fileName: "en")

    private static let blockedRegexPatterns = [
        #"(?i)\bfuck\b"#,
        #"(?i)\bbitch\b"#,
        #"(?i)\bslut\b"#,
        #"(?i)\bkill\s*yourself\b"#,
        #"(?i)\bnigger\b"#,
        #"(?i)\brape\b"#,
        #"(?i)\bporn\b"#,
        #"(?i)\bheroin\b"#,
        #"(?i)\bcocaine\b"#
    ]

    /// 对单段文本做本地脏词检测。
    static func containsBlockedContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let normalized = normalize(trimmed)
        if fallbackLiteralKeywords.contains(where: { normalized.contains($0) }) {
            return true
        }

        if vendoredChineseWords.contains(where: { normalized.contains($0) }) {
            return true
        }

        let lowered = trimmed.lowercased()
        if vendoredEnglishWords.contains(where: { matchesEnglishWord($0, in: lowered) }) {
            return true
        }

        return blockedRegexPatterns.contains { pattern in
            trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// 批量检测多段文本，任意一段命中即视为违规。
    static func containsBlockedContent(in texts: [String]) -> Bool {
        texts.contains { containsBlockedContent($0) }
    }

    /// 判断一条帖子是否带有机器人标签。
    static func isBotPoster(tags: [String]) -> Bool {
        let normalizedTags = tags.map(normalize)
        return normalizedTags.contains { tag in
            botTagKeywords.contains(where: { keyword in tag.contains(normalize(keyword)) })
        }
    }

    /// 带机器人标签的服务端帖子不参与自动屏蔽。
    ///
    /// 这条例外只作用于入站展示过滤，不影响用户主动发帖时的检测。
    static func shouldBypassDirtyWords(tags: [String]) -> Bool {
        isBotPoster(tags: tags)
    }

    /// 发帖前对标题、正文和标签执行统一校验。
    static func validateDraft(title: String, text: String, tags: [String]) -> String? {
        let texts = [title, text] + tags
        guard containsBlockedContent(in: texts) else { return nil }
        return "内容包含违规词，请修改后再发布。"
    }

    /// 发评论前执行本地校验。
    static func validateCommentDraft(text: String) -> String? {
        guard containsBlockedContent(text) else { return nil }
        return "评论包含违规词，请修改后再发送。"
    }

    /// 判断单个帖子在当前本地治理设置下是否可见。
    static func isPosterVisible(_ poster: GalleryPoster, snapshot: AppSettingsSnapshot) -> Bool {
        let hideAnonymous = snapshot.galleryHiddenUserIDs.first == -1
        let hiddenUsers = Set(snapshot.galleryHiddenUserIDs.filter { $0 != -1 })
        let hiddenPosters = Set(snapshot.galleryHiddenPosters.map(\.id))

        if hiddenPosters.contains(poster.id) { return false }
        if hideAnonymous && poster.anonymous { return false }
        if hiddenUsers.contains(poster.user.id) { return false }
        if shouldBypassDirtyWords(tags: poster.tags) { return true }

        let posterTexts = [
            poster.title,
            poster.text,
            poster.user.nickname,
            poster.user.motto
        ] + poster.tags
        return !containsBlockedContent(in: posterTexts)
    }

    /// 过滤整批帖子列表。
    static func filterVisiblePosters(_ posters: [GalleryPoster], snapshot: AppSettingsSnapshot) -> [GalleryPoster] {
        posters.filter { isPosterVisible($0, snapshot: snapshot) }
    }

    /// 判断单条评论在当前设置下是否可见。
    static func isCommentVisible(_ comment: GalleryComment, snapshot: AppSettingsSnapshot) -> Bool {
        let hideAnonymous = snapshot.galleryHiddenUserIDs.first == -1
        let hiddenUsers = Set(snapshot.galleryHiddenUserIDs.filter { $0 != -1 })

        if hideAnonymous && comment.anonymous { return false }
        if hiddenUsers.contains(comment.user.id) { return false }
        if snapshot.galleryHideStrictMode && hiddenUsers.contains(comment.replyUser.id) { return false }

        let commentTexts = [
            comment.text,
            comment.user.nickname,
            comment.user.motto
        ]
        return !containsBlockedContent(in: commentTexts)
    }

    /// 递归过滤评论树，同时保留仍然可见的子评论。
    static func filterVisibleComments(_ comments: [GalleryComment], snapshot: AppSettingsSnapshot) -> [GalleryComment] {
        comments.compactMap { comment in
            guard isCommentVisible(comment, snapshot: snapshot) else { return nil }
            let visibleSubComments = filterVisibleComments(comment.sub, snapshot: snapshot)
            return comment.replacingSubComments(visibleSubComments)
        }
    }

    /// 统一归一化文本，去掉大小写、空白和标点差异，减少规避检测的空间。
    private nonisolated static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let removedWhitespace = lowered.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(removedWhitespace))
    }

    /// 对英语脏词做单词级匹配，避免普通长单词误伤。
    private nonisolated static func matchesEnglishWord(_ word: String, in text: String) -> Bool {
        guard !englishAllowlist.contains(word) else { return false }

        if word.contains(where: { !$0.isLetter && !$0.isNumber }) {
            return text.contains(word)
        }

        let pattern = "(?<![a-z0-9])\(NSRegularExpression.escapedPattern(for: word))(?![a-z0-9])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 从打包进 app 的词表文件中加载中英文脏词。
    private nonisolated static func loadVendoredWords(fileName: String) -> [String] {
        guard let url = vendoredWordListURL(fileName: fileName),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        return contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(normalize)
            .filter { $0.count >= 2 }
    }

    /// 在主 bundle 中查找词表文件位置。
    private nonisolated static func vendoredWordListURL(fileName: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: fileName, withExtension: "txt", subdirectory: "Resources/DirtyWords") {
            return bundled
        }

        if let bundled = Bundle.main.url(forResource: fileName, withExtension: "txt", subdirectory: "ThirdParty/profanity-list/list") {
            return bundled
        }

        if let resourceURL = Bundle.main.resourceURL {
            let copiedResource = resourceURL.appendingPathComponent("Resources/DirtyWords/\(fileName).txt")
            if FileManager.default.fileExists(atPath: copiedResource.path) {
                return copiedResource
            }

            let direct = resourceURL.appendingPathComponent("ThirdParty/profanity-list/list/\(fileName).txt")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
        }

        return nil
    }
}

/// 发往 BIT101 后端举报接口的请求体。
private struct BackendReportPayload: Encodable {
    let obj: String
    let typeID: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case obj
        case typeID = "type_id"
        case text
    }
}

/// 发往可选外部审核端点的请求体。
private struct ExternalModerationReportPayload: Encodable {
    let objectID: String
    let posterID: Int
    let posterTitle: String
    let targetUserID: Int
    let targetUserNickname: String
    let reportTypeID: Int
    let reportTypeTitle: String
    let action: String
    let note: String
    let reportedAt: String
}

/// 举报上传服务。后端接口和可选自定义审核端点都走后台 best-effort，上报失败不会打断当前用户操作。
struct CommunityReportService {
    private let backendBaseURL = URL(string: "https://bit101.flwfdd.xyz")!
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

    /// 对外暴露的举报入口。
    ///
    /// 上报是 best-effort 的：本地隐藏/屏蔽会立即生效，上报失败不会打断当前交互。
    func submitReport(for poster: GalleryPoster, type: CommunityReportType, note: String, action: CommunityReportAction) {
        Task.detached(priority: .utility) {
            try? await sendToBackend(poster: poster, type: type, note: note, action: action)
            try? await sendToExternalEndpoint(poster: poster, type: type, note: note, action: action)
        }
    }

    /// 上报到 BIT101 自带的举报接口。
    private func sendToBackend(poster: GalleryPoster, type: CommunityReportType, note: String, action: CommunityReportAction) async throws {
        guard !storage.fakeCookie.isEmpty else { return }

        let url = backendBaseURL.appending(path: "manage/reports")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(storage.fakeCookie, forHTTPHeaderField: "fake-cookie")

        let backendNote = [
            "iOS 客户端治理动作：\(action.title)",
            "帖子标题：\(poster.title)",
            note.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        request.httpBody = try JSONEncoder().encode(
            BackendReportPayload(
                obj: "poster\(poster.id)",
                typeID: type.id,
                text: backendNote
            )
        )

        _ = try await session.data(for: request)
    }

    /// 如已配置外部审核端点，再额外抄送一份给外部服务。
    private func sendToExternalEndpoint(poster: GalleryPoster, type: CommunityReportType, note: String, action: CommunityReportAction) async throws {
        guard
            let endpointString = Bundle.main.object(forInfoDictionaryKey: "BIT101ModerationReportEndpoint") as? String,
            let endpoint = URL(string: endpointString.trimmingCharacters(in: .whitespacesAndNewlines)),
            !endpointString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ExternalModerationReportPayload(
                objectID: "poster\(poster.id)",
                posterID: poster.id,
                posterTitle: poster.title,
                targetUserID: poster.user.id,
                targetUserNickname: poster.user.nickname,
                reportTypeID: type.id,
                reportTypeTitle: type.title,
                action: action.rawValue,
                note: note,
                reportedAt: ISO8601DateFormatter().string(from: Date())
            )
        )
        _ = try await session.data(for: request)
    }
}
