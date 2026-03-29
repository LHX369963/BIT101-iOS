//
//  GalleryModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// 画廊首页的几个 feed。
enum GalleryFeedKind: String, CaseIterable, Identifiable {
    case follow
    case recommend
    case newest
    case hot
    case bot

    /// 供 `ForEach` 和本地持久化使用的稳定标识。
    var id: String { rawValue }

    /// 当前 feed 在 UI 上展示的标题。
    var title: String {
        switch self {
        case .follow:
            return "关注"
        case .recommend:
            return "推荐"
        case .newest:
            return "最新"
        case .hot:
            return "最热"
        case .bot:
            return "机器人"
        }
    }

    /// 对应后端 `mode` 参数。
    ///
    /// 推荐流走默认接口参数，因此返回 `nil`。
    var requestMode: String? {
        switch self {
        case .follow:
            return "follow"
        case .recommend:
            return nil
        case .newest:
            return "search"
        case .hot:
            return "hot"
        case .bot:
            return nil
        }
    }

    /// 对应后端 `order` 参数。
    var requestOrder: String? {
        switch self {
        case .newest:
            return "new"
        default:
            return nil
        }
    }

    /// 某些 feed 还需要显式带 `uid` 才能得到正确语义。
    ///
    /// 这里主要用于“最新”流复用搜索接口时避开“我的帖子”语义。
    var requestUID: Int? {
        switch self {
        case .newest:
            return -1
        default:
            return nil
        }
    }

    /// 机器人流不直接依赖后端 feed 语义，而是本地从公开帖子流中筛机器人标签。
    var isBotFeed: Bool {
        self == .bot
    }
}

/// 搜索页支持的排序方式。
enum GallerySearchOrder: String, CaseIterable, Identifiable {
    case similar
    case like
    case newest = "new"

    /// 供菜单 `Picker` 直接绑定的稳定标识。
    var id: String { rawValue }

    /// 搜索页排序控件展示的中文标题。
    var title: String {
        switch self {
        case .similar:
            return "相似"
        case .like:
            return "高赞"
        case .newest:
            return "最新"
        }
    }
}

/// 搜索栏当前查询条件。
struct GallerySearchQuery: Equatable {
    var text = ""
    var order: GallerySearchOrder = .newest
}

/// 图片资源模型。
struct GalleryImage: Decodable, Identifiable, Hashable {
    let mid: String
    let url: String
    let lowUrl: String

    /// 图片资源的稳定标识。
    var id: String { mid }
}

/// 用户身份标签。
struct GalleryIdentity: Decodable, Hashable {
    let id: Int
    let color: String
    let text: String
    let createTime: String
    let updateTime: String
    let deleteTime: String?
}

/// 话题用户模型。
struct GalleryUser: Decodable, Identifiable, Hashable {
    let id: Int
    let createTime: String
    let nickname: String
    let avatar: GalleryImage
    let motto: String
    let identity: GalleryIdentity
}

/// 帖子所属 claim。
struct GalleryClaim: Codable, Hashable, Identifiable {
    let id: Int
    let text: String
}

/// 话题帖子模型。
struct GalleryPoster: Decodable, Identifiable, Hashable {
    let anonymous: Bool
    let claim: GalleryClaim
    let commentNum: Int
    let createTime: String
    let editTime: String
    let id: Int
    let images: [GalleryImage]
    let likeNum: Int
    let `public`: Bool
    let tags: [String]
    let text: String
    let title: String
    let updateTime: String
    let user: GalleryUser
}

/// 帖子详情模型。
///
/// 相比列表项，详情额外带有当前用户的点赞状态、归属判断和插件字段。
struct GalleryPosterDetail: Decodable, Identifiable, Hashable {
    let anonymous: Bool
    let claim: GalleryClaim
    let commentNum: Int
    let createTime: String
    let editTime: String
    let id: Int
    let images: [GalleryImage]
    let like: Bool
    let likeNum: Int
    let own: Bool
    let plugins: String
    let `public`: Bool
    let tags: [String]
    let text: String
    let title: String
    let updateTime: String
    let user: GalleryUser

