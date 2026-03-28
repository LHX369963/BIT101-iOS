//
//  GalleryModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// 话题首页的四种 feed。
enum GalleryFeedKind: String, CaseIterable, Identifiable {
    case follow
    case recommend
    case newest
    case hot

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
