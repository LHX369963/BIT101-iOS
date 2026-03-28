//
//  MineModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// “我的”页个人信息接口模型。
struct MineUserInfo: Decodable {
    let user: GalleryUser
    let followingNum: Int
    let followerNum: Int
    let following: Bool
    let follower: Bool
    let own: Bool
}

/// “我的”页子列表的加载状态。
enum MineLoadStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// 粉丝、关注、帖子列表共用的分页状态。
struct MinePagedState<Item> {
    /// 当前已加载的列表项。
    var items: [Item] = []
    /// 列表整体加载状态。
    var status: MineLoadStatus = .idle
    /// 下一页页码。
    var nextPage = 0
    /// 是否正在请求下一页。
    var isLoadingMore = false
    /// 后端是否还有更多数据。
    var canLoadMore = true
}