    init(
        anonymous: Bool,
        claim: GalleryClaim,
        commentNum: Int,
        createTime: String,
        editTime: String,
        id: Int,
        images: [GalleryImage],
        like: Bool,
        likeNum: Int,
        own: Bool,
        plugins: String,
        public: Bool,
        tags: [String],
        text: String,
        title: String,
        updateTime: String,
        user: GalleryUser
    ) {
        self.anonymous = anonymous
        self.claim = claim
        self.commentNum = commentNum
        self.createTime = createTime
        self.editTime = editTime
        self.id = id
        self.images = images
        self.like = like
        self.likeNum = likeNum
        self.own = own
        self.plugins = plugins
        self.public = `public`
        self.tags = tags
        self.text = text
        self.title = title
        self.updateTime = updateTime
        self.user = user
    }

    init(poster: GalleryPoster) {
        self.init(
            anonymous: poster.anonymous,
            claim: poster.claim,
            commentNum: poster.commentNum,
            createTime: poster.createTime,
            editTime: poster.editTime,
            id: poster.id,
            images: poster.images,
            like: false,
            likeNum: poster.likeNum,
            own: false,
            plugins: "[]",
            public: poster.public,
            tags: poster.tags,
            text: poster.text,
            title: poster.title,
            updateTime: poster.updateTime,
            user: poster.user
        )
    }

    /// 把详情模型降级成列表卡片模型，供“我的帖子”等场景复用。
    var asPoster: GalleryPoster {
        GalleryPoster(
            anonymous: anonymous,
            claim: claim,
            commentNum: commentNum,
            createTime: createTime,
            editTime: editTime,
            id: id,
            images: images,
            likeNum: likeNum,
            public: `public`,
            tags: tags,
            text: text,
            title: title,
            updateTime: updateTime,
            user: user
        )
    }

    /// 复制一份帖子详情，并替换当前用户对帖子的点赞状态。
    func updatingLike(_ like: Bool, likeNum: Int) -> GalleryPosterDetail {
        GalleryPosterDetail(
            anonymous: anonymous,
            claim: claim,
            commentNum: commentNum,
            createTime: createTime,
            editTime: editTime,
            id: id,
            images: images,
            like: like,
            likeNum: likeNum,
            own: own,
            plugins: plugins,
            public: `public`,
            tags: tags,
            text: text,
            title: title,
            updateTime: updateTime,
            user: user
        )
    }

    /// 在发送评论后，同步刷新帖子详情里的评论总数。
    func updatingCommentCount(_ commentNum: Int) -> GalleryPosterDetail {
        GalleryPosterDetail(
            anonymous: anonymous,
            claim: claim,
            commentNum: commentNum,
            createTime: createTime,
            editTime: editTime,
            id: id,
            images: images,
            like: like,
            likeNum: likeNum,
            own: own,
            plugins: plugins,
            public: `public`,
            tags: tags,
            text: text,
            title: title,
            updateTime: updateTime,
            user: user
        )
    }
}

/// 评论列表支持的排序方式。
enum GalleryCommentOrder: String, CaseIterable, Identifiable {
    case newest = "new"
    case oldest = "old"
    case like

    /// 供评论排序菜单绑定的稳定标识。
    var id: String { rawValue }

    /// 评论排序菜单展示的标题。
    var title: String {
        switch self {
        case .newest:
            return "最新"
        case .oldest:
            return "最旧"
        case .like:
            return "高赞"
        }
    }
}

/// 话题评论模型。
///
/// 后端返回的顶层评论和子评论结构一致，所以这里递归持有 `sub`。
struct GalleryComment: Decodable, Identifiable, Hashable {
    let id: Int
    let obj: String
    let images: [GalleryImage]
    let user: GalleryUser
    let anonymous: Bool
    let createTime: String
    let updateTime: String
    let like: Bool
    let likeNum: Int
    let commentNum: Int
    let own: Bool
    let rate: Int
    let replyUser: GalleryUser
    let replyObj: String
    let text: String
    let sub: [GalleryComment]

