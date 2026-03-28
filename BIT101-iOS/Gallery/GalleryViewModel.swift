//
//  GalleryViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

@MainActor
/// 话题页状态机。
///
/// 同时管理四个 feed 和一个搜索结果页，并显式处理分页、刷新和取消错误。
final class GalleryViewModel: ObservableObject {
    @Published var selectedFeed: GalleryFeedKind = .recommend
    @Published var searchQuery = GallerySearchQuery()
    @Published var searchState = GalleryFeedState()
    @Published var isShowingSearch = false
    @Published var alert: LoginAlert?

    @Published private(set) var feedStates: [GalleryFeedKind: GalleryFeedState] = {
        var states: [GalleryFeedKind: GalleryFeedState] = [:]
        GalleryFeedKind.allCases.forEach { states[$0] = GalleryFeedState() }
        return states
    }()

    private let service: GalleryService

    init(service: GalleryService) {
        self.service = service
    }

    convenience init() {
        self.init(service: GalleryService())
    }

    /// 首次进入话题页时触发一次默认 feed 加载。
    func bootstrapIfNeeded() async {
        guard state(for: selectedFeed).status == .idle else { return }
        await refreshSelectedFeed()
    }

    /// 刷新当前选中的 feed。
    func refreshSelectedFeed() async {
        await refresh(feed: selectedFeed)
    }

    /// 从第一页重新拉取指定 feed。
    ///
    /// 取消错误会恢复旧快照，避免 tab 快速切换时把 UI 误判成失败。
    func refresh(feed: GalleryFeedKind) async {
        let previousState = state(for: feed)
        if previousState.status == .loading {
            return
        }
        setState(for: feed) {
            $0.status = .loading
            $0.isLoadingMore = false
            $0.canLoadMore = true
            $0.nextPage = 0
        }

        do {
            let posters = try await service.fetchFeed(kind: feed, page: nil)
            setState(for: feed) {
                $0.posters = posters
                $0.status = .loaded
                $0.nextPage = 1
                $0.canLoadMore = !posters.isEmpty
            }
        } catch {
            if isCancellation(error) {
                // 列表复用、tab 切换或手动重刷时，SwiftUI/URLSession 都可能主动取消旧任务。
                // 这种情况不是用户可感知的失败，不应该弹错误框。
                setState(for: feed) {
                    $0.posters = previousState.posters
                    $0.status = previousState.posters.isEmpty ? .idle : .loaded
                    $0.isLoadingMore = false
                    $0.nextPage = previousState.nextPage
                    $0.canLoadMore = previousState.canLoadMore
                }
                return
            }
            setState(for: feed) {
                $0.posters = []
                $0.status = .failed(error.localizedDescription)
                $0.canLoadMore = false
            }
            alert = LoginAlert(title: "加载话题失败", message: error.localizedDescription)
        }
    }

    /// 当用户滚动到尾部附近时触发分页加载。
    func loadMoreIfNeeded(for feed: GalleryFeedKind, currentPoster: GalleryPoster?) async {
        guard let currentPoster else { return }
        let state = state(for: feed)

        guard
            state.status == .loaded,
            !state.isLoadingMore,
            state.canLoadMore,
            state.posters.suffix(4).contains(where: { $0.id == currentPoster.id })
        else {
            return
        }

        setState(for: feed) { $0.isLoadingMore = true }

        do {
            let posters = try await service.fetchFeed(kind: feed, page: state.nextPage)
            setState(for: feed) {
                $0.posters.append(contentsOf: posters)
                $0.isLoadingMore = false
                $0.nextPage += 1
                $0.canLoadMore = !posters.isEmpty
            }
        } catch {
            if isCancellation(error) {
                setState(for: feed) { $0.isLoadingMore = false }
                return
            }
            setState(for: feed) { $0.isLoadingMore = false }
            alert = LoginAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 执行当前搜索条件对应的首屏搜索。
    ///
    /// 搜索前会先裁剪首尾空白，确保排序和关键词状态保持一致。
    func performSearch() async {
        let trimmed = searchQuery.text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery.text = trimmed
        let previousState = searchState
        searchState.status = .loading
        searchState.posters = []
        searchState.isLoadingMore = false
        searchState.nextPage = 0
        searchState.canLoadMore = true

        do {
            let posters = try await service.searchPosters(query: searchQuery, page: nil)
            searchState.posters = posters
            searchState.status = .loaded
            searchState.nextPage = 1
            searchState.canLoadMore = !posters.isEmpty
        } catch {
            if isCancellation(error) {
                searchState = previousState
                return
            }
            searchState.status = .failed(error.localizedDescription)
            searchState.canLoadMore = false
            alert = LoginAlert(title: "搜索失败", message: error.localizedDescription)
        }
    }

    /// 搜索结果页的分页加载。
    func loadMoreSearchResultsIfNeeded(currentPoster: GalleryPoster?) async {
        guard let currentPoster else { return }

        guard
            searchState.status == .loaded,
            !searchState.isLoadingMore,
            searchState.canLoadMore,
            searchState.posters.suffix(4).contains(where: { $0.id == currentPoster.id })
        else {
            return
        }

        searchState.isLoadingMore = true

        do {
            let posters = try await service.searchPosters(query: searchQuery, page: searchState.nextPage)
            searchState.posters.append(contentsOf: posters)
            searchState.isLoadingMore = false
            searchState.nextPage += 1
            searchState.canLoadMore = !posters.isEmpty
        } catch {
            if isCancellation(error) {
                searchState.isLoadingMore = false
                return
            }
            searchState.isLoadingMore = false
            alert = LoginAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 读取某个 feed 的当前状态，缺省时返回空白状态。
    func state(for feed: GalleryFeedKind) -> GalleryFeedState {
        feedStates[feed] ?? GalleryFeedState()
    }

    /// 首次打开搜索页时自动触发一次默认预览搜索。
    func bootstrapSearchIfNeeded() async {
        guard searchState.status == .idle else { return }
        await performSearch()
    }

    /// 统一回写单个 feed 的可变状态，避免多个调用点直接操作字典。
    private func setState(for feed: GalleryFeedKind, mutate: (inout GalleryFeedState) -> Void) {
        var state = feedStates[feed] ?? GalleryFeedState()
        mutate(&state)
        feedStates[feed] = state
    }

    /// 同时兼容 Swift Concurrency 的 `CancellationError` 和 URLSession 的 `-999 cancelled`。
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
