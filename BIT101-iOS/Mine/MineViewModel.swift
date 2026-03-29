//
//  MineViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

@MainActor
/// “我的”页状态机。
///
/// 负责资料卡刷新，以及粉丝、关注、帖子三个分页列表的加载。
final class MineViewModel: ObservableObject {
    @Published private(set) var userInfo: MineUserInfo?
    @Published private(set) var profileStatus: MineLoadStatus = .idle
    @Published private(set) var followerState = MinePagedState<GalleryUser>()
    @Published private(set) var followingState = MinePagedState<GalleryUser>()
    @Published private(set) var posterState = MinePagedState<GalleryPoster>()
    @Published var alert: LoginAlert?

    private let service: MineService
    private var hasBootstrapped = false

    init(service: MineService) {
        self.service = service
    }

    convenience init() {
        self.init(service: MineService())
    }

    /// 首次进入“我的”页时预加载资料卡和帖子数。
    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refreshProfile()
        await refreshPosters()
    }

    /// 资料卡里展示的帖子数摘要。
    ///
    /// 服务端没有总数字段时，用 `+` 表示当前页后面可能还有更多。
    var posterCountText: String {
        switch posterState.status {
        case .idle, .loading:
            return "..."
        case .loaded:
            return posterState.canLoadMore ? "\(posterState.items.count)+" : "\(posterState.items.count)"
        case .failed:
            return "0"
        }
    }

    /// 刷新个人资料卡。
    func refreshProfile() async {
        let hadUserInfo = userInfo != nil || profileStatus == .loaded
        if !hadUserInfo {
            profileStatus = .loading
        }

        do {
            userInfo = try await service.fetchMyInfo()
            profileStatus = .loaded
        } catch {
            if isCancellation(error) {
                profileStatus = hadUserInfo ? .loaded : .idle
                return
            }

            if hadUserInfo {
                profileStatus = .loaded
                alert = LoginAlert(title: "刷新个人信息失败", message: error.localizedDescription)
                return
            }

            userInfo = nil
            profileStatus = .failed(error.localizedDescription)
            alert = LoginAlert(title: "加载个人信息失败", message: error.localizedDescription)
        }
    }

    /// 重新拉取粉丝第一页。
    func refreshFollowers() async {
        followerState.status = .loading
        followerState.items = []
        followerState.nextPage = 0
        followerState.canLoadMore = true
        followerState.isLoadingMore = false

        do {
            let users = try await service.fetchFollowers(page: 0)
            followerState.items = users
            followerState.status = .loaded
            followerState.nextPage = 1
            followerState.canLoadMore = !users.isEmpty
        } catch {
            followerState.status = .failed(error.localizedDescription)
            followerState.canLoadMore = false
            alert = LoginAlert(title: "加载粉丝失败", message: error.localizedDescription)
        }
    }

    /// 粉丝列表的分页加载。
    func loadMoreFollowersIfNeeded(currentUser: GalleryUser?) async {
        guard let currentUser else { return }
        guard shouldLoadMore(currentID: currentUser.id, state: followerState) else { return }

        followerState.isLoadingMore = true
        do {
            let users = try await service.fetchFollowers(page: followerState.nextPage)
            followerState.items.append(contentsOf: users)
            followerState.nextPage += 1
            followerState.isLoadingMore = false
            followerState.canLoadMore = !users.isEmpty
        } catch {
            followerState.isLoadingMore = false
            alert = LoginAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 重新拉取关注列表第一页。
    func refreshFollowings() async {
        followingState.status = .loading
        followingState.items = []
        followingState.nextPage = 0
        followingState.canLoadMore = true
        followingState.isLoadingMore = false

        do {
            let users = try await service.fetchFollowings(page: 0)
            followingState.items = users
            followingState.status = .loaded
            followingState.nextPage = 1
            followingState.canLoadMore = !users.isEmpty
        } catch {
            followingState.status = .failed(error.localizedDescription)
            followingState.canLoadMore = false
            alert = LoginAlert(title: "加载关注失败", message: error.localizedDescription)
        }
    }

    /// 关注列表的分页加载。
    func loadMoreFollowingsIfNeeded(currentUser: GalleryUser?) async {
        guard let currentUser else { return }
        guard shouldLoadMore(currentID: currentUser.id, state: followingState) else { return }

        followingState.isLoadingMore = true
        do {
            let users = try await service.fetchFollowings(page: followingState.nextPage)
            followingState.items.append(contentsOf: users)
            followingState.nextPage += 1
            followingState.isLoadingMore = false
            followingState.canLoadMore = !users.isEmpty
        } catch {
            followingState.isLoadingMore = false
            alert = LoginAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 重新拉取“我的帖子”第一页。
    func refreshPosters() async {
        let hadPosters = !posterState.items.isEmpty || posterState.status == .loaded
        if !hadPosters {
            posterState.status = .loading
            posterState.items = []
            posterState.nextPage = 0
            posterState.canLoadMore = true
            posterState.isLoadingMore = false
        }

        do {
            let posters = try await service.fetchMyPosters(page: 0)
            posterState.items = posters
            posterState.status = .loaded
            posterState.nextPage = 1
            posterState.canLoadMore = !posters.isEmpty
            posterState.isLoadingMore = false
        } catch {
            posterState.isLoadingMore = false

            if isCancellation(error) {
                posterState.status = hadPosters ? .loaded : .idle
                return
            }

            if hadPosters {
                posterState.status = .loaded
                alert = LoginAlert(title: "刷新帖子失败", message: error.localizedDescription)
                return
            }

            posterState.status = .failed(error.localizedDescription)
            posterState.canLoadMore = false
            alert = LoginAlert(title: "加载帖子失败", message: error.localizedDescription)
        }
    }

    /// “我的帖子”列表的分页加载。
    func loadMorePostersIfNeeded(currentPoster: GalleryPoster?) async {
        guard let currentPoster else { return }
        guard shouldLoadMore(currentID: currentPoster.id, state: posterState) else { return }

        posterState.isLoadingMore = true
        do {
            let posters = try await service.fetchMyPosters(page: posterState.nextPage)
            posterState.items.append(contentsOf: posters)
            posterState.nextPage += 1
            posterState.isLoadingMore = false
            posterState.canLoadMore = !posters.isEmpty
        } catch {
            posterState.isLoadingMore = false
            alert = LoginAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 判断当前滚动位置是否已经足够接近列表尾部，可以安全触发分页。
    private func shouldLoadMore<T: Identifiable>(currentID: T.ID, state: MinePagedState<T>) -> Bool where T.ID: Equatable {
        guard
            state.status == .loaded,
            !state.isLoadingMore,
            state.canLoadMore,
            state.items.suffix(4).contains(where: { $0.id == currentID })
        else {
            return false
        }

        return true
    }

    /// 同时兼容 Swift Concurrency 与 URLSession 的取消错误。
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

@MainActor
/// 他人主页状态机。
///
/// 负责拉取指定用户的公开资料和帖子列表，供话题详情里的“查看主页”复用。
final class UserProfileViewModel: ObservableObject {
    @Published private(set) var userInfo: MineUserInfo?
    @Published private(set) var profileStatus: MineLoadStatus = .idle
    @Published private(set) var posterState = MinePagedState<GalleryPoster>()
    @Published var alert: LoginAlert?

    private let userID: Int
    private let service: MineService
    private var hasBootstrapped = false

    init(userID: Int, service: MineService) {
        self.userID = userID
        self.service = service
    }

    convenience init(userID: Int) {
        self.init(userID: userID, service: MineService())
    }

    /// 首次进入主页时预加载资料和第一页帖子。
    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refreshAll()
    }

    /// 资料卡里展示的帖子数摘要。
    var posterCountText: String {
        switch posterState.status {
        case .idle, .loading:
            return "..."
        case .loaded:
            return posterState.canLoadMore ? "\(posterState.items.count)+" : "\(posterState.items.count)"
        case .failed:
            return "0"
        }
    }

    /// 同时刷新资料卡和帖子列表。
    func refreshAll() async {
        async let infoTask: Void = refreshProfile()
        async let posterTask: Void = refreshPosters()
        _ = await (infoTask, posterTask)
    }

    /// 刷新指定用户资料卡。
    func refreshProfile() async {
        let hadUserInfo = userInfo != nil || profileStatus == .loaded
        if !hadUserInfo {
            profileStatus = .loading
        }

        do {
            userInfo = try await service.fetchUserInfo(id: userID)
            profileStatus = .loaded
        } catch {
            if isCancellation(error) {
                profileStatus = hadUserInfo ? .loaded : .idle
                return
            }

            if hadUserInfo {
                profileStatus = .loaded
                alert = LoginAlert(title: "刷新主页失败", message: error.localizedDescription)
                return
            }

            userInfo = nil
            profileStatus = .failed(error.localizedDescription)
            alert = LoginAlert(title: "加载主页失败", message: error.localizedDescription)
        }
    }

    /// 刷新指定用户帖子列表第一页。
    func refreshPosters() async {
        let hadPosters = !posterState.items.isEmpty || posterState.status == .loaded
        if !hadPosters {
            posterState.status = .loading
            posterState.items = []
            posterState.nextPage = 0
            posterState.canLoadMore = true
            posterState.isLoadingMore = false
        }

        do {
            let posters = try await service.fetchUserPosters(userID: userID, page: 0)
            posterState.items = posters
            posterState.status = .loaded
            posterState.nextPage = 1
            posterState.canLoadMore = !posters.isEmpty
            posterState.isLoadingMore = false
        } catch {
            posterState.isLoadingMore = false

            if isCancellation(error) {
                posterState.status = hadPosters ? .loaded : .idle
                return
            }

            if hadPosters {
                posterState.status = .loaded
                alert = LoginAlert(title: "刷新帖子失败", message: error.localizedDescription)
                return
            }

            posterState.status = .failed(error.localizedDescription)
            posterState.canLoadMore = false
            alert = LoginAlert(title: "加载帖子失败", message: error.localizedDescription)
        }
    }

    /// 指定用户帖子列表分页加载。
    func loadMorePostersIfNeeded(currentPoster: GalleryPoster?) async {
        guard let currentPoster else { return }
        guard shouldLoadMore(currentID: currentPoster.id, state: posterState) else { return }

        posterState.isLoadingMore = true
        do {
            let posters = try await service.fetchUserPosters(userID: userID, page: posterState.nextPage)
            posterState.items.append(contentsOf: posters)
            posterState.nextPage += 1
            posterState.isLoadingMore = false
            posterState.canLoadMore = !posters.isEmpty
        } catch {
            posterState.isLoadingMore = false
            alert = LoginAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 判断当前滚动位置是否已经接近列表尾部，可以触发下一页。
    private func shouldLoadMore<T: Identifiable>(currentID: T.ID, state: MinePagedState<T>) -> Bool where T.ID: Equatable {
        guard
            state.status == .loaded,
            !state.isLoadingMore,
            state.canLoadMore,
            state.items.suffix(4).contains(where: { $0.id == currentID })
        else {
            return false
        }

        return true
    }

    /// 同时兼容 Swift Concurrency 与 URLSession 的取消错误。
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