    /// 复制评论并替换其子评论列表。
    ///
    /// 主要用于本地过滤后重建仍然可见的评论树。
    func replacingSubComments(_ sub: [GalleryComment]) -> GalleryComment {
        GalleryComment(
            id: id,
            obj: obj,
            images: images,
            user: user,
            anonymous: anonymous,
            createTime: createTime,
            updateTime: updateTime,
            like: like,
            likeNum: likeNum,
            commentNum: commentNum,
            own: own,
            rate: rate,
            replyUser: replyUser,
            replyObj: replyObj,
            text: text,
            sub: sub
        )
    }

    /// 复制评论并替换当前用户对该评论的点赞状态。
    func updatingLike(_ like: Bool, likeNum: Int) -> GalleryComment {
        GalleryComment(
            id: id,
            obj: obj,
            images: images,
            user: user,
            anonymous: anonymous,
            createTime: createTime,
            updateTime: updateTime,
            like: like,
            likeNum: likeNum,
            commentNum: commentNum,
            own: own,
            rate: rate,
            replyUser: replyUser,
            replyObj: replyObj,
            text: text,
            sub: sub
        )
    }
}

/// 点赞接口返回的最新状态。
struct GalleryLikeResult: Decodable {
    let like: Bool
    let likeNum: Int
}

/// 单个 feed 的加载状态。
enum GalleryFeedStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// 单个 feed 的完整状态快照。
struct GalleryFeedState {
    /// 当前已经加载到客户端的帖子列表。
    var posters: [GalleryPoster] = []
    /// 列表当前所处的加载状态。
    var status: GalleryFeedStatus = .idle
    /// 是否正在请求下一页。
    var isLoadingMore = false
    /// 下一次分页请求的页码。
    var nextPage = 0
    /// 后端是否还有更多内容可翻。
    var canLoadMore = true
}

/// 消息中心支持的消息类型。
enum GalleryMessageType: String, CaseIterable, Identifiable {
    case comment
    case like
    case follow
    case system

    /// 供 `Picker` 和状态字典使用的稳定标识。
    var id: String { rawValue }

    /// 分段控件展示的中文标题。
    var title: String {
        switch self {
        case .comment:
            return "评论"
        case .like:
            return "点赞"
        case .follow:
            return "关注"
        case .system:
            return "系统"
        }
    }

    /// 当前类型对应的动作文案。
    func actionText(for message: GalleryMessage) -> String {
        switch self {
        case .comment:
            return message.obj.hasPrefix("comment") ? "回复了你的评论" : "评论了你的帖子"
        case .like:
            return message.obj.hasPrefix("comment") ? "点赞了你的评论" : "点赞了你的帖子"
        case .follow:
            return "关注了你"
        case .system:
            return "系统通知"
        }
    }
}

/// 消息发送者头像。
///
/// 消息接口里的 `from_user` 可能为空对象，因此这里单独做成宽松解码。
struct GalleryMessageAvatar: Decodable, Hashable {
    let url: String
    let lowUrl: String

    init(url: String = "", lowUrl: String = "") {
        self.url = url
        self.lowUrl = lowUrl
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case lowUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        lowUrl = try container.decodeIfPresent(String.self, forKey: .lowUrl) ?? ""
    }

    /// 优先返回低清地址，失败时回退到原图地址。
    var preferredURL: URL? {
        let raw = lowUrl.isEmpty ? url : lowUrl
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

/// 消息发送者。
///
/// 系统消息会返回空用户对象，因此昵称和头像都需要兜底。
struct GalleryMessageUser: Decodable, Hashable {
    let id: Int
    let nickname: String
    let avatar: GalleryMessageAvatar

    private enum CodingKeys: String, CodingKey {
        case id
        case nickname
        case avatar
    }

    init(id: Int = 0, nickname: String = "", avatar: GalleryMessageAvatar = GalleryMessageAvatar()) {
        self.id = id
        self.nickname = nickname
        self.avatar = avatar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        avatar = try container.decodeIfPresent(GalleryMessageAvatar.self, forKey: .avatar) ?? GalleryMessageAvatar()
    }

    /// 供消息列表直接展示的发信人名称。
    var displayName: String {
        if id == 0 {
            return "系统消息"
        }
        return nickname.isEmpty ? "未知用户" : nickname
    }
}

/// 各消息分类未读数。
struct GalleryMessageUnreadCounts: Decodable, Equatable {
    var comment: Int
    var follow: Int
    var like: Int
    var system: Int

    init(comment: Int = 0, follow: Int = 0, like: Int = 0, system: Int = 0) {
        self.comment = comment
        self.follow = follow
        self.like = like
        self.system = system
    }

    private enum CodingKeys: String, CodingKey {
        case comment
        case follow
        case like
        case system
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        comment = try container.decodeIfPresent(Int.self, forKey: .comment) ?? 0
        follow = try container.decodeIfPresent(Int.self, forKey: .follow) ?? 0
        like = try container.decodeIfPresent(Int.self, forKey: .like) ?? 0
        system = try container.decodeIfPresent(Int.self, forKey: .system) ?? 0
    }

    /// 统一给悬浮按钮计算红点总数。
    var total: Int {
        comment + follow + like + system
    }

    /// 读取单个消息类型的未读数。
    func unreadCount(for type: GalleryMessageType) -> Int {
        switch type {
        case .comment:
            return comment
        case .follow:
            return follow
        case .like:
            return like
        case .system:
            return system
        }
    }
}

/// 单条消息模型。
struct GalleryMessage: Decodable, Identifiable, Hashable {
    let fromUser: GalleryMessageUser
    let id: Int
    let linkObj: String
    let obj: String
    let text: String
    let updateTime: String

    /// 从消息对象里解析目标帖子 ID，供点按消息后跳到帖子详情。
    var linkedPosterID: Int? {
        Self.posterID(from: linkObj) ?? Self.posterID(from: obj)
    }

    private static func posterID(from raw: String) -> Int? {
        guard raw.hasPrefix("poster") else { return nil }
        return Int(raw.dropFirst("poster".count))
    }
}

/// 单个消息分类的列表状态。
struct GalleryMessageListState {
    /// 当前已经加载到客户端的消息列表。
    var items: [GalleryMessage] = []
    /// 列表当前所处的加载状态。
    var status: GalleryFeedStatus = .idle
    /// 是否正在请求下一页。
    var isLoadingMore = false
    /// 下一次分页请求要带的 last_id。
    var nextLastID: Int?
    /// 服务端是否还有更多历史消息。
    var canLoadMore = true
}

private extension GalleryImage {
    static var placeholder: GalleryImage {
        GalleryImage(mid: "", url: "", lowUrl: "")
    }
}

private extension GalleryIdentity {
    static var placeholder: GalleryIdentity {
        GalleryIdentity(id: 0, color: "#FF9500", text: "", createTime: "", updateTime: "", deleteTime: nil)
    }
}

extension GalleryUser {
    /// 供消息页跳转帖子详情时构造占位卡片。
    static func placeholder(id: Int = 0, nickname: String = "加载中") -> GalleryUser {
        GalleryUser(
            id: id,
            createTime: "",
            nickname: nickname,
            avatar: .placeholder,
            motto: "",
            identity: .placeholder
        )
    }
}

extension GalleryClaim {
    /// 供占位帖子使用的空 claim。
    static var placeholder: GalleryClaim {
        GalleryClaim(id: 0, text: "")
    }
}

extension GalleryPoster {
    /// 消息页在还未重新拉取帖子详情前使用的占位帖子。
    static func placeholder(id: Int, title: String = "正在打开帖子") -> GalleryPoster {
        GalleryPoster(
            anonymous: false,
            claim: .placeholder,
            commentNum: 0,
            createTime: "",
            editTime: "",
            id: id,
            images: [],
            likeNum: 0,
            public: true,
            tags: [],
            text: "",
            title: title,
            updateTime: "",
            user: .placeholder()
        )
    }
}
